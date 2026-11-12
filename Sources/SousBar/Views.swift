import AppKit

/// Fixed-size host for the expanded bar's content.
final class BarContainer: NSView {
    var size: NSSize { didSet { invalidateIntrinsicContentSize() } }

    init(size: NSSize) {
        self.size = size
        super.init(frame: NSRect(origin: .zero, size: size))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { size }
}

/// A label whose natural width is rounded *up* to a whole point. Otherwise a stack view can
/// round e.g. 82.5 down to 82 and the text truncates ("Hold · All…") with room to spare.
final class BarLabel: NSTextField {
    override var intrinsicContentSize: NSSize {
        let s = super.intrinsicContentSize
        return NSSize(width: s.width < 0 ? s.width : ceil(s.width) + 1, height: s.height)
    }
}

/// A Touch Bar button driven by raw touches.
/// - holdDuration 0: fires on release (a tap).
/// - holdDuration > 0: fills up while held and fires only when full. Lifting early cancels.
/// onPress/onRelease are for push-to-talk.
final class HoldButton: NSView {
    var onComplete: (() -> Void)?
    /// holdDuration > 0 only: a quick tap (lifted before the hold fills up) does this instead.
    var onTap: (() -> Void)?
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    var title: String { didSet { label.stringValue = title; label.isHidden = title.isEmpty } }
    var color: NSColor { didSet { layer?.backgroundColor = color.cgColor } }
    var isEnabled = true { didSet { alphaValue = isEnabled ? 1 : 0.35 } }
    var icon: NSImage? { didSet { iconView.image = icon.map { Icon.solid($0) }; iconView.isHidden = icon == nil } }

    private let holdDuration: TimeInterval
    private let label = BarLabel(labelWithString: "")
    private let iconView = NSImageView()
    private let fill = CALayer()
    private var timer: Timer?
    private var pressStart: Date?
    private var fired = false

    /// - icon: drawn at a fixed size, left of the title (or alone when the title is empty).
    /// - iconSize: defaults to Icon.barSize so every icon on the bar matches.
    /// - twoLine: small text that wraps onto a second line instead of widening the button.
    /// Dimmer second line under a one-line title (twoLine buttons only).
    let subtitle: String?

