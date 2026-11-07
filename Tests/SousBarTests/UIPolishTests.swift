import AppKit
import XCTest
@testable import SousBar

final class SVGPathTests: XCTestCase {
    func testAbsoluteSquare() {
        let b = SVGPath.parse("M1 2 H11 V12 H1 Z").boundingBoxOfPath
        XCTAssertEqual(b, CGRect(x: 1, y: 2, width: 10, height: 10))
    }

    func testRelativeCommandsAndPackedNumbers() {
        // l5.305-5.305 and c-1-2.5.5 style packing (no separators before "-" or a second ".")
        let b = SVGPath.parse("M10 10l5-5h-10v.5.5z").boundingBoxOfPath
        XCTAssertEqual(b.minX, 5, accuracy: 0.001)
        XCTAssertEqual(b.maxX, 15, accuracy: 0.001)
        XCTAssertEqual(b.minY, 5, accuracy: 0.001)
        XCTAssertEqual(b.maxY, 10, accuracy: 0.001)
    }

    func testImplicitLineToAfterMove() {
        let b = SVGPath.parse("M0 0 10 0 10 10z").boundingBoxOfPath
        XCTAssertEqual(b, CGRect(x: 0, y: 0, width: 10, height: 10))
    }

    func testSmoothCurveReflectsControlPoint() {
        let path = SVGPath.parse("M0 0 C0 10 10 10 10 0 S20 -10 20 0")
        XCTAssertEqual(path.boundingBoxOfPath.maxX, 20, accuracy: 0.001)
        XCTAssertLessThan(path.boundingBoxOfPath.minY, 0, "the S segment dips below 0")
    }

    func testGarbageDoesNotHang() {
        _ = SVGPath.parse("Q1 2 3 4 A 1 1 0 0 1 5 5 ,, M")
        _ = SVGPath.parse("")
    }
}

final class IconTests: XCTestCase {
    /// Pixel extent of the drawn ink, at 2x.
    private func inkExtent(_ image: NSImage, size: CGFloat) -> CGSize {
        let px = Int(size * 2)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        var minX = px, minY = px, maxX = -1, maxY = -1
        for y in 0..<px { for x in 0..<px where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.3 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        } }
        return maxX < 0 ? .zero : CGSize(width: maxX - minX + 1, height: maxY - minY + 1)
    }

    static let barIcons: [(String, Icon)] = [
        ("chef", .chefHat), ("mic", .mic), ("hide", .hide), ("play", .play), ("pause", .pause),
        ("jump", .symbol("arrow.up.right.square")),
        ("model", .symbol("cpu")), ("sessions", .symbol("list.bullet")), ("back", .symbol("chevron.left")),
    ]

    func testEveryBarIconFillsTheSameBox() {
        let size = Icon.barSize
        for (name, icon) in Self.barIcons where name != "back" { // a chevron is meant to be thin
            let ink = inkExtent(icon.image(size: size, color: .black), size: size)
            let longest = max(ink.width, ink.height)
            XCTAssertGreaterThan(longest, size * 2 * 0.85, "\(name) is drawn too small: \(ink)")
            XCTAssertLessThanOrEqual(longest, size * 2, name)
        }
    }

    /// On the real bar template icons came out at 76% brightness next to 100% white text.
    func testBarButtonIconsArePureWhite() throws {
        let b = HoldButton("", icon: Icon.mic.image(), width: 44)
        let shown = try XCTUnwrap(b.subviews.flatMap(\.subviews).compactMap { ($0 as? NSImageView)?.image }.first)
        XCTAssertFalse(shown.isTemplate, "the Touch Bar can't dim a non-template image")
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 36, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        shown.draw(in: NSRect(x: 0, y: 0, width: 36, height: 36))
        NSGraphicsContext.restoreGraphicsState()
        var brightest: CGFloat = 0
        for x in 0..<36 { for y in 0..<36 {
            if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.95 { brightest = max(brightest, c.brightnessComponent) }
        } }
        XCTAssertGreaterThan(brightest, 0.98)
        XCTAssertTrue(Icon.solid(Icon.dot(.green)) .isTemplate == false, "colored images pass through")
    }

    func testTemplateUnlessColored() {
        XCTAssertTrue(Icon.mic.image().isTemplate)
        XCTAssertFalse(Icon.mic.image(color: .red).isTemplate)
        XCTAssertFalse(Icon.dot(.green).isTemplate)
    }

    func testAppIconPNGs() throws {
        let data = try XCTUnwrap(AppIcon.png(pixels: 64))
        let rep = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(rep.pixelsWide, 64)
        XCTAssertEqual(rep.colorAt(x: 0, y: 0)?.alphaComponent ?? 1, 0, accuracy: 0.01, "corners are transparent")
        let dir = NSTemporaryDirectory() + "iconset-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        XCTAssertTrue(AppIcon.writeIconset(to: dir))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir).count, 10)
    }

    /// Set SOUSBAR_ICON_PREVIEW=/path.png to get a strip of every bar icon for a visual check.
    func testWritePreviewWhenAsked() throws {
        guard let out = ProcessInfo.processInfo.environment["SOUSBAR_ICON_PREVIEW"] else { return }
        let cell: CGFloat = 44, scale: CGFloat = 4
        let w = Int(cell * CGFloat(Self.barIcons.count) * scale), h = Int(30 * scale)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.black.setFill(); NSRect(x: 0, y: 0, width: w, height: h).fill()
        for (i, (_, icon)) in Self.barIcons.enumerated() {
            let x = CGFloat(i) * cell * scale
            NSColor(white: 0.28, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: x + 2 * scale, y: 0, width: (cell - 4) * scale, height: 30 * scale),
                         xRadius: 6 * scale, yRadius: 6 * scale).fill()
            let s = Icon.barSize * scale
            icon.image(size: s, color: .white).draw(in: NSRect(x: x + (cell * scale - s) / 2, y: (30 * scale - s) / 2, width: s, height: s))
        }
        NSGraphicsContext.restoreGraphicsState()
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: out))
    }
}

