import AppKit

/// Pull requests and their CI, from your `gh` login. One PR at a time, worst first.
///
///   [⊞] [ctm_fe #470 ] ✗ CI failed · Fix login redirect · by ann · Lint ✓ Types ✓ Unit ✗ …  2/30 · 5m  ‹ › Mine ↗ [hide]
///       [✗ 1 failing ]
final class PRModule: BarModule {
    let id = "prs"
    let icon = Icon.symbol("arrow.triangle.branch")
    weak var host: BarHost?

    let store: PRStore
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    private var index = 0
    /// Showing every PR as buttons (tap the card) instead of one card.
    private(set) var showingList = false
    private var listPage = 0
    private var scroll: (id: String, offset: CGFloat)?
    private(set) var status: String?
    private var statusToken = 0
    static var statusDuration: TimeInterval = 3

    init(store: PRStore) {
        self.store = store
        store.onUpdate = { [weak self] events in
            guard let self else { return }
            let policy = Settings.prPopUp
            if let event = events.first(where: { $0.popsUp(policy) }) {
                // Show the PR it's about.
                if Settings.prOnlyMine, !event.pr.involvesYou { Settings.prOnlyMine = false }
                self.index = self.list.firstIndex { $0.id == event.pr.id } ?? 0
                self.showingList = false
                self.host?.moduleWantsAttention(self)
            }
            self.host?.moduleDidChange(self)
        }
    }

    // MARK: Launcher

    /// PRs that need you: your failing builds, reviews asked of you, changes requested on yours.
    var attention: [PullRequest] {
        store.prs.filter { ($0.isMine && ($0.ci == .failing || $0.reviewDecision == "CHANGES_REQUESTED")) || $0.reviewRequested }
    }

    var title: String {
        let n = attention.count
        return n > 0 ? "PRs · \(n)" : (store.prs.isEmpty ? "PRs" : "PRs (\(store.prs.count))")
    }

    var tint: NSColor? {
        if store.prs.contains(where: { $0.isMine && $0.ci == .failing }) { return .systemRed }
        if store.prs.contains(where: { $0.reviewRequested }) { return .systemOrange }
        if store.prs.contains(where: { $0.isMine && $0.ci == .running }) { return .systemBlue }
        return nil
    }

    // MARK: Bar

    /// What's shown: everything in your scopes, or only yours and your reviews.
    var list: [PullRequest] { Settings.prOnlyMine ? store.prs.filter(\.involvesYou) : store.prs }

    var current: PullRequest? {
        let l = list
        guard !l.isEmpty else { return nil }
        index = min(max(0, index), l.count - 1)
        return l[index]
    }

    func barViews() -> [NSView] {
        let filter = HoldButton(Settings.prOnlyMine ? "Mine" : "All", width: 56)
        filter.onComplete = { [weak self] in
            Settings.prOnlyMine.toggle()
            self?.index = 0
            self?.listPage = 0
            if let self { self.host?.moduleDidChange(self) }
        }
        if showingList, !list.isEmpty { return listViews(filter: filter) }
        showingList = false

        guard let pr = current else {
            return [chip(title: "GitHub", subtitle: status ?? store.error.map { "⚠︎ \($0)" } ?? "hold ↻"),
                    message(emptyText), TouchBarController.spacer(), filter]
        }
        let l = list

        // Number first so it's never cut off; the second line says how CI is doing at a glance.
        let subtitle = status ?? store.error.map { "⚠︎ \($0)" } ?? Self.ciSummary(pr)
        let card = chip(title: "#\(pr.number) \(pr.repoName)", subtitle: subtitle,
                        color: Self.color(pr) ?? NSColor(white: 0.2, alpha: 1))
        card.onTap = { [weak self] in self?.showList() } // tap: every PR; hold: check now

        let text = ScrollingTextView(Self.body(pr, event: store.recentEvents[pr.id]),
                                     offset: scroll?.id == pr.id ? scroll!.offset : 0)
        let prId = pr.id
        text.onScroll = { [weak self] in self?.scroll = (prId, $0) }

        let age = caption("\(index + 1)/\(l.count)" + (pr.updatedAt.map { " · " + FeedDate.ago($0) } ?? ""))

        let prev = button("chevron.left") { [weak self] in self?.step(-1) }
        prev.isEnabled = index > 0
        let next = button("chevron.right") { [weak self] in self?.step(1) }
        next.isEnabled = index < l.count - 1
        let open = button("arrow.up.right.square") { [weak self] in
            if let url = pr.url { self?.openURL(url) }
        }
        open.isEnabled = pr.url != nil
        return [card, text, age, TouchBarController.spacer(), prev, next, filter, open]
    }