    init(_ title: String, subtitle: String? = nil, icon: NSImage? = nil, iconSize: CGFloat = Icon.barSize,
         color: NSColor = NSColor(white: 0.28, alpha: 1), hold: TimeInterval = 0,
         width: CGFloat? = nil, twoLine: Bool = false) {
        self.subtitle = subtitle
        self.title = title
        self.color = color
        self.icon = icon
        self.holdDuration = hold
        super.init(frame: .zero)
        allowedTouchTypes = [.direct]
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        layer?.backgroundColor = color.cgColor
        fill.backgroundColor = NSColor.white.withAlphaComponent(0.35).cgColor
        fill.frame = .zero
        layer?.addSublayer(fill)

        label.stringValue = title
        label.isHidden = title.isEmpty
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        if twoLine, let subtitle, let width {
            // Title cut to one line by width, so the subtitle always gets the second line.
            let titleFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
            let room = width - 6 - iconSize - 5 - 4 - 6
            let text = NSMutableAttributedString(
                string: TextTools.truncate(title, toWidth: room, font: titleFont) + "\n",
                attributes: [.font: titleFont, .foregroundColor: NSColor.white])
            text.append(NSAttributedString(string: TextTools.truncate(subtitle, toWidth: room, font: .systemFont(ofSize: 11)),
                                           attributes: [.font: NSFont.systemFont(ofSize: 11),
                                                        .foregroundColor: NSColor(white: 1, alpha: 0.6)]))
            label.attributedStringValue = text
            label.maximumNumberOfLines = 2
            label.lineBreakMode = .byClipping
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        } else if twoLine {
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.alignment = .left
            label.maximumNumberOfLines = 2
            label.lineBreakMode = .byWordWrapping
            label.cell?.truncatesLastVisibleLine = true
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        } else {
            label.font = .systemFont(ofSize: 14, weight: .medium)
            label.alignment = .center
            label.lineBreakMode = .byTruncatingTail
        }

        iconView.image = icon.map { Icon.solid($0) } // pure white, as bright as the labels
        iconView.isHidden = icon == nil
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.contentTintColor = .white
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let content = NSStackView(views: [iconView, label])
        content.orientation = .horizontal
        content.spacing = twoLine ? 5 : 4
        content.alignment = .centerY
        content.detachesHiddenViews = true
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        translatesAutoresizingMaskIntoConstraints = false
        var constraints = [
            iconView.widthAnchor.constraint(equalToConstant: iconSize),
            iconView.heightAnchor.constraint(equalToConstant: iconSize),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: twoLine ? 6 : 8),
            content.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: twoLine ? -4 : -8),
            heightAnchor.constraint(equalToConstant: 30),
        ]
        constraints.append(twoLine ? content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6)
                                   : content.centerXAnchor.constraint(equalTo: centerXAnchor))
        if let width {
            constraints.append(widthAnchor.constraint(equalToConstant: width))
        } else {
            constraints.append(widthAnchor.constraint(greaterThanOrEqualToConstant: 44))
            // Hug the content so free space goes to the text strip, not to buttons.
            let snug = widthAnchor.constraint(equalTo: content.widthAnchor, constant: 16)
            snug.priority = .defaultHigh
            constraints.append(snug)
        }
        NSLayoutConstraint.activate(constraints)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func touchesBegan(with event: NSEvent) {
        guard isEnabled else { return }
        fired = false
        pressStart = Date()
        layer?.backgroundColor = (color.highlight(withLevel: 0.25) ?? color).cgColor
        onPress?()
        if holdDuration > 0 {
            let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    private func tick() {
        guard let start = pressStart else { return }
        let progress = min(1, Date().timeIntervalSince(start) / holdDuration)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = CGRect(x: 0, y: 0, width: bounds.width * CGFloat(progress), height: bounds.height)
        CATransaction.commit()
        if progress >= 1, !fired {
            fired = true
            timer?.invalidate()
            timer = nil
            onComplete?()
        }
    }

    override func touchesEnded(with event: NSEvent) { finishTouch(cancelled: false) }
    override func touchesCancelled(with event: NSEvent) { finishTouch(cancelled: true) }

    private func finishTouch(cancelled: Bool) {
        timer?.invalidate()
        timer = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = .zero
        CATransaction.commit()
        layer?.backgroundColor = color.cgColor
        guard pressStart != nil, isEnabled else { return }
        pressStart = nil
        onRelease?()
        if holdDuration == 0, !cancelled { onComplete?() }
        if holdDuration > 0, !fired, !cancelled { onTap?() }
    }
}

/// One line of text you page through by swiping left/right.
/// Tap does nothing on purpose. Long-press opens the reader panel.
final class PagedTextView: NSView {
    var onLongPress: (() -> Void)?

    private(set) var text = ""
    private var pages: [String] = [""]
    private var page = 0
    private var showLastPage = false
    private let label = NSTextField(labelWithString: "")
    private let counter = NSTextField(labelWithString: "")
    private let font = NSFont.systemFont(ofSize: 14)
    private var lastWidth: CGFloat = 0
    private var touchStartX: CGFloat?
    private var moved = false
    private var longPressTimer: Timer?

    // "Working" animation: a Claude-style spinner glyph plus shimmering orange text.
    private let glyph = NSTextField(labelWithString: "")
    private var glyphWidth: NSLayoutConstraint!
    private var activityTimer: Timer?
    private var activityText: String?   // nil = rotating verbs
    private var tick = 0
    private(set) var isAnimating = false

    init() {
        super.init(frame: .zero)
        allowedTouchTypes = [.direct]
        wantsLayer = true
        // Swiping slides the text sideways; clip it so it never draws over the chip or buttons.
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false

        glyph.font = .systemFont(ofSize: 15, weight: .bold)
        glyph.alignment = .center
        glyph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyph)
        glyphWidth = glyph.widthAnchor.constraint(equalToConstant: 0)

        label.font = font
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.wantsLayer = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        counter.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        counter.textColor = NSColor(white: 1, alpha: 0.5)
        counter.alignment = .right
        counter.translatesAutoresizingMaskIntoConstraints = false

        addSubview(label)
        addSubview(counter)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyphWidth,
            label.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: counter.leadingAnchor, constant: -6),
            counter.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            counter.centerYAnchor.constraint(equalTo: centerYAnchor),
            counter.widthAnchor.constraint(equalToConstant: 40),
        ])
        setContentHuggingPriority(.init(1), for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// `followTail` keeps the last page visible (for live dictation).
    func setText(_ newText: String, followTail: Bool = false) {
        stopActivity()
        guard newText != text || followTail != showLastPage else { return }
        text = newText
        showLastPage = followTail
        page = 0
        repaginate()
    }

    // MARK: Working animation

    /// Shows Claude is busy: `detail` (e.g. "Bash: npm test") or, when nil, rotating verbs.
    func setActivity(_ detail: String?) {
        if isAnimating, detail == activityText { return }
        activityText = detail
        isAnimating = true
        glyphWidth.constant = 16
        text = ""
        counter.stringValue = ""
        label.stringValue = activityLine()
        startActivityTimer()
        animateFrame()
    }

    private func stopActivity() {
        guard isAnimating else { return }
        isAnimating = false
        activityTimer?.invalidate()
        activityTimer = nil
        glyph.stringValue = ""
        glyphWidth.constant = 0
        label.textColor = .white
        text = "\u{0}" // force the next setText to render
    }

    private func activityLine() -> String {
        if let activityText { return "Running \(activityText)" }
        return ActivityStyle.verbs[(tick / ActivityStyle.ticksPerVerb) % ActivityStyle.verbs.count] + "…"
    }

    private func startActivityTimer() {
        guard activityTimer == nil, superview != nil else { return } // not window: see SpeedReaderView.schedule
        let t = Timer(timeInterval: ActivityStyle.interval, repeats: true) { [weak self] _ in self?.animateFrame() }
        RunLoop.main.add(t, forMode: .common)
        activityTimer = t
    }

    private func animateFrame() {
        tick += 1
        glyph.stringValue = ActivityStyle.glyph(at: tick)
        let color = ActivityStyle.color(at: tick)
        glyph.textColor = color
        label.textColor = color
        let line = activityLine()
        if line != label.stringValue {
            let fade = CATransition()
            fade.type = .push
            fade.subtype = .fromTop
            fade.duration = 0.25
            label.layer?.add(fade, forKey: "verb")
            label.stringValue = line
        }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if superview == nil {
            activityTimer?.invalidate()
            activityTimer = nil
        } else if isAnimating {
            startActivityTimer()
        }
    }

    deinit { activityTimer?.invalidate() }

    private var textWidth: CGFloat {
        let w = bounds.width - 6 - 6 - 40 - 4
        return w > 60 ? w : 560
    }

    private func repaginate() {
        pages = TextTools.paginate(text, width: textWidth, font: font)
        page = showLastPage ? pages.count - 1 : min(page, pages.count - 1)
        render()
    }

    override func layout() {
        super.layout()
        if abs(bounds.width - lastWidth) > 1 {
            lastWidth = bounds.width
            repaginate()
        }
    }

    private func render() {
        guard !isAnimating else { return }
        label.stringValue = pages[page]
        counter.stringValue = pages.count > 1 ? "\(page + 1)/\(pages.count)" : ""
    }

    private func go(_ delta: Int) {
        let target = page + delta
        guard target >= 0, target < pages.count else { return }
        page = target
        let transition = CATransition()
        transition.type = .push
        transition.subtype = delta > 0 ? .fromRight : .fromLeft
        transition.duration = 0.18
        label.layer?.add(transition, forKey: "page")
        render()
    }

    private func setDragOffset(_ dx: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        label.layer?.setAffineTransform(CGAffineTransform(translationX: dx, y: 0))
        CATransaction.commit()
    }

    override func touchesBegan(with event: NSEvent) {
        guard let touch = event.touches(matching: .began, in: self).first else { return }
        touchStartX = touch.location(in: self).x
        moved = false
        longPressTimer?.invalidate()
        let t = Timer(timeInterval: 0.6, repeats: false) { [weak self] _ in
            guard let self, !self.moved, self.touchStartX != nil else { return }
            self.touchStartX = nil
            self.onLongPress?()
        }
        RunLoop.main.add(t, forMode: .common)
        longPressTimer = t
    }

    override func touchesMoved(with event: NSEvent) {
        guard let startX = touchStartX, let touch = event.touches(matching: .moved, in: self).first else { return }
        let dx = touch.location(in: self).x - startX
        if abs(dx) > 6 {
            moved = true
            longPressTimer?.invalidate()
        }
        setDragOffset(dx * 0.4)
    }

    override func touchesEnded(with event: NSEvent) {
        longPressTimer?.invalidate()
        setDragOffset(0)
        guard let startX = touchStartX, let touch = event.touches(matching: .ended, in: self).first else {
            touchStartX = nil
            return
        }
        touchStartX = nil
        let dx = touch.location(in: self).x - startX
        if dx < -24 { go(1) } else if dx > 24 { go(-1) }
    }

    override func touchesCancelled(with event: NSEvent) {
        longPressTimer?.invalidate()
        touchStartX = nil
        setDragOffset(0)
    }
}

