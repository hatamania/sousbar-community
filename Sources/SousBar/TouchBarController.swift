import AppKit

/// Owns the Control Strip pill and the full-width bar.
///
/// Rules:
///  • Nothing here activates an app or takes keyboard focus, except "Jump ↗" (long-press).
///  • When Claude needs an answer the full bar opens by itself (option A), and goes
///    back to your app's own Touch Bar once you've answered.
final class TouchBarController: NSObject, NSTouchBarDelegate, BarHost {
    static let pillId = NSTouchBarItem.Identifier(rawValue: "local.sousbar.pill")
    static let mainId = NSTouchBarItem.Identifier(rawValue: "local.sousbar.main")
    static let rightId = NSTouchBarItem.Identifier(rawValue: "local.sousbar.right")

    private let store: Store
    private let voice = VoiceInput()
    private let panel = ReaderPanel()

    private let bar = NSTouchBar()
    private let pillItem: NSCustomTouchBarItem
    private let pillButton: NSButton
    /// Left item: chip and text. Right item: the buttons. A flexible space between them keeps
    /// the buttons on the right edge however wide the Touch Bar is.
    let container: BarContainer
    let rightContainer: BarContainer
    private var leftStack = NSStackView()
    private var rightStack = NSStackView()

    /// What the bar shows when no approval or dictation is in front.
    /// active = running sessions (the chip); sessions = this folder's history (the list button).
    /// reading = the current reply word by word.
    /// launcher = the layer in front: one button per app (Claude, then `modules`).
    /// module = one of `modules` has the bar.
    enum Mode: Equatable { case normal, active, sessions, model, effort, reading, launcher, module(String) }
    var mode: Mode = .normal // internal so tests can render each screen
    private var sessionsPage = 0
    /// The folder whose history the session picker shows, and that history (loaded off the main thread).
    private var historyFolder: String?
    private var history: [PastSession] = []
    private var historyToken = 0
    /// After tapping New: the folder we're waiting on, so the bar can switch to that session when it starts.
    private var expectingNewSession: (folder: String, since: Date)?
    /// Opens a terminal running `claude` in a folder. Swappable so tests never open real tabs.
    var openNewSession: (String, TerminalInfo?) -> String? = TerminalBridge.newSession(in:like:)
    /// Show / hide the full-width bar. Swappable so tests never take over the real Touch Bar.
    var systemPresent: (NSTouchBar, NSTouchBarItem.Identifier) -> Void = PrivateTouchBar.present(_:trayId:)
    var systemMinimize: (NSTouchBar) -> Void = PrivateTouchBar.minimize(_:)

    /// Apps on the launcher after Claude (RSS and so on). See `BarModule`.
    var modules: [BarModule] = [] {
        didSet { for m in modules { m.host = self } }
    }
    /// A module showed itself for something new and you haven't touched it yet: it closes by itself.
    private(set) var isPeeking = false
    private var peekToken = 0
    static let peekDuration: TimeInterval = 8

    private(set) var isPresented = false
    private var autoOpened = false
    private var lastSignature = ""

    /// Session shown in the bar; tap the session chip to cycle.
    private(set) var currentSessionId: String?

    // Voice state
    private var recordingTarget: VoiceTarget?
    private var transcript: String?
    private var transcriptTarget: VoiceTarget?

    private static let voiceColor = NSColor(red: 0.55, green: 0.2, blue: 0.75, alpha: 1)

    // A short message shown in place of the text for a few seconds.
    private var flashMessage: String?
    private var flashToken = 0

    // Views we update in place.
    private weak var pager: PagedTextView?
    private weak var reader: SpeedReaderView?
    private weak var chip: HoldButton?

    init(store: Store) {
        self.store = store
        pillButton = NSButton(title: "", image: Icon.app.image(), target: nil, action: nil)
        pillItem = NSCustomTouchBarItem(identifier: Self.pillId)
        container = BarContainer(size: NSSize(width: Settings.barWidth, height: 30))
        rightContainer = BarContainer(size: NSSize(width: 44, height: 30))
        super.init()

        pillButton.target = self
        pillButton.action = #selector(pillTapped)
        pillButton.font = .systemFont(ofSize: 13, weight: .semibold)
        pillButton.imagePosition = .imageOnly
        pillItem.view = pillButton

        bar.delegate = self
        store.onSessionStarted = { [weak self] session in self?.sessionStarted(session) }
        bar.defaultItemIdentifiers = [Self.mainId, .flexibleSpace, Self.rightId]
    }

