import AppKit
import ServiceManagement
import SwiftUI
import SousCore

/// Whether the Touch Bar's Control Strip (where the pill lives) is turned on.
enum ControlStrip {
    /// Touch Bar modes that show the Control Strip. A missing value is the macOS default
    /// ("App Controls with Control Strip").
    static func isShown(mode: String?) -> Bool {
        guard let mode else { return true }
        return ["appWithControlStrip", "fullControlStrip"].contains(mode)
    }

    static var currentMode: String? {
        CFPreferencesCopyAppValue("PresentationModeGlobal" as CFString, "com.apple.touchbar.agent" as CFString) as? String
    }

    static var isShown: Bool { isShown(mode: currentMode) }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.keyboard") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Launch at login (macOS 13+).
enum LoginItem {
    static var isSupported: Bool {
        if #available(macOS 13.0, *) { return true }
        return false
    }

    static var isEnabled: Bool {
        guard #available(macOS 13.0, *) else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    static func set(_ on: Bool) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("SousBar: launch at login failed: \(error)")
        }
    }
}

final class OnboardingModel: ObservableObject {
    /// Setup was interrupted (macOS quits the app after you grant microphone or speech access).
    let resumed: Bool

    init(resumed: Bool = false) { self.resumed = resumed }

    @Published var connected = HookConnection.isConnected
    @Published var connectError: String?
    @Published var justConnected = false
    @Published var controlStrip = ControlStrip.isShown
    @Published var voice = VoiceInput.isAuthorized
    @Published var voiceError: String?
    @Published var launchAtLogin = LoginItem.isEnabled
    @Published var demoRunning = false
    @Published var demoDone = false

    let canConnect = HookConnection.bundledHook != nil || FileManager.default.isExecutableFile(atPath: SousPaths.hookBinary)

    /// Settings can change outside the window (System Settings, the menu bar), so re-read them.
    func refresh() {
        connected = HookConnection.isConnected
        controlStrip = ControlStrip.isShown
        voice = VoiceInput.isAuthorized
        launchAtLogin = LoginItem.isEnabled
    }

    func connect() {
        let result = HookConnection.connect()
        connected = HookConnection.isConnected
        connectError = result.ok ? nil : (result.message.isEmpty ? "That didn't work." : result.message)
        justConnected = result.ok
    }

    func allowVoice() {
        VoiceInput.requestPermissions { [weak self] error in
            self?.voiceError = error
            self?.voice = VoiceInput.isAuthorized
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        LoginItem.set(on)
        launchAtLogin = LoginItem.isEnabled
    }

    /// Sends a fake read-only approval to the Touch Bar, through the same hook Claude Code uses.
    func sendTestApproval() {
        let installed = SousPaths.hookBinary
        guard let hook = FileManager.default.isExecutableFile(atPath: installed) ? installed : HookConnection.bundledHook else { return }
        demoRunning = true
        demoDone = false
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: hook)
            p.arguments = ["demo", "safe"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
            DispatchQueue.main.async {
                self.demoRunning = false
                self.demoDone = true
            }
        }
    }
}

// MARK: - Design

private enum Brand {
    static let orange = Color(red: 1.0, green: 0.58, blue: 0.0)
    static let ember = Color(red: 0.95, green: 0.35, blue: 0.12)
    static let bg = Color(red: 0.07, green: 0.07, blue: 0.08)
    static let card = Color.white.opacity(0.06)
    static let key = Color(white: 0.24)
    static let pill: [(Color, String)] = [
        (Color(white: 0.55), "Idle"),
        (.blue, "Working"),
        (orange, "Needs you"),
        (.green, "New reply"),
    ]
}

enum OnboardingStep: Int, CaseIterable {
    case welcome, connect, controlStrip, voice, launch, tryIt, done