/// The look of the "Claude is working" animation, kept separate so it can be tested.
enum ActivityStyle {
    /// Grows and shrinks like Claude Code's own spinner.
    static let glyphs = ["·", "✢", "✳", "✶", "✻", "✽"]
    /// Chef-hat themed, to match the app icon.
    static let verbs = ["Cooking", "Simmering", "Whisking", "Seasoning", "Stirring", "Tasting", "Plating"]
    static let interval: TimeInterval = 0.12
    static let ticksPerVerb = 25 // ~3 s

    static let orange = NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1) // #D97757
    static let peach = NSColor(srgbRed: 0.98, green: 0.78, blue: 0.68, alpha: 1)

    /// Ping-pongs through the glyphs: · ✢ ✳ ✶ ✻ ✽ ✻ ✶ ✳ ✢ · …
    static func glyph(at tick: Int) -> String {
        let period = glyphs.count * 2 - 2
        let i = tick % period
        return glyphs[i < glyphs.count ? i : period - i]
    }

    /// Shimmers between orange and peach about once every 2 s.
    static func color(at tick: Int) -> NSColor {
        let phase = (sin(Double(tick) * interval * .pi) + 1) / 2
        return orange.blended(withFraction: CGFloat(phase), of: peach) ?? orange
    }
}
