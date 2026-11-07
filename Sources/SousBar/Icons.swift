import AppKit

/// Parses the subset of SVG path syntax our icons use (M L H V C S Z, absolute and relative).
enum SVGPath {
    static func parse(_ d: String) -> CGPath {
        let path = CGMutablePath()
        var tokens = tokenize(d)[...]
        var cmd: Character = "M"
        var cur = CGPoint.zero, start = CGPoint.zero, lastCtrl: CGPoint?

        func num() -> CGFloat {
            guard case let .number(n)? = tokens.first else { return 0 }
            tokens.removeFirst()
            return n
        }
        func point(_ rel: Bool) -> CGPoint {
            let x = num(), y = num()
            return rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y)
        }

        while let token = tokens.first {
            if case let .command(c) = token {
                cmd = c
                tokens.removeFirst()
            }
            let rel = cmd.isLowercase
            switch cmd.uppercased().first! {
            case "M":
                cur = point(rel); start = cur
                path.move(to: cur)
                cmd = rel ? "l" : "L" // further pairs are implicit line-tos
                lastCtrl = nil
            case "L":
                cur = point(rel); path.addLine(to: cur); lastCtrl = nil
            case "H":
                let x = num(); cur.x = rel ? cur.x + x : x; path.addLine(to: cur); lastCtrl = nil
            case "V":
                let y = num(); cur.y = rel ? cur.y + y : y; path.addLine(to: cur); lastCtrl = nil
            case "C":
                let c1 = point(rel), c2 = point(rel), end = point(rel)
                path.addCurve(to: end, control1: c1, control2: c2)
                lastCtrl = c2; cur = end
            case "S":
                let c1 = lastCtrl.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                let c2 = point(rel), end = point(rel)
                path.addCurve(to: end, control1: c1, control2: c2)
                lastCtrl = c2; cur = end
            case "Z":
                path.closeSubpath(); cur = start; lastCtrl = nil
                if case .number? = tokens.first { tokens.removeFirst() } // malformed; skip
            default:
                tokens.removeFirst() // unsupported command; skip its numbers
            }
        }
        return path
    }

    private enum Token { case command(Character), number(CGFloat) }

    private static func tokenize(_ d: String) -> [Token] {
        var out: [Token] = []
        var numberText = ""
        func flush() {
            if let n = Double(numberText) { out.append(.number(CGFloat(n))) }
            numberText = ""
        }
        for ch in d {
            if ch.isLetter, ch != "e", ch != "E" {
                flush(); out.append(.command(ch))
            } else if ch == "-", !numberText.isEmpty, numberText.last != "e", numberText.last != "E" {
                flush(); numberText = "-"
            } else if ch == ".", numberText.contains("."), !numberText.contains("e") {
                flush(); numberText = "." // "0.5.5" means 0.5 then .5
            } else if ch.isNumber || ch == "." || ch == "-" || ch == "e" || ch == "E" {
                numberText.append(ch)
            } else {
                flush() // separators: space, comma, newline, tab
            }
        }
        flush()
        return out
    }
}

/// Every icon in the app, drawn from vector paths so they stay sharp and are the same size.
enum Icon {
    case chefHat, mic, hide, play, pause
    case symbol(String)

    /// The icon on the pill, in the menu bar and as the app icon.
    static let app = Icon.chefHat

