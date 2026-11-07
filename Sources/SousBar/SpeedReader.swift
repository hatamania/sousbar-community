import AppKit

/// One word (or code chip) shown on its own, and how long it stays relative to the base pace.
struct RSVPToken: Equatable {
    let text: String
    /// 1 = one beat at the chosen words-per-minute.
    let weight: Double
    /// First word of a sentence or paragraph: where swipes jump to.
    let startsSentence: Bool
    /// The letter the eye should land on, or nil to center (code chips).
    let focus: Int?
}

/// Rapid serial visual presentation: splitting, pacing and focus letters. No UI here.
enum RSVP {
    static let minWPM = 150
    static let maxWPM = 700
    static let stepWPM = 50
    static let defaultWPM = 300

    static func clamp(_ wpm: Int) -> Int {
        let stepped = Int((Double(wpm) / Double(stepWPM)).rounded()) * stepWPM
        return min(maxWPM, max(minWPM, stepped))
    }

    /// Splits plain text (from TextTools.stripMarkdown) into tokens. A "‹code · N lines›" chip
    /// stays one token; list bullets are dropped (the line break already gives a pause).
    static func tokenize(_ text: String) -> [RSVPToken] {
        var tokens: [RSVPToken] = []
        let lines = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        for line in lines {
            let words = splitKeepingChips(line).filter { $0 != "•" }
            for (i, word) in words.enumerated() {
                let first = i == 0
                let last = i == words.count - 1
                let afterSentence = tokens.last.map { endsSentence($0.text) } ?? true
                tokens.append(RSVPToken(
                    text: word,
                    weight: weight(word, endOfLine: last),
                    startsSentence: first || afterSentence,
                    focus: isChip(word) ? nil : focusIndex(word)
                ))
            }
        }
        return tokens
    }

    private static func isChip(_ w: String) -> Bool { w.hasPrefix("‹") && w.hasSuffix("›") }