final class ActivityStyleTests: XCTestCase {
    func testGlyphsPingPong() {
        let seq = (0..<12).map(ActivityStyle.glyph(at:))
        XCTAssertEqual(seq, ["·", "✢", "✳", "✶", "✻", "✽", "✻", "✶", "✳", "✢", "·", "✢"])
    }

    func testColorStaysBetweenOrangeAndPeach() {
        for tick in 0..<40 {
            let c = ActivityStyle.color(at: tick).usingColorSpace(.sRGB)!
            XCTAssertGreaterThanOrEqual(c.redComponent, 0.85 - 0.001)
            XCTAssertLessThanOrEqual(c.redComponent, 0.98 + 0.001)
        }
    }

    func testPagerAnimatesThenStopsOnText() {
        let pager = PagedTextView()
        pager.setActivity(nil)
        XCTAssertTrue(pager.isAnimating)
        pager.setActivity("Bash: make")
        XCTAssertTrue(pager.isAnimating)
        pager.setText("Done")
        XCTAssertFalse(pager.isAnimating)
        XCTAssertEqual(pager.text, "Done")
    }

    func testPagerClipsSwipedText() {
        XCTAssertEqual(PagedTextView().layer?.masksToBounds, true)
    }
}

final class SessionStatusTests: XCTestCase {
    private func session(_ state: AgentState, unread: Bool = false) -> AgentSession {
        let s = AgentSession(id: "x")
        s.state = state
        s.unread = unread
        return s
    }

    func testStatuses() {
        XCTAssertEqual(session(.idle).status(hasPending: true), .needsYou)
        XCTAssertEqual(session(.waiting("in terminal")).status(hasPending: false), .inTerminal)
        XCTAssertEqual(session(.thinking).status(hasPending: false), .working)
        XCTAssertEqual(session(.tool("Bash")).status(hasPending: false), .working)
        XCTAssertEqual(session(.done, unread: true).status(hasPending: false), .newReply)
        XCTAssertEqual(session(.done).status(hasPending: false), .idle)
        XCTAssertEqual(session(.idle).status(hasPending: false), .idle)
    }

    func testDotColorsAreDistinct() {
        let all: [SessionStatus] = [.needsYou, .inTerminal, .working, .newReply, .idle]
        XCTAssertEqual(Set(all.map { TouchBarController.color(for: $0) }).count, all.count)
    }

    func testModelMatching() {
        XCTAssertTrue(ModelChoice.matches("claude-opus-5-5", "opus"))
        XCTAssertTrue(ModelChoice.matches("Sonnet[1m]", "sonnet"))
        XCTAssertFalse(ModelChoice.matches("claude-haiku-5-5", "opus"))
        XCTAssertFalse(ModelChoice.matches(nil, "opus"))
        XCTAssertEqual(ModelChoice.efforts, ["low", "medium", "high", "xhigh", "max"])
    }

    func testSessionStartRecordsModel() {
        let store = Store()
        store.handle(["event": "SessionStart", "input": ["session_id": "s", "model": "claude-opus-5-5"]], reply: nil)
        XCTAssertEqual(store.session("s")?.model, "claude-opus-5-5")
    }
}

final class HoldButtonLayoutTests: XCTestCase {
    /// Regression: "Hold · Allow" (82.5 pt) was rounded to 82 pt and truncated in a 128 pt button.
    func testLabelsNeverRoundDownIntoTruncation() {
        for (title, width) in [("Hold · Allow", 128.0), ("Hold · Always", 136.0), ("→ Term", 72.0), ("Deny", 70.0)] {
            let b = HoldButton(title, hold: 0.7, width: width)
            let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 30))
            host.addSubview(b)
            host.layoutSubtreeIfNeeded()
            let label = b.subviews.flatMap(\.subviews).compactMap { $0 as? NSTextField }.first!
            let needed = label.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: 10_000, height: 30)).width
            XCTAssertGreaterThanOrEqual(label.frame.width, needed, title)
        }
    }

    func testIconOnlyButtonHasNoLabelSpace() {
        let b = HoldButton("", icon: Icon.hide.image(), width: 44)
        XCTAssertEqual(b.title, "")
        XCTAssertNotNil(b.icon)
    }
}

final class TruncateToWidthTests: XCTestCase {
    private let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
    private func width(_ s: String) -> CGFloat { ceil((s as NSString).size(withAttributes: [.font: font]).width) }

    func testFitsUntouched() {
        XCTAssertEqual(TextTools.truncate("web", toWidth: 100, font: font), "web")
    }

    func testCutsToWidthWithEllipsis() {
        let out = TextTools.truncate("Audit app features and suggest the next move", toWidth: 100, font: font)
        XCTAssertTrue(out.hasSuffix("…"))
        XCTAssertLessThanOrEqual(width(out), 100)
        XCTAssertGreaterThan(out.count, 8, "uses the room it has")
        XCTAssertFalse(out.contains(" …"), "no space before the ellipsis")
    }

    func testTinyWidth() {
        XCTAssertEqual(TextTools.truncate("abcdef", toWidth: 1, font: font), "…")
    }
}