    fileprivate var path: (CGPath, CGPathFillRule)? {
        switch self {
        case .chefHat:
            return (SVGPath.parse("""
            M7 5C4.23858 5 2 7.23858 2 10C2 12.0503 3.2341 13.8124 5 14.584V17.25H19L19 14.584C20.7659 13.8124 22 12.0503 22 10C22 7.23858 19.7614 5 17 5C16.7495 5 16.5033 5.01842 16.2626 5.05399C15.6604 3.27806 13.9794 2 12 2C10.0206 2 8.33961 3.27806 7.73736 5.05399C7.49673 5.01842 7.25052 5 7 5Z
            M18.9983 18.75H5.00169C5.01188 20.1469 5.08343 20.9119 5.58579 21.4142C6.17157 22 7.11438 22 9 22H15C16.8856 22 17.8284 22 18.4142 21.4142C18.9166 20.9119 18.9881 20.1469 18.9983 18.75Z
            """), .winding)
        case .mic:
            return (SVGPath.parse("""
            M118,333 C121.866,333 125,329.866 125,326 L125,316 C125,312.134 121.866,309 118,309 C114.134,309 111,312.134 111,316 L111,326 C111,329.866 114.134,333 118,333 L118,333 Z M129,328 L127,328 C126.089,332.007 122.282,335 118,335 C113.718,335 109.911,332.007 109,328 L107,328 C107.883,332.799 112.063,336.51 117,336.955 L117,339 L116,339 C115.448,339 115,339.448 115,340 C115,340.553 115.448,341 116,341 L120,341 C120.552,341 121,340.553 121,340 C121,339.448 120.552,339 120,339 L119,339 L119,336.955 C123.937,336.51 128.117,332.799 129,328 L129,328 Z
            """), .evenOdd)
        case .hide:
            return (SVGPath.parse("""
            M11.957,33.214L7.171,38L10,40.828l5.305-5.305C17.867,36.992,20.788,38,24,38c12,0,20-14,20-14s-2.953-5.159-7.957-9.214
            L40.829,10L38,7.172l-5.305,5.305C30.133,11.008,27.212,10,24,10C12,10,4,24,4,24S6.953,29.159,11.957,33.214z M16,24
            c0-4.418,3.582-8,8-8c1.483,0,2.867,0.411,4.058,1.114l-3.035,3.035C24.694,20.062,24.356,20,24,20c-2.206,0-4,1.794-4,4
            c0,0.356,0.062,0.694,0.149,1.023l-3.035,3.035C16.411,26.867,16,25.483,16,24z M32,24c0,4.418-3.582,8-8,8
            c-1.483,0-2.867-0.411-4.058-1.114l3.035-3.035C23.306,27.938,23.644,28,24,28c2.206,0,4-1.794,4-4
            c0-0.356-0.062-0.694-0.149-1.023l3.035-3.035C31.589,21.133,32,22.517,32,24z
            """), .winding)
        case .play:
            return (SVGPath.parse("""
            M296.494737,3608.57322 L292.500752,3606.14219 C291.83208,3605.73542 291,3606.25002 291,3607.06891 L291,3611.93095 C291,3612.7509 291.83208,3613.26444 292.500752,3612.85767 L296.494737,3610.42771 C297.168421,3610.01774 297.168421,3608.98319 296.494737,3608.57322
            """), .evenOdd)
        case .pause:
            return (SVGPath.parse("""
            M172,3605 C171.448,3605 171,3605.448 171,3606 L171,3612 C171,3612.552 171.448,3613 172,3613 C172.552,3613 173,3612.552 173,3612 L173,3606 C173,3605.448 172.552,3605 172,3605 M177,3606 L177,3612 C177,3612.552 176.552,3613 176,3613 C175.448,3613 175,3612.552 175,3612 L175,3606 C175,3605.448 175.448,3605 176,3605 C176.552,3605 177,3605.448 177,3606
            """), .evenOdd)
        case .symbol:
            return nil
        }
    }

    /// The default size of every button icon on the bar.
    static let barSize: CGFloat = 18