    /// Whitespace split, except text between ‹ and › is kept together.
    private static func splitKeepingChips(_ line: String) -> [String] {
        var out: [String] = []
        var current = ""
        var inChip = false
        for ch in line {
            if ch == "‹" { inChip = true }
            if ch == "›" { inChip = false }
            if ch.isWhitespace && !inChip {
                if !current.isEmpty { out.append(current) }
                current = ""
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    private static let closers = CharacterSet(charactersIn: "\"')]}”’»*_`")

    /// The word without trailing quotes/brackets, so `done."` still counts as ending a sentence.
    private static func core(_ w: String) -> String {
        w.trimmingCharacters(in: closers)
    }

    static func endsSentence(_ w: String) -> Bool {
        guard let last = core(w).last else { return false }
        return ".!?…".contains(last)
    }

    /// How many beats a word gets: punctuation pauses, long or technical words linger, code chips hold.
    static func weight(_ w: String, endOfLine: Bool) -> Double {
        if isChip(w) { return 3.5 }
        var weight = 1.0
        let c = core(w)
        let letters = c.filter { $0.isLetter || $0.isNumber }.count
        if letters > 8 { weight *= min(1.6, 1 + Double(letters - 8) * 0.07) }
        // Numbers, paths, identifiers: things you can't guess from context.
        if c.contains(where: \.isNumber) || c.contains("/") || c.contains("_") || c.contains("::")
            || (c.dropLast().contains(".") && c.count > 3) {
            weight *= 1.4
        }
        var pause = 1.0
        if let last = c.last {
            if ".!?…".contains(last) { pause = 2.2 }
            else if ";:".contains(last) { pause = 1.8 }
            else if last == "," || last == "—" || last == "–" { pause = 1.5 }
        }
        if endOfLine { pause = max(pause, 2.8) }
        return weight * pause
    }

    /// Spritz-style optimal recognition point: a little left of the middle, counted over the
    /// word's letters (leading quotes or brackets don't count).
    static func focusIndex(_ word: String) -> Int {
        let chars = Array(word)
        let lead = chars.prefix { !($0.isLetter || $0.isNumber) }.count
        let body = chars.dropFirst(lead).filter { $0.isLetter || $0.isNumber }.count
        let offset: Int
        switch body {
        case 0...1: offset = 0
        case 2...5: offset = 1
        case 6...9: offset = 2
        case 10...13: offset = 3
        default: offset = 4
        }
        return min(chars.count - 1, lead + offset)
    }

    /// Seconds a token stays up. The first few words start slower and ramp up to speed.
    static func duration(_ token: RSVPToken, at index: Int, wpm: Int) -> TimeInterval {
        let ramp: [Double] = [1.8, 1.5, 1.3, 1.1]
        let warmup = index < ramp.count ? ramp[index] : 1
        return 60.0 / Double(clamp(wpm)) * token.weight * warmup
    }
}

/// Playback state, separate from the view so it can be tested without timers.
final class SpeedReaderEngine {
    let tokens: [RSVPToken]
    private(set) var index = 0
    private(set) var isPlaying = false
    var wpm: Int { didSet { wpm = RSVP.clamp(wpm) } }
    /// Index where the current run started, so the ramp-up restarts after a pause or jump.
    private var runStart = 0

    init(text: String, wpm: Int) {
        tokens = RSVP.tokenize(text)
        self.wpm = RSVP.clamp(wpm)
    }

    var current: RSVPToken? { tokens.indices.contains(index) ? tokens[index] : nil }
    var isAtEnd: Bool { index >= tokens.count - 1 }
    var progress: Double { tokens.count > 1 ? Double(index) / Double(tokens.count - 1) : 1 }

    /// How long the current word stays up before `advance()`.
    var currentDuration: TimeInterval {
        guard let t = current else { return 0 }
        return RSVP.duration(t, at: index - runStart, wpm: wpm)
    }

    func play() {
        guard !tokens.isEmpty else { return }
        if isAtEnd { index = 0 } // replay from the top
        isPlaying = true
        runStart = index
    }

    func pause() { isPlaying = false }

    /// Moves to the next word. Returns false (and stops) at the end.
    @discardableResult
    func advance() -> Bool {
        guard index < tokens.count - 1 else {
            isPlaying = false
            return false
        }
        index += 1
        return true
    }

    /// Back to the start of this sentence, or the previous one if we're already at a start.
    func previousSentence() {
        var i = max(0, index - 1)
        while i > 0, !tokens[i].startsSentence { i -= 1 }
        index = i
        runStart = index
    }

    func nextSentence() {
        var i = index + 1
        while i < tokens.count, !tokens[i].startsSentence { i += 1 }
        index = min(i, tokens.count - 1)
        runStart = index
    }

    func faster() { wpm += RSVP.stepWPM }
    func slower() { wpm -= RSVP.stepWPM }
}

/// Shows one word at a time with its focus letter pinned to the same spot and colored.
/// Tap: pause/resume. Swipe: previous/next sentence (pauses). Long-press: full reply.
final class SpeedReaderView: NSView {
    var onLongPress: (() -> Void)?
    /// Playing/paused/finished changed (to update the play button).
    var onStateChange: ((Bool) -> Void)?

    private(set) var engine: SpeedReaderEngine
    private var timer: Timer?
    private var badge: String?          // e.g. "350 wpm", shown briefly at the right
    private var badgeToken = 0
    private var touchStartX: CGFloat?
    private var moved = false
    private var longPressTimer: Timer?

    static let font = NSFont.systemFont(ofSize: 17, weight: .medium)
    static let focusColor = ActivityStyle.orange
    /// Where the focus letter sits, as a fraction of the view's width.
    static let anchor: CGFloat = 0.32

    init(text: String, wpm: Int) {
        engine = SpeedReaderEngine(text: text, wpm: wpm)
        super.init(frame: .zero)
        allowedTouchTypes = [.direct]
        wantsLayer = true
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
        ])
        setContentHuggingPriority(.init(1), for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }

    var isPlaying: Bool { engine.isPlaying }

    // MARK: Playback

    func play() {
        engine.play()
        schedule()
        needsDisplay = true
        onStateChange?(true)
    }

    func pause() {
        engine.pause()
        timer?.invalidate()
        timer = nil
        needsDisplay = true
        onStateChange?(false)
    }

    func toggle() { isPlaying ? pause() : play() }

    func faster() { changeSpeed { $0.faster() } }
    func slower() { changeSpeed { $0.slower() } }

    private func changeSpeed(_ change: (SpeedReaderEngine) -> Void) {
        change(engine)
        Settings.readingWPM = engine.wpm
        showBadge("\(engine.wpm) wpm")
        if isPlaying { schedule() } // apply the new pace to the current word right away
    }

    private func schedule() {
        timer?.invalidate()
        // No window check: Touch Bar views may never report one, which left the reader stuck on word one.
        guard engine.isPlaying, superview != nil else { return }
        let t = Timer(timeInterval: engine.currentDuration, repeats: false) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        if engine.advance() {
            needsDisplay = true
            schedule()
        } else {
            timer = nil
            needsDisplay = true
            onStateChange?(false) // finished: tap or ▶ plays again from the top
        }
    }

    private func jump(_ forward: Bool) {
        if isPlaying { pause() }
        forward ? engine.nextSentence() : engine.previousSentence()
        needsDisplay = true
    }

    private func showBadge(_ text: String) {
        badge = text
        badgeToken += 1
        let token = badgeToken
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.badgeToken == token else { return }
            self.badge = nil
            self.needsDisplay = true
        }
    }

    /// Runs while the view is on the bar; stops as soon as it's taken off (the bar is rebuilt or hidden).
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if superview == nil {
            timer?.invalidate()
            timer = nil
        } else if engine.isPlaying, timer == nil {
            schedule()
        }
    }

