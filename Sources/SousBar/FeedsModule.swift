import AppKit

/// The Feeds app on the launcher: new items from your RSS/Atom feeds (GitHub, Jira, …), one at
/// a time. When something new arrives it shows itself on the Touch Bar for a few seconds.
///
///   [‹back] [Jira] Ann moved SB-12 to Done · 5m   1/3  ‹  ›  ↗  ✓  [hide]
final class FeedsModule: BarModule {
    let id = "feeds"
    let icon = Icon.symbol("dot.radiowaves.up.forward")
    weak var host: BarHost?

    let store: FeedStore
    /// Opens a link. Swappable so tests never launch a browser.
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    private var index = 0

    init(store: FeedStore) {
        self.store = store
        store.onUpdate = { [weak self] new in
            guard let self else { return }
            if !new.isEmpty {
                self.index = 0 // the newest one
                if Settings.feedPeek { self.host?.moduleWantsAttention(self) }
            }
            self.host?.moduleDidChange(self)
        }
    }

    var title: String { store.unread.isEmpty ? "Feeds" : "Feeds · \(store.unread.count)" }
    var tint: NSColor? { store.unread.isEmpty ? nil : .systemGreen }

    /// Unread items if there are any, otherwise the latest ones.
    private var showingUnread: Bool { !store.unread.isEmpty }
    var entries: [FeedEntry] { showingUnread ? store.unread : store.recent }
    var current: FeedEntry? {
        let list = entries
        guard !list.isEmpty else { return nil }
        index = min(max(0, index), list.count - 1)
        return list[index]
    }

    func barViews() -> [NSView] {
        guard let entry = current else { return [message(emptyText), TouchBarController.spacer()] }
        let list = entries

        let failing = store.errors.isEmpty ? nil : "⚠︎ \(store.errors.count) failing"
        let source = HoldButton(entry.sourceName, subtitle: failing, color: NSColor(white: 0.2, alpha: 1),
                                width: TouchBarController.chipWidth, twoLine: true)

        let text = message(entry.item.title, dim: !showingUnread)
        let age = caption([FeedDate.ago(entry.item.date), "\(index + 1)/\(list.count)\(showingUnread ? " new" : "")"]
            .filter { !$0.isEmpty }.joined(separator: " · "))

        let prev = button("chevron.left") { [weak self] in self?.step(-1) }
        prev.isEnabled = index > 0
        let next = button("chevron.right") { [weak self] in self?.step(1) }
        next.isEnabled = index < list.count - 1
        let open = button("arrow.up.right.square") { [weak self] in self?.open(entry) }
        open.isEnabled = entry.item.link != nil

        // The spacer keeps the caption's label inset off the edge; the text gives way first.
        var views: [NSView] = [source, text, age, TouchBarController.spacer(), prev, next, open]
        if showingUnread {
            views.append(button("checkmark") { [weak self] in
                self?.index = 0
                self?.store.markAllRead()
            })
        }
        return views
    }

    private var emptyText: String {
        if store.sources.isEmpty { return "No feeds yet. Add one from the menu bar chef hat › Feeds › Add Feed…" }
        if let (id, error) = store.errors.first, let name = store.sources.first(where: { $0.id == id })?.name {
            return "\(name): \(error)"
        }
        return "Nothing yet. Checking your feeds…"
    }

    private func step(_ delta: Int) {
        index += delta
        host?.moduleDidChange(self)
    }

    private func open(_ entry: FeedEntry) {
        if let link = entry.item.link { openURL(link) }
        if showingUnread { store.markRead(entry) } // redraws via onUpdate
    }

    // MARK: - Views

    private func message(_ s: String, dim: Bool = false) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 15)
        l.textColor = NSColor(white: 1, alpha: dim ? 0.6 : 1)
        l.lineBreakMode = .byTruncatingTail
        l.maximumNumberOfLines = 1
        l.cell?.truncatesLastVisibleLine = true
        l.setContentHuggingPriority(.init(2), for: .horizontal) // the spacer after it takes slack first
        l.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        return l
    }

    private func caption(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        l.textColor = NSColor(white: 1, alpha: 0.5)
        l.setContentHuggingPriority(.required, for: .horizontal)
        l.setContentCompressionResistancePriority(.required, for: .horizontal)
        return l
    }

    private func button(_ symbol: String, _ action: @escaping () -> Void) -> HoldButton {
        let b = HoldButton("", icon: Icon.symbol(symbol).image(), width: TouchBarController.iconButtonWidth)
        b.onComplete = action
        return b
    }
}