    static var visible: [OnboardingStep] {
        allCases.filter { $0 != .launch || LoginItem.isSupported }
    }
}

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    var onDone: () -> Void
    @State private var step: OnboardingStep
    @State private var forward = true

    init(model: OnboardingModel, start: OnboardingStep? = nil, onDone: @escaping () -> Void) {
        self.model = model
        self.onDone = onDone
        // After macOS restarted the app for a permission, jump to the first step still to do.
        var first = OnboardingStep.welcome
        if model.resumed {
            first = OnboardingStep.visible.first { s in
                switch s {
                case .connect: return !model.connected
                case .controlStrip: return !model.controlStrip
                case .voice: return !model.voice
                case .welcome, .done: return false
                default: return true
                }
            } ?? .done
        }
        _step = State(initialValue: start ?? first)
    }

    private var steps: [OnboardingStep] { OnboardingStep.visible }
    private var index: Int { steps.firstIndex(of: step) ?? 0 }

    var body: some View {
        ZStack {
            Brand.bg

            VStack(spacing: 0) {
                progress.padding(.top, 38)

                hero
                    .frame(height: 190)
                    .padding(.top, 18)
                    .id(step)
                    .transition(slide)

                text
                    .id("text-\(step.rawValue)")
                    .transition(slide)
                    .padding(.horizontal, 48)

                Spacer(minLength: 0)
                footer.padding(.horizontal, 28).padding(.bottom, 22)
            }
        }
        .frame(width: 640, height: 540)
        .preferredColorScheme(.dark)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in model.refresh() }
    }

    private var slide: AnyTransition {
        .asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                    removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity))
    }

    private func go(_ delta: Int) {
        let next = min(max(index + delta, 0), steps.count - 1)
        forward = delta > 0
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { step = steps[next] }
    }

    // MARK: Chrome

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(steps, id: \.self) { s in
                Capsule()
                    .fill(s.rawValue <= step.rawValue ? Brand.orange : Color.white.opacity(0.15))
                    .frame(width: s == step ? 28 : 8, height: 6)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: step)
    }

    private var footer: some View {
        HStack {
            if step != .welcome && step != .done {
                Button("Back") { go(-1) }.buttonStyle(GhostButton())
            }
            Spacer()
            switch step {
            case .welcome:
                Button("Let's cook  →") { go(1) }.buttonStyle(PrimaryButton()).keyboardShortcut(.defaultAction)
            case .done:
                Button("Start cooking") { onDone() }.buttonStyle(PrimaryButton()).keyboardShortcut(.defaultAction)
            default:
                Button(isDone(step) ? "Continue  →" : "Skip for now") { go(1) }
                    .buttonStyle(isDone(step) ? AnyButtonStyle(PrimaryButton()) : AnyButtonStyle(GhostButton()))
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func isDone(_ s: OnboardingStep) -> Bool {
        switch s {
        case .connect: return model.connected
        case .controlStrip: return model.controlStrip
        case .voice: return model.voice
        case .launch: return model.launchAtLogin
        case .tryIt: return model.demoDone
        case .welcome, .done: return true
        }
    }

    // MARK: Pages

    @ViewBuilder private var hero: some View {
        switch step {
        case .welcome: WelcomeHero()
        case .connect: ConnectHero(connected: model.connected)
        case .controlStrip: ControlStripHero(shown: model.controlStrip)
        case .voice: VoiceHero()
        case .launch: LaunchHero(on: model.launchAtLogin)
        case .tryIt: ApprovalHero(live: model.demoRunning)
        case .done: LegendHero()
        }
    }

    @ViewBuilder private var text: some View {
        switch step {
        case .welcome:
            page("Your sous chef for Claude Code",
                 "Claude does the cooking. SousBar brings you only what needs you, right on the Touch Bar: approvals, questions and finished replies. You never have to switch apps.")
        case .connect:
            page("Connect to Claude Code",
                 model.justConnected
                    ? "Connected. Restart any running Claude Code sessions so they pick up SousBar."
                    : "SousBar adds its hooks to ~/.claude/settings.json, after making a backup. Nothing else in your settings changes.",
                 error: model.connectError) {
                if model.connected { DoneBadge("Connected") }
                else { Button("Connect") { model.connect() }.buttonStyle(PrimaryButton()).disabled(!model.canConnect) }
            }
        case .controlStrip:
            page("Find the chef hat",
                 model.controlStrip
                    ? "The Control Strip is on. Look for the chef hat on the right of your Touch Bar, and tap it to open the full bar."
                    : "SousBar lives in the Control Strip. Turn on Keyboard › Touch Bar Settings › Show Control Strip.") {
                if model.controlStrip { DoneBadge("Control Strip is on") }
                else { Button("Open Keyboard Settings") { ControlStrip.openSettings() }.buttonStyle(PrimaryButton()) }
            }
        case .voice:
            page("Talk instead of typing",
                 "Hold the mic to dictate prompts, Deny reasons or your own answers. macOS restarts SousBar once you allow it; this guide picks up right where you were.",
                 error: model.voiceError) {
                if model.voice { DoneBadge("Microphone allowed") }
                else { Button("Allow Microphone") { model.allowVoice() }.buttonStyle(PrimaryButton()) }
            }
        case .launch:
            page("Always on the line",
                 "Start SousBar when you log in, so it's ready whenever Claude Code is.") {
                Toggle(isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) })) {
                    Text("Launch at login").font(.system(size: 13, weight: .medium))
                }
                .toggleStyle(.switch)
                .tint(Brand.orange)
                .fixedSize()
            }
        case .tryIt:
            page("Take it for a spin",
                 model.demoRunning
                    ? "Now look down at your Touch Bar and tap Allow or Deny."
                    : (model.demoDone ? "That's the whole loop. When Claude asks, you answer from the bar."
                                      : "Send a pretend approval to your Touch Bar. Nothing actually runs.")) {
                if model.demoRunning {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Waiting for you on the Touch Bar…").foregroundColor(.secondary) }
                } else {
                    Button(model.demoDone ? "Send another" : "Send to my Touch Bar") { model.sendTestApproval() }
                        .buttonStyle(PrimaryButton())
                }
            }
        case .done:
            page("You're all set, chef",
                 "The chef hat's color tells you what's happening at a glance. You can reopen this guide any time from Setup Guide… in the menu bar.")
        }
    }

    private func page<Action: View>(_ title: String, _ body: String, error: String? = nil,
                                    @ViewBuilder action: () -> Action = { EmptyView() }) -> some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            Text(body)
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.65))
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            if let error {
                Text(error).font(.callout).foregroundColor(.red).multilineTextAlignment(.center)
            }
            action().padding(.top, 8)
        }
        .padding(.top, 22)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Buttons

