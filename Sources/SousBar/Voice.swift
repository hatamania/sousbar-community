import AVFoundation
import Speech

/// Push-to-talk using Apple's speech recognizer (on-device when the language supports it).
final class VoiceInput {
    var onPartial: ((String) -> Void)?
    private(set) var isRecording = false

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var latest = ""
    private var completion: ((String) -> Void)?

    static var isAuthorized: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
            && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Calls back on main with nil on success, or a message explaining what to enable.
    static func requestPermissions(_ done: @escaping (String?) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else {
                DispatchQueue.main.async { done("Allow Speech Recognition for SousBar in System Settings › Privacy") }
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    done(granted ? nil : "Allow Microphone for SousBar in System Settings › Privacy")
                }
            }
        }
    }

    func start(localeId: String) throws {
        guard !isRecording else { return }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeId)), recognizer.isAvailable else {
            throw VoiceError("Speech recognition for \(localeId) isn't available right now")
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0 else { throw VoiceError("No microphone found") }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            req.append(buffer)
        }
        engine.prepare()
        try engine.start()

        latest = ""
        request = req
        isRecording = true
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let result {
                    self.latest = result.bestTranscription.formattedString
                    self.onPartial?(self.latest)
                    if result.isFinal { self.deliver() }
                }
                if error != nil { self.deliver() }
            }
        }
    }

    /// Stops listening; `completion` gets the final transcript (may be empty).
    func stop(_ completion: @escaping (String) -> Void) {
        guard isRecording else {
            completion("")
            return
        }
        self.completion = completion
        stopAudio()
        request?.endAudio()
        // If the final result never arrives, use the last partial.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in self?.deliver() }
    }

    func cancel() {
        completion = nil
        stopAudio()
        task?.cancel()
        task = nil
        request = nil
    }

    private func stopAudio() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        isRecording = false
    }

    private func deliver() {
        guard let completion else { return }
        self.completion = nil
        task = nil
        request = nil
        completion(latest.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

struct VoiceError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