    /// The icon scaled to fit a `size`×`size` box, centered. Without `color` it's a
    /// template image, so the Touch Bar and menu bar tint it for light/dark.
    func image(size: CGFloat = Icon.barSize, color: NSColor? = nil) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            self.draw(in: rect, color: color ?? .black)
            return true
        }
        image.isTemplate = color == nil
        return image
    }

    /// Draws aspect-fit into `rect` (a flipped, y-down context).
    func draw(in rect: CGRect, color: NSColor) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if let (path, rule) = path {
            let b = path.boundingBoxOfPath
            let scale = min(rect.width / b.width, rect.height / b.height)
            ctx.saveGState()
            ctx.translateBy(x: rect.midX - b.midX * scale, y: rect.midY - b.midY * scale)
            ctx.scaleBy(x: scale, y: scale)
            ctx.addPath(path)
            ctx.setFillColor(color.cgColor)
            ctx.fillPath(using: rule)
            ctx.restoreGState()
        } else if case let .symbol(name) = self, let mask = Self.trimmedSymbol(name) {
            // SF Symbols carry built-in padding; fit only the ink so they match the vector icons.
            let s = CGSize(width: mask.width, height: mask.height)
            let scale = min(rect.width / s.width, rect.height / s.height)
            let fitted = CGRect(x: rect.midX - s.width * scale / 2, y: rect.midY - s.height * scale / 2,
                                width: s.width * scale, height: s.height * scale)
            ctx.saveGState()
            // Flipped context: flip back locally so the bitmap isn't drawn upside down.
            ctx.translateBy(x: 0, y: fitted.maxY + fitted.minY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.clip(to: fitted, mask: mask)
            ctx.setFillColor(color.cgColor)
            ctx.fill(fitted)
            ctx.restoreGState()
        }
    }

    private static var symbolCache: [String: CGImage] = [:]

    /// The symbol rendered large, then cropped to its non-transparent pixels, as an alpha mask.
    private static func trimmedSymbol(_ name: String) -> CGImage? {
        if let cached = symbolCache[name] { return cached }
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 64, weight: .medium)) else { return nil }
        let w = Int(ceil(symbol.size.width)) + 4, h = Int(ceil(symbol.size.height)) + 4
        guard let rgba = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: rgba, flipped: false)
        symbol.draw(in: CGRect(x: 2, y: 2, width: symbol.size.width, height: symbol.size.height))
        NSGraphicsContext.restoreGraphicsState()
        guard let px = rgba.data?.assumingMemoryBound(to: UInt8.self) else { return nil }

        // Alpha → a gray mask (white = ink), and the ink's bounding box. Row 0 is the top row.
        var gray = [UInt8](repeating: 0, count: w * h)
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w {
                let a = px[(y * w + x) * 4 + 3]
                gray[y * w + x] = a
                if a > 40 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
            }
        }
        guard maxX >= minX,
              let provider = CGDataProvider(data: Data(gray) as CFData),
              let full = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                                 space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                                 provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent),
              let trimmed = full.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
        else { return nil }
        symbolCache[name] = trimmed
        return trimmed
    }

    /// A copy of a template image drawn in `color`, no longer a template. Touch Bar buttons use
    /// this: it draws template images about 24% dimmer than white text (measured on a real bar).
    static func solid(_ image: NSImage, _ color: NSColor = .white) -> NSImage {
        guard image.isTemplate else { return image }
        let out = NSImage(size: image.size, flipped: false) { r in
            image.draw(in: r)
            color.set()
            r.fill(using: .sourceAtop)
            return true
        }
        out.isTemplate = false
        return out
    }

    /// A filled circle, for session status dots.
    static func dot(_ color: NSColor, size: CGFloat = 9) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
            color.setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// Builds the app icon (chef hat on Claude orange) as an .iconset folder for `iconutil`.
/// install.sh runs `SousBar --write-iconset <dir>` so no binary icon file lives in the repo.
enum AppIcon {
    static let orange = NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1) // #D97757

    static func png(pixels: Int) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let gc = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        let size = CGFloat(pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        let ctx = gc.cgContext
        // Flip to y-down so the SVG paths draw the right way up.
        ctx.translateBy(x: 0, y: size)
        ctx.scaleBy(x: 1, y: -1)

        // macOS icon grid: the tile is ~80% of the canvas with ~22% corner radius.
        let tile = CGRect(x: size * 0.1, y: size * 0.1, width: size * 0.8, height: size * 0.8)
        let shape = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
        NSGradient(colors: [orange.blended(withFraction: 0.18, of: .white) ?? orange,
                            orange.blended(withFraction: 0.12, of: .black) ?? orange])?
            .draw(in: shape, angle: 90)
        Icon.app.draw(in: tile.insetBy(dx: tile.width * 0.2, dy: tile.width * 0.2), color: .white)

        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    /// Writes every size `iconutil` expects. Returns false if any file couldn't be written.
    static func writeIconset(to dir: String) -> Bool {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var ok = true
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
                guard let data = png(pixels: base * scale),
                      FileManager.default.createFile(atPath: dir + "/" + name, contents: data) else {
                    ok = false
                    continue
                }
            }
        }
        return ok
    }
}