private struct PrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 18).padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(configuration.isPressed ? Brand.ember : Brand.orange)
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct GhostButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(.white.opacity(configuration.isPressed ? 0.5 : 0.75))
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(configuration.isPressed ? 0.12 : 0.07)))
    }
}

private struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: ButtonStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

private struct DoneBadge: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
            Text(text)
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundColor(.green)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.green.opacity(0.12)))
    }
}

// MARK: - Touch Bar mock-ups

/// A small Touch Bar: black glass, rounded ends, a faint glow underneath.
private struct TouchBar<Content: View>: View {
    var width: CGFloat = 540
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: 6) { content }
            .padding(.horizontal, 8)
            .frame(width: width, height: 40)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.black)
            )
    }
}

private struct ChefHat: View {
    var color: Color
    var size: CGFloat = 18
    var body: some View {
        Image(nsImage: Icon.app.image(size: size, color: NSColor(color)))
            .frame(width: size, height: size)
    }
}

private struct Key: View {
    let label: String
    var fill: Color = Brand.key
    var width: CGFloat? = nil
    var body: some View {
        Text(label)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.white)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(width: width, height: 30)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(fill))
    }
}

private struct Chip: View {
    var name = "my-app"
    var body: some View {
        Text(name)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.white.opacity(0.85))
            .frame(width: 70, height: 30)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.12)))
    }
}

/// Text with an orange highlight sweeping across, like the bar's "Cooking…".
private struct Shimmer: View {
    let text: String
    @State private var phase: CGFloat = -1
    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(Brand.orange.opacity(0.55))
            .overlay(
                GeometryReader { g in
                    Rectangle().fill(Brand.orange)
                        .frame(width: g.size.width * 0.35)
                        .offset(x: phase * g.size.width * 1.4)
                }
                .mask(Text(text).font(.system(size: 13, weight: .medium)))
            )
            .lineLimit(1)
            .onAppear {
                withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { phase = 1 }
            }
    }
}

