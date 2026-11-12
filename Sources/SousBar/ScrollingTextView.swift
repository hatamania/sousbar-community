import AppKit

/// Scroll position math for `ScrollingTextView`, kept apart so it can be tested.
struct ScrollPhysics {
    /// How far you can scroll: text width minus what fits. Never negative.
    var maxOffset: CGFloat
    var offset: CGFloat = 0
    /// Points per second, positive = toward the end of the text.
    var velocity: CGFloat = 0

    /// Per second, how much of the velocity is kept while coasting (a phone-like glide).
    static let decelerationPerSecond: CGFloat = 0.06
    static let minVelocity: CGFloat = 12
    /// How hard dragging past an end resists (0…1, lower = stiffer).
    static let rubberBand: CGFloat = 0.35

    /// Finger moved by `dx` points (positive = finger moved right = back toward the start).
    mutating func drag(by dx: CGFloat) {
        let outside = offset < 0 || offset > maxOffset
        offset -= outside ? dx * Self.rubberBand : dx
    }

    /// Finger lifted. `fingerVelocity` is the finger's speed (positive = moving right).
    mutating func release(fingerVelocity: CGFloat) {
        velocity = -fingerVelocity
    }

    /// Advances the glide by `dt` seconds. Returns false once it has come to rest.
    mutating func step(_ dt: CGFloat) -> Bool {
        // Past an end: spring back.
        if offset < 0 || offset > maxOffset {
            let target = offset < 0 ? 0 : maxOffset
            velocity = 0
            offset += (target - offset) * min(1, dt * 14)
            if abs(target - offset) < 0.5 { offset = target; return false }
            return true
        }
        guard abs(velocity) > Self.minVelocity else { velocity = 0; return false }
        offset += velocity * dt
        velocity *= pow(Self.decelerationPerSecond, dt)
        if offset < 0 || offset > maxOffset {
            // Hit an end while gliding: stop there instead of flying past.
            offset = min(max(offset, 0), maxOffset)
            velocity = 0
            return false
        }
        return true
    }

    /// 0 at the start, 1 at the end.
    var progress: CGFloat { maxOffset > 0 ? min(1, max(0, offset / maxOffset)) : 1 }
}

/// One line of text you scroll through continuously: it follows your finger and keeps gliding
/// when you let go, like a list on a phone. A thin bar along the bottom shows where you are.
/// (PagedTextView, used for Claude's replies, jumps a page per swipe instead.)
final class ScrollingTextView: NSView {
    /// Called when you start touching it.
    var onInteract: (() -> Void)?
    /// Called with the new offset whenever it settles, so a rebuilt view can pick up where you were.
    var onScroll: ((CGFloat) -> Void)?

    /// The text shown (for tests and accessibility).
    let string: String
    private let line: CTLine
    private let textWidth: CGFloat
    private let ascent: CGFloat
    private let descent: CGFloat
    private var physics: ScrollPhysics
    private var lastX: CGFloat?
    private var samples: [(time: TimeInterval, x: CGFloat)] = []
    private var glide: Timer?
    private static let inset: CGFloat = 6

    var offset: CGFloat { physics.offset }
    var maxOffset: CGFloat { physics.maxOffset }