    func install() {
        PrivateTouchBar.setCloseBoxShown(false)
        PrivateTouchBar.addSystemTrayItem(pillItem)
        reassertPill()

        // macOS drops Control Strip items from background apps when the front app
        // changes or the modal bar closes. Put the pill back every time.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(reassertPill),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(reassertPill),
            name: NSWorkspace.didWakeNotification, object: nil)
        let keepAlive = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.reassertPill() }
        RunLoop.main.add(keepAlive, forMode: .common)

        refresh()
    }

    @objc func reassertPill() {
        PrivateTouchBar.setControlStripPresence(Self.pillId, true)
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        let view: NSView
        switch identifier {
        case Self.mainId: view = container
        case Self.rightId: view = rightContainer
        default: return nil
        }
        let item = NSCustomTouchBarItem(identifier: identifier)
        item.view = view
        return item
    }

    // MARK: - Showing / hiding

    @objc private func pillTapped() {
        // Claude is waiting on you: skip the launcher.
        if !store.pending.isEmpty { openClaude() } else { present(auto: false) }
    }

    /// Opens the bar. `auto` = opened for an approval (goes straight to Claude, and closes again
    /// once answered). Otherwise it opens on the launcher.
    func present(auto: Bool) {
        if !isPresented {
            autoOpened = auto
            isPresented = true
            mode = auto ? .normal : .launcher
            if !auto { currentSessionId = store.sessionsByRecency.first?.id }
            rebuild()
            systemPresent(bar, Self.pillId)
        } else {
            rebuild()
        }
    }

    /// Claude's bar (the session home), opening the bar first if needed.
    func openClaude() {
        isPeeking = false
        if !isPresented { present(auto: false) }
        mode = .normal
        rebuild()
        if Settings.autoRead, store.pending.isEmpty, let s = currentSession, s.unread, canRead(s) { startReading() }
    }

    /// Opens a module by id ("claude" is Claude). Returns false if there's no such module.
    @discardableResult
    func open(moduleId id: String) -> Bool {
        if id == "claude" { openClaude(); return true }
        guard modules.contains(where: { $0.id == id }) else { return false }
        if !isPresented { present(auto: false) }
        mode = .module(id)
        rebuild()
        return true
    }

    func showLauncher() {
        isPeeking = false
        if !isPresented { present(auto: false); return }
        autoOpened = false // you're browsing now; don't close when the approval is answered
        mode = .launcher
        rebuild()
    }

    func minimize() {
        guard isPresented else { return }
        if voice.isRecording { voice.cancel() }
        isPresented = false
        autoOpened = false
        isPeeking = false
        mode = .normal
        systemMinimize(bar)
        updatePill()
        reassertPill()
        // Some macOS versions only re-show the item after the close animation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.reassertPill() }
    }

    func handleNewPending(_ item: PendingItem) {
        mode = .normal // an approval always takes over from the pickers
        if isPeeking {
            // The bar was only up to show a feed item: close it again once this is answered.
            isPeeking = false
            autoOpened = true
        }
        // A leftover message ("Sent to …") must never cover what the approval is asking.
        flashMessage = nil
        flashToken += 1
        if voice.isRecording {
            updatePill()
            return
        }
        if Settings.autoExpand && !isPresented {
            present(auto: true)
        } else {
            refresh()
        }
    }

    // MARK: - Refresh

    func refresh() {
        updatePill()
        guard isPresented else {
            currentSessionId = nil
            return
        }
        if voice.isRecording {
            updateChip()
            return
        }
        if autoOpened, store.pending.isEmpty, transcript == nil, flashMessage == nil {
            minimize()
            return
        }
        if signature() != lastSignature {
            rebuild()
        } else {
            updateChip()
            if store.pending.isEmpty, transcript == nil, flashMessage == nil, mode == .normal { updateHomeText() }
        }
    }

    private var currentSession: AgentSession? {
        if let id = currentSessionId, let s = store.session(id) { return s }
        let s = store.sessionsByRecency.first
        currentSessionId = s?.id
        return s
    }

    private func signature() -> String {
        var parts: [String] = []
        if let item = store.pending.first {
            parts.append("pending:\(item.id):\(item.questionIndex):\(item.multiSelection.joined(separator: ","))")
            parts.append("count:\(store.pending.count)")
            if transcript != nil, transcriptTarget?.itemId == item.id { parts.append("reply") }
        } else if transcript != nil {
            parts.append("transcript")
        } else {
            parts.append("home")
        }
        parts.append(currentSession?.id ?? "-")
        parts.append("\(mode):\(sessionsPage)")
        if mode == .active || mode == .sessions {
            // Redraw the picker when a session appears, ends, or changes status (not on every event).
            parts.append(store.sessionsByRecency.map { "\($0.id)=\(status(of: $0))" }.joined(separator: ","))
        }
        parts.append(Settings.voiceLocale)
        parts.append(flashMessage == nil ? "" : "flash")
        return parts.joined(separator: "|")
    }

    /// Orange = needs you, blue = working, green = new reply; nil = nothing going on.
    private var claudeTint: NSColor? {
        if !store.pending.isEmpty { return .systemOrange }
        if store.sessions.values.contains(where: { $0.state.isWorking }) { return .systemBlue }
        if store.sessions.values.contains(where: { $0.unread }) { return .systemGreen }
        return nil
    }

    private func updatePill() {
        let color = claudeTint ?? NSColor(white: store.sessions.isEmpty ? 0.25 : 0.3, alpha: 1)
        // Just the chef hat; a number only when more than one request is waiting.
        pillButton.title = store.pending.count > 1 ? "\(store.pending.count)" : ""
        pillButton.imagePosition = pillButton.title.isEmpty ? .imageOnly : .imageLeading
        pillButton.bezelColor = color
    }

    private func status(of session: AgentSession) -> SessionStatus {
        session.status(hasPending: store.pending.contains { $0.sessionId == session.id })
    }

    /// Dot colors used everywhere a session is listed.
    static func color(for status: SessionStatus) -> NSColor {
        switch status {
        case .needsYou: return .systemOrange
        case .inTerminal: return .systemRed
        case .working: return .systemBlue
        case .newReply: return .systemGreen
        case .idle: return .systemGray
        }
    }

    private func chipTitle() -> String {
        currentSession?.project ?? "No sessions"
    }

    private func chipDot() -> NSImage? {
        currentSession.map { Icon.dot(Self.color(for: status(of: $0))) }
    }

    private func updateChip() {
        guard let chip, chip.onComplete != nil else { return } // pending/voice chips keep their own title
        chip.title = chipTitle()
        chip.icon = chipDot()
    }

    // MARK: - Building the bar

    func rebuild() {
        // A dictated reply whose request was answered elsewhere, timed out, or was cancelled.
        if let id = transcriptTarget?.itemId, !store.pending.contains(where: { $0.id == id }) {
            transcript = nil
            transcriptTarget = nil
            DispatchQueue.main.async { [weak self] in
                self?.flash("That request was already answered or went to the terminal")
            }
        }
        if let item = store.pending.first { currentSessionId = item.sessionId }
        lastSignature = signature()

        var views: [NSView]
        if mode != .normal, store.pending.isEmpty, transcript == nil {
            views = modeViews()
        } else if let item = store.pending.first {
            if let text = transcript, let target = transcriptTarget, target.itemId == item.id {
                views = replyViews(text, target: target, item: item)
            } else {
                views = pendingViews(item)
            }
        } else if let text = transcript, case let .prompt(sessionId)? = transcriptTarget {
            views = transcriptViews(text, sessionId: sessionId)
        } else {
            views = homeViews()
        }
        views.append(hideButton())

        let split = Self.splitIndex(views)
        rightStack = Self.fill(rightContainer, with: Array(views[split...]))
        // The buttons' natural width decides the right item; the left item gets the rest of the budget.
        let rightWidth = ceil(rightStack.fittingSize.width)
        rightContainer.size = NSSize(width: rightWidth, height: 30)
        container.size = NSSize(width: max(200, Settings.barWidth - rightWidth - Self.itemGap), height: 30)
        leftStack = Self.fill(container, with: Array(views[..<split]))
        updatePill()
    }

    /// Space macOS leaves between Touch Bar items.
    static let itemGap: CGFloat = 8

    /// Where the right-hand group starts: after the last stretchy view (the text, the reader,
    /// a spacer or a caption). With none, only the hide button goes right.
    static func splitIndex(_ views: [NSView]) -> Int {
        let stretchy = views.lastIndex { v in
            v is PagedTextView || v is SpeedReaderView || v is NSTextField || type(of: v) == NSView.self
        }
        return stretchy.map { $0 + 1 } ?? max(0, views.count - 1)
    }

    private static func fill(_ container: BarContainer, with views: [NSView]) -> NSStackView {
        container.subviews.forEach { $0.removeFromSuperview() }
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return stack
    }

    /// Everything on the bar, left to right (for tests and previews).
    var itemViews: [NSView] { leftStack.arrangedSubviews + rightStack.arrangedSubviews }

    /// Every icon-only button is this wide, so the icons line up.
    static let iconButtonWidth: CGFloat = 44
    /// The session chip never grows; long names wrap onto a second line.
    static let chipWidth: CGFloat = 84

    private func iconButton(_ icon: Icon, color: NSColor = NSColor(white: 0.28, alpha: 1),
                            hold: TimeInterval = 0) -> HoldButton {
        HoldButton("", icon: icon.image(), color: color, hold: hold, width: Self.iconButtonWidth)
    }

    /// Hides the bar (your app's own Touch Bar comes back). Always the last button.
    private func hideButton() -> HoldButton {
        let b = iconButton(.hide)
        b.onComplete = { [weak self] in self?.minimize() }
        return b
    }

    /// Session name chip. Tap it to pick a session; pass `title` for a fixed, non-tappable label.
    private func makeChip(title: String? = nil, icon: NSImage? = nil,
                          color: NSColor = NSColor(white: 0.2, alpha: 1)) -> HoldButton {
        let tappable = title == nil
        let image = icon ?? (tappable ? chipDot() : nil)
        let b = HoldButton(title ?? chipTitle(), icon: image, iconSize: image?.size.width ?? Icon.barSize,
                           color: color, width: Self.chipWidth, twoLine: true)
        if tappable { b.onComplete = { [weak self] in self?.openActive() } }
        chip = b
        return b
    }

    private func micButton(_ target: @escaping () -> VoiceTarget?, title: String = "",
                           color: NSColor = TouchBarController.voiceColor, width: CGFloat? = nil) -> HoldButton {
        let b = HoldButton(title, icon: Icon.mic.image(), color: color, width: width ?? Self.iconButtonWidth)
        b.onPress = { [weak self] in
            guard let t = target() else { return }
            self?.startRecording(t)
        }
        b.onRelease = { [weak self] in self?.stopRecording() }
        return b
    }

    private func makePager(_ text: String, longPress: (() -> Void)? = nil) -> PagedTextView {
        let p = PagedTextView()
        p.setText(text)
        p.onLongPress = longPress
        pager = p
        return p
    }

    private func openActive() {
        guard !store.sessions.isEmpty else { return }
        sessionsPage = 0
        mode = .active
        rebuild()
    }

    /// The list button: this folder's history. Internal so tests can open it.
    func openSessions() {
        guard let session = currentSession else { return }
        sessionsPage = 0
        mode = .sessions
        if historyFolder != session.cwd { history = [] }
        historyFolder = session.cwd
        loadHistory(for: session)
        rebuild()
    }

    /// Reads the folder's saved conversations in the background, then redraws the picker.
    private func loadHistory(for session: AgentSession) {
        let dir = SessionHistory.directory(cwd: session.cwd, transcriptPath: session.transcriptPath)
        historyToken += 1
        let token = historyToken
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let list = SessionHistory.list(in: dir)
            DispatchQueue.main.async {
                guard let self, token == self.historyToken, list != self.history else { return }
                self.history = list
                if self.mode == .sessions, self.isPresented { self.rebuild() }
            }
        }
    }

    /// Opens a new terminal tab in this folder running `claude` (nothing comes to the front).
    func newSession() {
        guard let folder = historyFolder ?? currentSession?.cwd, !folder.isEmpty else { return }
        // Open it next to a session in this folder if there is one, so it lands in the same window.
        let nearby = store.sessionsByRecency.first { $0.cwd == folder } ?? currentSession
        mode = .normal
        if let error = openNewSession(folder, nearby?.terminal) { return flash(error) }
        expectingNewSession = (folder, Date())
        flash("Starting a new session in \((folder as NSString).lastPathComponent)…")
    }

    /// When the session started by New reports in, show it.
    private func sessionStarted(_ session: AgentSession) {
        guard let expected = expectingNewSession else { return }
        if Date().timeIntervalSince(expected.since) > 60 { expectingNewSession = nil; return }
        guard session.cwd == expected.folder else { return }
        expectingNewSession = nil
        currentSessionId = session.id
        if isPresented { rebuild() }
    }

    /// Types `/resume <id>` into a Claude Code session running in that folder.
    private func resume(_ entry: PickerEntry) {
        let folder = historyFolder ?? currentSession?.cwd
        let here = ([currentSession].compactMap { $0 } + store.sessionsByRecency).filter { $0.cwd == folder }
        guard let target = here.first(where: { $0.terminal.canReceiveText }) else {
            mode = .normal
            return flash("To resume, run this folder's Claude Code in tmux or iTerm2")
        }
        guard !target.state.isWorking else {
            mode = .normal
            return flash("Claude is busy in that terminal. Resume when it's done.")
        }
        mode = .normal
        if let error = TerminalBridge.send("/resume \(entry.id)", to: target.terminal) { return flash(error) }
        currentSessionId = target.id
        flash("Resuming “\(TextTools.truncate(entry.title, 40))”")
    }

    private func openModelPicker() {
        guard let s = currentSession else { return }
        guard s.terminal.canReceiveText else {
            flash("Switching model needs tmux or iTerm2 for this session (\(s.project))")
            return
        }
        guard !s.state.isWorking else {
            flash("Claude is busy. Switch the model when it's done.")
            return
        }
        mode = .model
        rebuild()
    }

    private func backToHome() {
        mode = .normal
        rebuild()
    }

    // MARK: - Pickers (sessions, model, effort)

    private func modeViews() -> [NSView] {
        let back = iconButton(.symbol("chevron.left"))
        back.onComplete = { [weak self] in self?.backToHome() }
        switch mode {
        case .active:
            let entries = SessionPicker.active(live: store.sessionsByRecency,
                                               status: { [unowned self] in self.status(of: $0) },
                                               title: { [unowned self] in self.store.title(for: $0) },
                                               subtitleWidth: Self.sessionTextWidth)
            return [back] + pickerViews(entries)
        case .sessions:
            let folder = historyFolder ?? currentSession?.cwd ?? ""
            let entries = SessionPicker.entries(folder: folder, live: store.sessionsByRecency,
                                                status: { [unowned self] in self.status(of: $0) },
                                                title: { [unowned self] in self.store.title(for: $0) },
                                                history: history)
            // Which folder this is, then its sessions.
            let name = caption((folder as NSString).lastPathComponent)
            name.lineBreakMode = .byTruncatingTail
            name.widthAnchor.constraint(lessThanOrEqualToConstant: 110).isActive = true
            let new = HoldButton("New", icon: Icon.symbol("plus").image(), color: Self.selectedColor, width: 76)
            new.onComplete = { [weak self] in self?.newSession() }
            return [back, name] + pickerViews(entries) + [new]
        case .model: return [back, caption("Model"), Self.spacer()] + modelViews()
        case .effort: return [back, caption("Effort"), Self.spacer()] + effortViews()
        case .reading: return readingViews()
        case .normal: return homeViews()
        case .launcher: return launcherViews()
        case .module(let id):
            guard let module = modules.first(where: { $0.id == id }) else { return launcherViews() }
            let views = module.barViews()
            // Touching anything in a module that popped up by itself keeps it open.
            for case let b as HoldButton in views {
                let action = b.onComplete
                b.onComplete = { [weak self] in
                    self?.isPeeking = false
                    action?()
                }
            }
            return [launcherButton()] + views
        }
    }

    // MARK: - BarHost

    func moduleDidChange(_ module: BarModule) {
        guard isPresented else { return }
        if mode == .launcher || mode == .module(module.id) { rebuild() }
    }

    func moduleWantsAttention(_ module: BarModule) {
        // Never interrupt an approval, dictation, or whatever you're doing on the bar.
        guard !isPresented, store.pending.isEmpty, !voice.isRecording else { return }
        present(auto: false)
        mode = .module(module.id)
        rebuild()
        isPeeking = true
        peekToken += 1
        let token = peekToken
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.peekDuration) { [weak self] in
            guard let self, self.isPeeking, self.peekToken == token, self.mode == .module(module.id) else { return }
            self.minimize()
        }
    }

    // MARK: - Launcher

    static let launcherButtonWidth: CGFloat = 120

    /// One button per app, Claude first.
    private func launcherViews() -> [NSView] {
        let claude = HoldButton("Claude", icon: Icon.app.image(), color: claudeTint ?? Self.neutralColor,
                                width: Self.launcherButtonWidth)
        claude.onComplete = { [weak self] in self?.openClaude() }
        var views: [NSView] = [claude]
        for module in modules {
            let b = HoldButton(module.title, icon: module.icon.image(), color: module.tint ?? Self.neutralColor,
                               width: Self.launcherButtonWidth)
            let id = module.id
            b.onComplete = { [weak self] in self?.open(moduleId: id) }
            views.append(b)
        }
        return views + [Self.spacer()]
    }

    private static let neutralColor = NSColor(white: 0.28, alpha: 1)

    /// Back to the launcher. First button on Claude's home and on every module.
    private func launcherButton() -> HoldButton {
        let b = iconButton(.symbol("square.grid.2x2"))
        b.onComplete = { [weak self] in self?.showLauncher() }
        return b
    }

    private func caption(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 12, weight: .semibold)
        l.textColor = NSColor(white: 1, alpha: 0.55)
        l.setContentHuggingPriority(.required, for: .horizontal) // natural size; the spacer stretches
        return l
    }

    /// Empty view that takes up leftover width (and marks where the right-hand buttons start).
    static func spacer() -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.setContentHuggingPriority(.init(1), for: .horizontal)
        v.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        return v
    }

    /// Room for session buttons: everything but back, hide, a page button and spacing.
    /// Wide enough for a conversation name over "folder · Status".
    private static let sessionButtonWidth: CGFloat = 168
    /// Text room inside a session button (matches HoldButton's two-line layout with a 9 pt dot).
    static let sessionTextWidth: CGFloat = sessionButtonWidth - 6 - 9 - 5 - 4 - 6
    private var sessionsPerPage: Int {
        // Back, hide, a page button, and (history only) the folder caption and New.
        let room = Settings.barWidth - Self.iconButtonWidth * 3 - 6 * 4 - (mode == .sessions ? 116 + 82 : 0)
        return max(1, Int(room / (Self.sessionButtonWidth + 6)))
    }

    private func pickerViews(_ entries: [PickerEntry]) -> [NSView] {
        let perPage = sessionsPerPage
        let pages = max(1, (entries.count + perPage - 1) / perPage)
        sessionsPage = min(sessionsPage, pages - 1)
        var views: [NSView] = entries.dropFirst(sessionsPage * perPage).prefix(perPage).map { entry in
            switch entry.kind {
            case let .live(st):
                let current = entry.id == currentSessionId
                let b = HoldButton(entry.title, subtitle: entry.subtitle, icon: Icon.dot(Self.color(for: st)), iconSize: 9,
                                   color: current ? NSColor(white: 0.42, alpha: 1) : NSColor(white: 0.25, alpha: 1),
                                   width: Self.sessionButtonWidth, twoLine: true)
                b.onComplete = { [weak self] in
                    self?.currentSessionId = entry.id
                    self?.backToHome()
                }
                return b
            case .past:
                // Resuming replaces the conversation in that terminal, so it's a hold, not a tap.
                let b = HoldButton(entry.title, subtitle: entry.subtitle, icon: Icon.dot(NSColor(white: 0.5, alpha: 1)), iconSize: 9,
                                   color: NSColor(white: 0.17, alpha: 1), hold: 0.6,
                                   width: Self.sessionButtonWidth, twoLine: true)
                b.onComplete = { [weak self] in self?.resume(entry) }
                return b
            }
        }
        views.append(Self.spacer())
        if pages > 1 {
            let more = HoldButton("\(sessionsPage + 1)/\(pages)", icon: Icon.symbol("chevron.right").image(), width: 72)
            more.onComplete = { [weak self] in
                guard let self else { return }
                self.sessionsPage = (self.sessionsPage + 1) % pages
                self.rebuild()
            }
            views.append(more)
        }
        return views
    }

    private static let selectedColor = NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1)
    private static let choiceColor = NSColor(white: 0.3, alpha: 1)

    private func modelViews() -> [NSView] {
        let session = currentSession
        var views: [NSView] = ModelChoice.models.map { m in
            let selected = ModelChoice.matches(session?.model, m.alias)
            let b = HoldButton(m.title, color: selected ? Self.selectedColor : Self.choiceColor, width: 96)
            b.onComplete = { [weak self] in self?.pickModel(m.alias) }
            return b
        }
        let skip = HoldButton("Effort", icon: Icon.symbol("chevron.right").image(), width: 96)
        skip.onComplete = { [weak self] in
            self?.mode = .effort
            self?.rebuild()
        }
        views.append(skip)
        return views
    }

    private func effortViews() -> [NSView] {
        let session = currentSession
        return ModelChoice.efforts.map { e in
            let b = HoldButton(e, color: session?.effort == e ? Self.selectedColor : Self.choiceColor, width: 84)
            b.onComplete = { [weak self] in self?.pickEffort(e) }
            return b
        }
    }

    /// Types `/model <alias>` into the session, then moves on to effort.
    private func pickModel(_ alias: String) {
        guard let s = currentSession else { return backToHome() }
        if let error = TerminalBridge.send("/model \(alias)", to: s.terminal) {
            mode = .normal
            return flash(error)
        }
        s.model = alias
        mode = .effort
        rebuild()
    }

    /// Types `/effort <level>` into the session, then goes back to the normal bar.
    private func pickEffort(_ level: String) {
        guard let s = currentSession else { return backToHome() }
        mode = .normal
        if let error = TerminalBridge.send("/effort \(level)", to: s.terminal) { return flash(error) }
        s.effort = level
        let model = ModelChoice.models.first { ModelChoice.matches(s.model, $0.alias) }?.title
        flash([model, "effort \(level)"].compactMap { $0 }.joined(separator: " · "))
    }

    // Home: status / last response, voice, jump.
    private func homeViews() -> [NSView] {
        let session = currentSession
        // Mark as read without triggering another refresh mid-build.
        if let session, session.state == .done || session.state == .idle { session.unread = false }

        let pager = makePager(flashMessage ?? homeText()) { [weak self] in self?.openReader() }
        if flashMessage == nil, let session, session.state.isWorking { pager.setActivity(activityDetail(session)) }

        let lang = HoldButton(Settings.voiceLocale.hasPrefix("vi") ? "VI" : "EN", width: 40)
        lang.onComplete = { [weak self] in
            Settings.voiceLocale = Settings.voiceLocale.hasPrefix("vi") ? "en-US" : "vi-VN"
            self?.rebuild()
        }

        let model = iconButton(.symbol("cpu"))
        model.isEnabled = session != nil
        model.onComplete = { [weak self] in self?.openModelPicker() }

        let sessions = iconButton(.symbol("list.bullet"))
        sessions.isEnabled = !store.sessions.isEmpty
        sessions.onComplete = { [weak self] in self?.openSessions() }

        // Always tappable: if there's nothing to play yet it says why instead of silently ignoring you.
        let read = iconButton(.play)
        read.isEnabled = session != nil
        read.onComplete = { [weak self] in self?.startReading() }

        let mic = micButton { [weak self] in self?.currentSession.map { .prompt(sessionId: $0.id) } }
        mic.isEnabled = session != nil

        let jump = iconButton(.symbol("arrow.up.right.square"), hold: 0.6)
        jump.isEnabled = session != nil
        jump.onComplete = { [weak self] in
            guard let s = self?.currentSession else { return }
            self?.minimize()
            TerminalBridge.jump(to: s.terminal)
        }

        return [launcherButton(), makeChip(), pager, read, lang, model, sessions, mic, jump]
    }

    // MARK: - Word-by-word reading

    private func canRead(_ s: AgentSession) -> Bool {
        !s.state.isWorking && store.replyText(for: s) != nil
    }

    /// Opens the reader on the current reply and starts it, or says why it can't.
    func startReading() {
        guard let s = currentSession else { return }
        if s.state.isWorking { return flash("Claude is still working. Play the reply when it's done.") }
        guard store.replyText(for: s) != nil else { return flash("No reply to read yet in \(s.project)") }
        mode = .reading
        s.unread = false
        rebuild()
        reader?.play()
    }

    private func readingViews() -> [NSView] {
        guard let s = currentSession, canRead(s) else {
            mode = .normal
            return homeViews()
        }
        let view = SpeedReaderView(text: TextTools.stripMarkdown(store.replyText(for: s) ?? ""), wpm: Settings.readingWPM)
        view.onLongPress = { [weak self] in self?.openReader() }
        reader = view

        let slower = iconButton(.symbol("minus"))
        slower.onComplete = { [weak view] in view?.slower() }
        let faster = iconButton(.symbol("plus"))
        faster.onComplete = { [weak view] in view?.faster() }
        let playPause = iconButton(.pause, color: Self.selectedColor)
        playPause.onComplete = { [weak view] in view?.toggle() }
        view.onStateChange = { [weak playPause] playing in
            playPause?.icon = (playing ? Icon.pause : Icon.play).image()
        }
        // Back to the swipeable pages.
        let pages = iconButton(.symbol("text.alignleft"))
        pages.onComplete = { [weak self] in self?.backToHome() }

        return [makeChip(), view, slower, faster, playPause, pages]
    }

    private func activityDetail(_ s: AgentSession) -> String? {
        if case let .tool(label) = s.state { return label }
        return nil
    }

    /// Updates the text in place (no rebuild), animating while Claude works.
    private func updateHomeText() {
        if let s = currentSession, s.state.isWorking {
            pager?.setActivity(activityDetail(s))
        } else {
            pager?.setText(homeText())
        }
    }

    private func homeText() -> String {
        guard let s = currentSession else {
            return "No Claude Code sessions yet. Start `claude` in a terminal and it shows up here."
        }
        switch s.state {
        case .thinking:
            return "Thinking…"
        case .tool(let label):
            return "Running \(label)"
        case .waiting(let message):
            return message
        case .done, .idle:
            // Never read files during a redraw; a missing reply loads in the background.
            guard let reply = store.replyTextWithoutWaiting(for: s) else { return s.state == .idle ? "Ready" : "Done" }
            return TextTools.stripMarkdown(reply)
        }
    }

    private func openReader() {
        guard let s = currentSession, let text = store.replyText(for: s) else { return }
        panel.show(title: "Claude · \(s.project)", markdown: text)
    }

    // Approval or question.
    private func pendingViews(_ item: PendingItem) -> [NSView] {
        let session = store.session(item.sessionId)
        let project = session?.project ?? "Claude"
        let count = store.pending.count > 1 ? " · 1/\(store.pending.count)" : ""
        let chip = makeChip(title: project + count, icon: Icon.dot(Self.color(for: .needsYou)),
                            color: NSColor(red: 0.45, green: 0.27, blue: 0, alpha: 1))

        let toTerminal = HoldButton("→ Term", width: 72)
        toTerminal.onComplete = { [weak self] in self?.store.resolve(item, output: nil) }

        switch item.kind {
        case let .permission(tool, summary, detail, risky, suggestions):
            let text = "\(ToolText.displayName(tool)) · \(summary.isEmpty ? "(no details)" : summary)"
            let pager = makePager(flashMessage ?? text) { [weak self] in
                self?.panel.show(title: "\(ToolText.displayName(tool)) · \(project)", markdown: detail)
            }
            let deny = HoldButton("Deny", color: .systemRed, width: 70)
            deny.onComplete = { [weak self] in
                self?.store.resolve(item, output: Decision.deny(Decision.denyMessage()))
            }
            // Hold, say why, release: Claude gets the reason with the denial.
            let denyWhy = micButton({ .denyReason(itemId: item.id) }, title: "Deny",
                                    color: NSColor(red: 0.5, green: 0.12, blue: 0.12, alpha: 1), width: 84)
            let allow = HoldButton(risky ? "Hold · Allow" : "Allow", color: .systemGreen,
                                   hold: risky ? Settings.holdToAllow : 0, width: risky ? 128 : 80)
            allow.onComplete = { [weak self] in self?.store.resolve(item, output: Decision.allow()) }

            var views: [NSView] = [chip, pager, deny, denyWhy, allow]
            // Always writes a lasting rule, so it's a hold even for read-only tools.
            if let rules = AlwaysRules.describe(suggestions) {
                let always = HoldButton("Hold · Always", color: NSColor(red: 0.1, green: 0.45, blue: 0.3, alpha: 1),
                                        hold: Settings.holdToAllow, width: 136)
                always.onComplete = { [weak self] in
                    self?.store.resolve(item, output: Decision.allow(updatedPermissions: suggestions))
                    self?.flash("Always allowing \(rules)")
                }
                views.append(always)
            }
            views.append(toTerminal)
            return views

        case let .question(questions, toolInput):
            let index = min(item.questionIndex, questions.count - 1)
            let q = questions[index]
            let questionText = q["question"] as? String ?? ""
            let header = (q["header"] as? String).map { "\($0): " } ?? ""
            let progress = questions.count > 1 ? " (\(index + 1)/\(questions.count))" : ""
            let options = (q["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
            let multi = q["multiSelect"] as? Bool ?? false

            let pager = makePager(flashMessage ?? (header + questionText + progress)) { [weak self] in
                let lines = (q["options"] as? [[String: Any]] ?? []).map { opt -> String in
                    let label = opt["label"] as? String ?? ""
                    let desc = opt["description"] as? String ?? ""
                    return desc.isEmpty ? "- **\(label)**" : "- **\(label)**: \(desc)"
                }
                self?.panel.show(title: "Question · \(project)", markdown: "\(questionText)\n\n" + lines.joined(separator: "\n"))
            }

            var views: [NSView] = [chip, pager]
            // Room left after chip, a minimum-width question, Other, Done, → Term, hide and spacing.
            let doneWidth: CGFloat = multi ? 64 : 0
            let fixed: CGFloat = Self.chipWidth + 160 + 84 + 72 + Self.iconButtonWidth + 6 * 9 + doneWidth
            let shown = Array(options.prefix(4))
            let titles = TextTools.fitLabels(shown, budget: Settings.barWidth - fixed,
                                             font: .systemFont(ofSize: 14, weight: .medium))
            for (label, title) in zip(shown, titles) {
                let selected = item.multiSelection.contains(label)
                let b = HoldButton(title, color: selected ? .systemBlue : NSColor(white: 0.32, alpha: 1))
                b.onComplete = { [weak self] in
                    guard let self else { return }
                    if multi {
                        if let i = item.multiSelection.firstIndex(of: label) {
                            item.multiSelection.remove(at: i)
                        } else {
                            item.multiSelection.append(label)
                        }
                        self.rebuild()
                    } else {
                        self.answer(item, questionText: questionText, answer: label, questions: questions, toolInput: toolInput)
                    }
                }
                views.append(b)
            }
            // Hold and say your own answer, like the terminal's "Other".
            let other = micButton({ .otherAnswer(itemId: item.id, questionIndex: index) }, title: "Other", width: 84)
            views.append(other)
            if multi {
                let done = HoldButton("Done", color: .systemGreen, width: 64)
                done.isEnabled = !item.multiSelection.isEmpty
                done.onComplete = { [weak self] in
                    let ordered = options.filter { item.multiSelection.contains($0) }
                    self?.answer(item, questionText: questionText, answer: ordered.joined(separator: ", "),
                                 questions: questions, toolInput: toolInput)
                }
                views.append(done)
            }
            views.append(toTerminal)
            return views
        }
    }

    private func answer(_ item: PendingItem, questionText: String, answer: String,
                        questions: [[String: Any]], toolInput: [String: Any]) {
        item.answers[questionText] = answer
        item.multiSelection = []
        item.questionIndex += 1
        if item.questionIndex >= questions.count {
            var updated = toolInput
            updated["answers"] = item.answers
            store.resolve(item, output: Decision.allow(updatedInput: updated))
        } else {
            rebuild()
        }
    }

    private func clearTranscript() {
        transcript = nil
        transcriptTarget = nil
    }

    /// Cancel and the mic (say it again), shared by every "check what you said" screen.
    private func reviewButtons(_ target: VoiceTarget) -> [NSView] {
        let cancel = HoldButton("Cancel", width: 72)
        cancel.onComplete = { [weak self] in
            self?.clearTranscript()
            self?.rebuild()
        }
        return [cancel, micButton { target }]
    }

    // Voice prompt waiting to be sent to the terminal.
    private func transcriptViews(_ text: String, sessionId: String) -> [NSView] {
        let target = store.session(sessionId)
        let chip = makeChip(title: "To \(target?.project ?? "?")", icon: Icon.mic.image(size: 12))
        let pager = makePager(text)

        let send = HoldButton("Send ➤", color: .systemGreen, width: 84)
        send.isEnabled = target != nil
        send.onComplete = { [weak self] in
            guard let self, let target else { return }
            let error = TerminalBridge.send(text, to: target.terminal)
            self.clearTranscript()
            self.flash(error ?? "Sent to \(target.project)")
        }
        return [chip, pager] + reviewButtons(.prompt(sessionId: sessionId)) + [send]
    }

    // Spoken deny reason or "Other" answer, waiting to go back through the hook.
    private func replyViews(_ text: String, target: VoiceTarget, item: PendingItem) -> [NSView] {
        let project = store.session(item.sessionId)?.project ?? "Claude"
        let pager = makePager(text)
        let send: HoldButton
        let chip: HoldButton

        switch (target, item.kind) {
        case (.denyReason, _):
            chip = makeChip(title: "Deny · \(project)", icon: Icon.mic.image(size: 12),
                            color: NSColor(red: 0.45, green: 0.1, blue: 0.1, alpha: 1))
            send = HoldButton("Deny ➤", color: .systemRed, width: 84)
            send.onComplete = { [weak self] in
                guard let self else { return }
                self.clearTranscript()
                self.store.resolve(item, output: Decision.deny(Decision.denyMessage(reason: text)))
                self.flash("Denied, and told Claude why")
            }

        case let (.otherAnswer(_, questionIndex), .question(questions, toolInput)):
            chip = makeChip(title: "Answer · \(project)", icon: Icon.mic.image(size: 12),
                            color: NSColor(red: 0.35, green: 0.15, blue: 0.5, alpha: 1))
            send = HoldButton("Answer ➤", color: .systemGreen, width: 96)
            send.isEnabled = questionIndex == item.questionIndex && questionIndex < questions.count
            send.onComplete = { [weak self] in
                guard let self, questionIndex == item.questionIndex, questionIndex < questions.count else { return }
                let q = questions[questionIndex]
                let labels = (q["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
                let ticked = labels.filter { item.multiSelection.contains($0) }
                self.clearTranscript()
                self.answer(item, questionText: q["question"] as? String ?? "",
                            answer: Decision.otherAnswer(selected: ticked, spoken: text),
                            questions: questions, toolInput: toolInput)
            }

        default: // Shouldn't happen: an "Other" answer for something that isn't a question.
            clearTranscript()
            return pendingViews(item)
        }
        return [chip, pager] + reviewButtons(target) + [send]
    }

    // MARK: - Voice

    private func startRecording(_ target: VoiceTarget) {
        if case let .prompt(sessionId) = target {
            // Prompts are typed into the terminal; replies go back through the hook and work anywhere.
            guard let session = store.session(sessionId) else { return }
            guard session.terminal.canReceiveText else {
                flash("Voice prompts need tmux or iTerm2 for this session (\(session.project))")
                return
            }
        }
        guard VoiceInput.isAuthorized else {
            VoiceInput.requestPermissions { [weak self] error in
                self?.flash(error ?? "Voice is ready. Hold the mic and talk.")
            }
            return
        }
        do {
            voice.onPartial = { [weak self] partial in
                self?.pager?.setText(partial, followTail: true)
            }
            try voice.start(localeId: Settings.voiceLocale)
            recordingTarget = target
            pager?.setText("Listening… release to stop", followTail: true)
        } catch {
            flash(error.localizedDescription)
        }
    }

    private func stopRecording() {
        guard voice.isRecording else { return }
        pager?.setText("Transcribing…")
        let target = recordingTarget
        recordingTarget = nil
        voice.stop { [weak self] text in
            guard let self else { return }
            if text.isEmpty || target == nil {
                self.flash("Didn't catch that. Hold the mic and try again.")
            } else {
                self.transcript = text
                self.transcriptTarget = target
                self.rebuild()
            }
        }
    }

    // MARK: - Flash messages

    private func flash(_ message: String) {
        flashMessage = message
        flashToken += 1
        let token = flashToken
        if isPresented, !voice.isRecording { rebuild() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
            guard let self, self.flashToken == token else { return }
            self.flashMessage = nil
            self.refresh()
        }
    }
}