private struct WelcomeHero: View {
    @State private var i = 0
    private let lines: [(Color, String)] = [
        (.blue, "Cooking… Running Bash: npm test"),
        (Brand.orange, "Claude needs you: Edit src/app.ts"),
        (.green, "Done: the build is fixed"),
        (Color(white: 0.55), "Idle"),
    ]
    private let tick = Timer.publish(every: 2.0, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 26) {
            ZStack {
                Circle().fill(lines[i].0.opacity(0.16)).frame(width: 104, height: 104)
                ChefHat(color: lines[i].0, size: 52)
            }
            TouchBar(width: 460) {
                Chip()
                Group {
                    if i == 0 { Shimmer(text: lines[i].1) }
                    else { Text(lines[i].1).font(.system(size: 13, weight: .medium)).foregroundColor(.white) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(i)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                RoundedRectangle(cornerRadius: 6).fill(lines[i].0).frame(width: 40, height: 30)
                    .overlay(ChefHat(color: .white, size: 16))
            }
        }
        .onReceive(tick) { _ in withAnimation(.easeInOut(duration: 0.45)) { i = (i + 1) % lines.count } }
    }
}

private struct ConnectHero: View {
    let connected: Bool
    @State private var flow: CGFloat = 0
    var body: some View {
        HStack(spacing: 0) {
            node(Image(systemName: "terminal.fill").font(.system(size: 30)).foregroundColor(.white), "Claude Code")
            ZStack {
                Line().stroke(connected ? Color.green : Color.white.opacity(0.25),
                              style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: connected ? [] : [2, 9], dashPhase: flow))
                    .frame(height: 3)
                if connected {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 22)).foregroundColor(.green)
                        .background(Circle().fill(Brand.bg))
                        .transition(.scale)
                }
            }
            .frame(width: 180)
            node(ChefHat(color: Brand.orange, size: 38), "SousBar")
        }
        .animation(.spring(), value: connected)
        .onAppear { withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { flow = -22 } }
    }

    private func node<V: View>(_ icon: V, _ label: String) -> some View {
        VStack(spacing: 10) {
            icon
                .frame(width: 84, height: 84)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Brand.card))
            Text(label).font(.system(size: 12, weight: .medium)).foregroundColor(.white.opacity(0.6))
        }
    }
}

private struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return p
    }
}

private struct ControlStripHero: View {
    let shown: Bool
    @State private var pulse = false
    var body: some View {
        VStack(spacing: 18) {
            TouchBar(width: 560) {
                Key(label: "esc", width: 50)
                Spacer()
                ForEach(["chevron.left", "chevron.right", "magnifyingglass"], id: \.self) { s in
                    Image(systemName: s).font(.system(size: 12)).foregroundColor(.white.opacity(0.35)).frame(width: 34, height: 30)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05)))
                }
                Spacer()
                HStack(spacing: 4) {
                    ForEach(["sun.max.fill", "speaker.wave.2.fill", "mic.fill"], id: \.self) { s in
                        Image(systemName: s).font(.system(size: 12)).foregroundColor(.white.opacity(0.7)).frame(width: 34, height: 30)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Brand.key))
                    }
                    ZStack {
                        RoundedRectangle(cornerRadius: 6).stroke(Brand.orange, lineWidth: 2)
                            .scaleEffect(pulse ? 1.5 : 1).opacity(pulse ? 0 : 0.9)
                        RoundedRectangle(cornerRadius: 6).fill(Brand.key)
                        ChefHat(color: Brand.orange, size: 16)
                    }
                    .frame(width: 40, height: 30)
                }
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
                .opacity(shown ? 1 : 0.35)
            }
            HStack(spacing: 6) {
                Image(systemName: shown ? "checkmark.circle.fill" : "arrow.up.right")
                Text(shown ? "Control Strip" : "Control Strip is hidden")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(shown ? .green : Brand.orange)
            .frame(maxWidth: 540, alignment: .trailing)
        }
        .onAppear { withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true } }
    }
}

private struct VoiceHero: View {
    @State private var levels: [CGFloat] = Array(repeating: 0.2, count: 22)
    @State private var typed = 0
    private let sentence = "“run the tests and fix whatever fails”"
    private let tick = Timer.publish(every: 0.09, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 22) {
            HStack(spacing: 3) {
                ForEach(levels.indices, id: \.self) { i in
                    Capsule().fill(Brand.orange)
                        .frame(width: 5, height: 8 + levels[i] * 56)
                }
            }
            .frame(height: 64)
            TouchBar(width: 500) {
                Key(label: "", fill: .red, width: 44).overlay(Image(systemName: "mic.fill").foregroundColor(.white))
                Text(String(sentence.prefix(typed)))
                    .font(.system(size: 13, weight: .medium)).foregroundColor(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Key(label: "Send ➤", fill: Brand.orange)
            }
        }
        .onReceive(tick) { _ in
            withAnimation(.easeInOut(duration: 0.09)) {
                levels = levels.map { _ in CGFloat.random(in: 0.05...1) }
            }
            typed = typed >= sentence.count + 18 ? 0 : typed + 1
        }
    }
}