    init(_ text: NSAttributedString, offset: CGFloat = 0) {
        string = text.string
        line = CTLineCreateWithAttributedString(text)
        var a: CGFloat = 0, d: CGFloat = 0, l: CGFloat = 0
        textWidth = CGFloat(CTLineGetTypographicBounds(line, &a, &d, &l))
        ascent = a
        descent = d
        physics = ScrollPhysics(maxOffset: 0, offset: offset)
        super.init(frame: .zero)
        allowedTouchTypes = [.direct]
        wantsLayer = true
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 30).isActive = true
        widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        setContentHuggingPriority(.init(2), for: .horizontal)
        setContentCompressionResistancePriority(.init(1), for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { glide?.invalidate() }

    override var intrinsicContentSize: NSSize { NSSize(width: textWidth + Self.inset * 2, height: 30) }

    override func layout() {
        super.layout()
        physics.maxOffset = max(0, textWidth + Self.inset * 2 - bounds.width)
        physics.offset = min(max(physics.offset, 0), physics.maxOffset)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: Self.inset - physics.offset, y: (bounds.height - ascent - descent) / 2 + descent + 1)
        CTLineDraw(line, ctx)
        ctx.restoreGState()

        // Fade the text out at an edge that has more beyond it (the Touch Bar is black).
        let fade: CGFloat = 18
        if let space = CGColorSpace(name: CGColorSpace.sRGB),
           let g = CGGradient(colorsSpace: space, colors: [CGColor(red: 0, green: 0, blue: 0, alpha: 1),
                                                          CGColor(red: 0, green: 0, blue: 0, alpha: 0)] as CFArray,
                              locations: [0, 1]) {
            let band = CGRect(x: 0, y: 4, width: bounds.width, height: bounds.height - 4)
            if physics.offset > 1 {
                ctx.saveGState()
                ctx.clip(to: band)
                ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: 0), end: CGPoint(x: fade, y: 0), options: [])
                ctx.restoreGState()
            }
            if physics.offset < physics.maxOffset - 1 {
                ctx.saveGState()
                ctx.clip(to: band)
                ctx.drawLinearGradient(g, start: CGPoint(x: bounds.width, y: 0),
                                       end: CGPoint(x: bounds.width - fade, y: 0), options: [])
                ctx.restoreGState()
            }
        }

        // Where you are: a thin track with a bright segment, only when there's more to read.
        guard physics.maxOffset > 0 else { return }
        let track = NSRect(x: Self.inset, y: 1, width: bounds.width - Self.inset * 2, height: 2)
        NSColor(white: 1, alpha: 0.15).setFill()
        NSBezierPath(roundedRect: track, xRadius: 1, yRadius: 1).fill()
        let thumbWidth = max(24, track.width * bounds.width / (textWidth + Self.inset * 2))
        let thumb = NSRect(x: track.minX + (track.width - thumbWidth) * physics.progress, y: 1, width: thumbWidth, height: 2)
        NSColor(white: 1, alpha: 0.6).setFill()
        NSBezierPath(roundedRect: thumb, xRadius: 1, yRadius: 1).fill()
    }

    // MARK: Touches

    override func touchesBegan(with event: NSEvent) {
        guard let touch = event.touches(matching: .began, in: self).first else { return }
        glide?.invalidate()
        physics.velocity = 0
        let x = touch.location(in: self).x
        lastX = x
        samples = [(event.timestamp, x)]
        onInteract?()
    }

    override func touchesMoved(with event: NSEvent) {
        guard let last = lastX, let touch = event.touches(matching: .moved, in: self).first else { return }
        let x = touch.location(in: self).x
        physics.drag(by: x - last)
        lastX = x
        samples.append((event.timestamp, x))
        samples.removeAll { event.timestamp - $0.time > 0.1 } // velocity from the last 100 ms
        needsDisplay = true
    }

    override func touchesEnded(with event: NSEvent) {
        guard lastX != nil else { return }
        lastX = nil
        var v: CGFloat = 0
        if let first = samples.first, let last = samples.last, last.time - first.time > 0.01 {
            v = (last.x - first.x) / CGFloat(last.time - first.time)
        }
        physics.release(fingerVelocity: v)
        startGlide()
    }

    override func touchesCancelled(with event: NSEvent) {
        lastX = nil
        physics.velocity = 0
        startGlide() // springs back if you were past an end
    }

    private func startGlide() {
        glide?.invalidate()
        let dt: CGFloat = 1.0 / 60
        let t = Timer(timeInterval: TimeInterval(dt), repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            let moving = self.physics.step(dt)
            self.needsDisplay = true
            if !moving {
                timer.invalidate()
                self.onScroll?(self.physics.offset)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        glide = t
    }
}