    // MARK: All PRs (tap the card)

    static let listButtonWidth: CGFloat = 150

    /// PR buttons that fit next to back, the page counter and buttons, All/Mine, launcher and hide.
    var perPage: Int {
        let counter: CGFloat = 40
        let room = Settings.barWidth - TouchBarController.iconButtonWidth * 5 - 56 - counter - 6 * 8
        return max(1, Int(room / (Self.listButtonWidth + 6)))
    }

    func showList() {
        showingList = true
        listPage = index / perPage // the page with the PR you were on
        host?.moduleDidChange(self)
    }

    private func listViews(filter: HoldButton) -> [NSView] {
        let l = list
        let pages = max(1, (l.count + perPage - 1) / perPage)
        listPage = min(max(0, listPage), pages - 1)

        let back = button("chevron.left") { [weak self] in
            self?.showingList = false
            if let self { self.host?.moduleDidChange(self) }
        }
        var views: [NSView] = [back]
        let start = listPage * perPage
        for (offset, pr) in l[start..<min(l.count, start + perPage)].enumerated() {
            let i = start + offset
            let b = HoldButton("#\(pr.number) \(pr.repoName)", subtitle: Self.listSubtitle(pr), iconSize: 0,
                               color: Self.color(pr) ?? NSColor(white: i == index ? 0.32 : 0.2, alpha: 1),
                               width: Self.listButtonWidth, twoLine: true)
            if i == index { b.layer?.borderWidth = 1.5; b.layer?.borderColor = NSColor(white: 1, alpha: 0.7).cgColor }
            b.onComplete = { [weak self] in
                guard let self else { return }
                self.index = i
                self.showingList = false
                self.host?.moduleDidChange(self)
            }
            views.append(b)
        }
        views.append(caption(pages > 1 ? "\(listPage + 1)/\(pages)" : "\(l.count)"))
        views.append(TouchBarController.spacer())
        let prev = button("chevron.up") { [weak self] in self?.turn(-1) }
        prev.isEnabled = listPage > 0
        let next = button("chevron.down") { [weak self] in self?.turn(1) }
        next.isEnabled = listPage < pages - 1
        return views + [prev, next, filter]
    }

    private func turn(_ delta: Int) {
        listPage += delta
        host?.moduleDidChange(self)
    }

    /// What matters most about a PR, in a few words.
    static func listSubtitle(_ pr: PullRequest) -> String {
        if pr.ci == .failing { return ciSummary(pr) }
        if pr.reviewRequested { return "your review" }
        if pr.reviewDecision == "CHANGES_REQUESTED" { return "changes requested" }
        if pr.ci == .running { return ciSummary(pr) }
        if pr.mergeable == "CONFLICTING" { return "conflicts" }
        if pr.isDraft { return "draft · \(pr.author)" }
        if pr.reviewDecision == "APPROVED" { return "✓ approved" }
        return pr.isMine ? "yours" : pr.author
    }

    private var emptyText: String {
        if let error = store.error { return error }
        if store.lastChecked == nil { return "Checking GitHub…" }
        if Settings.prOnlyMine, !store.prs.isEmpty { return "Nothing of yours open. Tap Mine to see all \(store.prs.count)." }
        return "No open pull requests in your scopes."
    }

    /// "✗ 2 failing", "⋯ 3 running", "✓ checks pass", or the hold hint when there are no checks.
    static func ciSummary(_ pr: PullRequest) -> String {
        let failing = pr.checks.filter { $0.state == .failing }.count
        let running = pr.checks.filter { $0.state == .running }.count
        switch pr.ci {
        case .failing: return "✗ \(max(failing, 1)) failing"
        case .running: return "⋯ \(max(running, 1)) running"
        case .passing: return "✓ checks pass"
        case .none: return "hold ↻"
        }
    }