private struct LaunchHero: View {
    let on: Bool
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Spacer()
                Image(systemName: "wifi")
                Image(systemName: "battery.75")
                ChefHat(color: on ? Brand.orange : Color(white: 0.6), size: 16)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(on ? 0.15 : 0)))
                Text("Sat 9:41").font(.system(size: 12, weight: .medium))
            }
            .font(.system(size: 13))
            .foregroundColor(.white.opacity(0.85))
            .padding(.horizontal, 14)
            .frame(width: 420, height: 28)
            .background(Color.white.opacity(0.08))
            ZStack {
                Brand.card
                Image(systemName: "power")
                    .font(.system(size: 44, weight: .medium))
                    .foregroundColor(on ? Brand.orange : .white.opacity(0.4))
            }
            .frame(width: 420, height: 130)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .animation(.spring(), value: on)
    }
}

private struct ApprovalHero: View {
    let live: Bool
    @State private var hold: CGFloat = 0
    var body: some View {
        VStack(spacing: 20) {
            TouchBar(width: 560) {
                Chip(name: "demo")
                VStack(alignment: .leading, spacing: 1) {
                    Text("WebFetch").font(.system(size: 11, weight: .bold)).foregroundColor(Brand.orange)
                    Text("example.com/docs").font(.system(size: 12)).foregroundColor(.white)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Key(label: "→ Term")
                Key(label: "Deny", fill: Color(red: 0.55, green: 0.15, blue: 0.15))
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6).fill(Color(red: 0.12, green: 0.35, blue: 0.18))
                    RoundedRectangle(cornerRadius: 6).fill(Color.green).frame(width: 76 * hold)
                    Text("Allow").font(.system(size: 12, weight: .semibold)).foregroundColor(.white).frame(width: 76)
                }
                .frame(width: 76, height: 30)
            }
            HStack(spacing: 8) {
                Image(systemName: live ? "arrow.down" : "hand.tap.fill")
                Text(live ? "It's on your real Touch Bar now" : "Tap to allow. Riskier tools need a hold.")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(live ? Brand.orange : .white.opacity(0.5))
        }
        .onAppear { withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { hold = 1 } }
    }
}

private struct LegendHero: View {
    @State private var appear = false
    var body: some View {
        HStack(spacing: 22) {
            ForEach(Array(Brand.pill.enumerated()), id: \.offset) { i, item in
                VStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(item.0.opacity(0.16))
                            .frame(width: 74, height: 74)
                        ChefHat(color: item.0, size: 36)
                    }
                    Text(item.1).font(.system(size: 12, weight: .semibold)).foregroundColor(.white.opacity(0.75))
                }
                .scaleEffect(appear ? 1 : 0.6)
                .opacity(appear ? 1 : 0)
                .animation(.spring(response: 0.5, dampingFraction: 0.6).delay(Double(i) * 0.08), value: appear)
            }
        }
        .onAppear { appear = true }
    }
}

/// The first-launch setup window. Shown once; reopenable from the menu bar.
final class OnboardingWindow: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindow()
    private var window: NSWindow?
    private var model: OnboardingModel?

    /// First launch only (or after setup was interrupted). Replaces the old "Connect?" alert.
    static func showIfNeeded() {
        guard !Settings.hasOnboarded else { return }
        shared.show(resumed: Settings.onboardingStarted)
    }

    func show(resumed: Bool = false) {
        if let window {
            model?.refresh()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        Settings.onboardingStarted = true
        let model = OnboardingModel(resumed: resumed)
        let host = NSHostingController(rootView: OnboardingView(model: model) { [weak self] in
            self?.finish()
            self?.window?.close()
        })
        let window = NSWindow(contentViewController: host)
        window.title = "SousBar Setup"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(red: 0.07, green: 0.07, blue: 0.08, alpha: 1)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        self.model = model
        // An accessory app's window has to come to the front to be seen.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Only a close the user asked for (Done or the close button) ends setup. When macOS quits the
    /// app mid-setup, e.g. after granting microphone access, setup carries on at the next launch.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        finish()
        return true
    }

    private func finish() {
        Settings.hasOnboarded = true
        Settings.onboardingStarted = false
        // Closing without connecting counts as "Not now": don't nag with the old alert.
        if !HookConnection.isConnected { Settings.declinedHookSetup = true }
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        model = nil
    }
}
