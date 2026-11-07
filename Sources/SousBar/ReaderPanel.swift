import AppKit

/// Floating panel for reading a full response. It never activates the app,
/// so whatever you're typing in keeps focus.
final class ReaderPanel {
    private var panel: NSPanel?
    private var textView: NSTextView?

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(title: String, markdown: String) {
        let panel = self.panel ?? makePanel()
        panel.title = title
        textView?.textStorage?.setAttributedString(render(markdown))
        textView?.scrollToBeginningOfDocument(nil)
        panel.orderFrontRegardless()
    }

    func close() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as? NSTextView
        tv?.isEditable = false
        tv?.isSelectable = true
        tv?.textContainerInset = NSSize(width: 14, height: 12)
        tv?.backgroundColor = .textBackgroundColor
        panel.contentView = scroll

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: frame.maxX - 580, y: frame.maxY - 20))
        }
        self.panel = panel
        self.textView = tv
        return panel
    }

    private func render(_ markdown: String) -> NSAttributedString {
        let base = NSFont.systemFont(ofSize: 14)
        let mono = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let parsed = try? NSAttributedString(markdown: markdown, options: options, baseURL: nil) else {
            return NSAttributedString(string: markdown, attributes: [.font: base, .foregroundColor: NSColor.textColor])
        }
        let out = NSMutableAttributedString(attributedString: parsed)
        let full = NSRange(location: 0, length: out.length)
        out.addAttributes([.font: base, .foregroundColor: NSColor.textColor], range: full)
        out.enumerateAttribute(.inlinePresentationIntent, in: full) { value, range, _ in
            guard let raw = (value as? NSNumber)?.uintValue else { return }
            let intent = InlinePresentationIntent(rawValue: raw)
            var font = base
            if intent.contains(.code) { font = mono }
            if intent.contains(.stronglyEmphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
            if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            out.addAttribute(.font, value: font, range: range)
        }
        // Fenced code blocks: everything between ``` lines in monospace.
        let ns = out.string as NSString
        if let re = try? NSRegularExpression(pattern: "```[^\\n]*\\n([\\s\\S]*?)```", options: []) {
            for match in re.matches(in: out.string, range: NSRange(location: 0, length: ns.length)) {
                out.addAttribute(.font, value: mono, range: match.range)
            }
        }
        return out
    }
}