    /// Red = failing, orange = your review, blue = running.
    static func color(_ pr: PullRequest) -> NSColor? {
        if pr.ci == .failing { return .systemRed.blended(withFraction: 0.35, of: .black) }
        if pr.reviewRequested { return .systemOrange.blended(withFraction: 0.35, of: .black) }
        if pr.ci == .running { return .systemBlue.blended(withFraction: 0.35, of: .black) }
        return nil
    }

    /// "✗ CI failed   Fix login redirect   by ann · Changes requested · Conflicts   Lint ✓  Unit ✗ …"
    static func body(_ pr: PullRequest, event: PREvent?) -> NSAttributedString {
        let s = NSMutableAttributedString()
        func add(_ text: String, _ color: NSColor, bold: Bool = false) {
            s.append(NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: 15, weight: bold ? .semibold : .regular), .foregroundColor: color]))
        }
        if let event { add(event.label + "   ", NSColor.systemYellow, bold: true) }
        add(pr.title, .white, bold: true)

        var facts = ["by \(pr.author)"]
        if pr.isMine { facts[0] = "yours" }
        if pr.reviewRequested { facts.append("your review requested") }
        switch pr.reviewDecision {
        case "APPROVED": facts.append("approved")
        case "CHANGES_REQUESTED": facts.append("changes requested")
        case "REVIEW_REQUIRED": facts.append("needs review")
        default: break
        }
        if pr.mergeable == "CONFLICTING" { facts.append("conflicts") }
        if pr.isDraft { facts.append("draft") }
        add("   " + facts.joined(separator: " · "), NSColor(white: 1, alpha: 0.7))

        // Checks, failing first, then running, then passing.
        let order: [CIState] = [.failing, .running, .passing, .none]
        let checks = pr.checks.sorted { order.firstIndex(of: $0.state)! < order.firstIndex(of: $1.state)! }
        if !checks.isEmpty {
            add("   ", .white)
            for c in checks {
                let color: NSColor = c.state == .failing ? .systemRed : c.state == .running ? .systemBlue
                    : c.state == .passing ? .systemGreen : NSColor(white: 1, alpha: 0.5)
                add(c.name + " ", NSColor(white: 1, alpha: 0.85))
                add(c.state.symbol + "   ", color, bold: true)
            }
        } else if pr.ci == .none {
            add("   no checks", NSColor(white: 1, alpha: 0.5))
        }
        return s
    }

    /// Checks GitHub now (hold the PR's name).
    func refresh() {
        statusToken += 1
        status = "Checking…"
        host?.moduleDidChange(self)
        store.check { [weak self] result in
            guard let self else { return }
            switch result {
            case .changed(let n): self.status = n > 0 ? "\(n) update\(n == 1 ? "" : "s")" : "Updated"
            case .upToDate: self.status = "Up to date"
            case .failed: self.status = "⚠︎ failed"
            }
            self.statusToken += 1
            let token = self.statusToken
            self.host?.moduleDidChange(self)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.statusDuration) { [weak self] in
                guard let self, self.statusToken == token else { return }
                self.status = nil
                self.host?.moduleDidChange(self)
            }
        }
    }

    private func step(_ delta: Int) {
        index += delta
        host?.moduleDidChange(self)
    }

    // MARK: Views

    private func chip(title: String, subtitle: String, color: NSColor = NSColor(white: 0.2, alpha: 1)) -> HoldButton {
        let b = HoldButton(title, subtitle: subtitle, iconSize: 0, color: color, hold: 0.6,
                           width: 120, twoLine: true)
        b.onComplete = { [weak self] in self?.refresh() }
        return b
    }

    private func message(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 15)
        l.textColor = NSColor(white: 1, alpha: 0.8)
        l.lineBreakMode = .byTruncatingTail
        l.setContentHuggingPriority(.init(2), for: .horizontal)
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