    deinit { timer?.invalidate() }

    // MARK: Drawing

    /// x where a word starts so that its focus letter's center lands on `anchorX`.
    static func origin(of word: String, focus: Int?, anchorX: CGFloat, width: CGFloat) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let full = (word as NSString).size(withAttributes: attrs).width
        guard let focus, focus < word.count else { return (width - full) / 2 }
        let before = (String(word.prefix(focus)) as NSString).size(withAttributes: attrs).width
        let letter = (String(Array(word)[focus]) as NSString).size(withAttributes: attrs).width
        return anchorX - before - letter / 2
    }

    override func draw(_ dirtyRect: NSRect) {
        let w = bounds.width, h = bounds.height
        let anchorX = (w * Self.anchor).rounded()
        let dim = NSColor(white: 1, alpha: 0.28)

        dim.setFill()
        // Guide ticks at the very top and bottom edges, clear of the letters.
        NSRect(x: anchorX - 0.75, y: h - 2.5, width: 1.5, height: 2.5).fill()
        NSRect(x: anchorX - 0.75, y: 2, width: 1.5, height: 2).fill()

        if let token = engine.current {
            let text = NSMutableAttributedString(string: token.text, attributes: [
                .font: Self.font, .foregroundColor: NSColor.white,
            ])
            if let f = token.focus, f < token.text.count {
                let start = token.text.index(token.text.startIndex, offsetBy: f)
                let ns = NSRange(start..<token.text.index(after: start), in: token.text)
                text.addAttribute(.foregroundColor, value: Self.focusColor, range: ns)
            } else {
                text.addAttribute(.foregroundColor, value: NSColor(white: 1, alpha: 0.7), range: NSRange(location: 0, length: text.length))
            }
            let x = Self.origin(of: token.text, focus: token.focus, anchorX: anchorX, width: w)
            let size = text.size()
            text.draw(at: NSPoint(x: x, y: (h - size.height) / 2 + 1))
        }

        // Progress along the bottom edge.
        Self.focusColor.withAlphaComponent(0.85).setFill()
        NSRect(x: 0, y: 0, width: (w * engine.progress).rounded(), height: 1.5).fill()

        // Right corner: speed while changing it, "Paused" when paused mid-way.
        let corner: String? = badge ?? (!isPlaying && engine.index > 0 && !engine.isAtEnd ? "Paused" : nil)
        if let corner {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor(white: 1, alpha: 0.55),
            ]
            let s = (corner as NSString).size(withAttributes: attrs)
            (corner as NSString).draw(at: NSPoint(x: w - s.width - 6, y: (h - s.height) / 2), withAttributes: attrs)
        }
    }

    // MARK: Touches

    override func touchesBegan(with event: NSEvent) {
        guard let touch = event.touches(matching: .began, in: self).first else { return }
        touchStartX = touch.location(in: self).x
        moved = false
        longPressTimer?.invalidate()
        let t = Timer(timeInterval: 0.6, repeats: false) { [weak self] _ in
            guard let self, !self.moved, self.touchStartX != nil else { return }
            self.touchStartX = nil
            if self.isPlaying { self.pause() }
            self.onLongPress?()
        }
        RunLoop.main.add(t, forMode: .common)
        longPressTimer = t
    }

    override func touchesMoved(with event: NSEvent) {
        guard let startX = touchStartX, let touch = event.touches(matching: .moved, in: self).first else { return }
        if abs(touch.location(in: self).x - startX) > 6 {
            moved = true
            longPressTimer?.invalidate()
        }
    }

    override func touchesEnded(with event: NSEvent) {
        longPressTimer?.invalidate()
        guard let startX = touchStartX, let touch = event.touches(matching: .ended, in: self).first else {
            touchStartX = nil
            return
        }
        touchStartX = nil
        let dx = touch.location(in: self).x - startX
        if dx < -24 { jump(true) }        // same direction as paging: swipe left = forward
        else if dx > 24 { jump(false) }
        else if !moved { toggle() }       // a tap
    }

    override func touchesCancelled(with event: NSEvent) {
        longPressTimer?.invalidate()
        touchStartX = nil
    }
}
