import AppKit
import SousCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = Store()
    private let server = HookServer()
    private var touchBar: TouchBarController!
    private var statusItem: NSStatusItem!
    private let feeds = FeedStore()
    private var feedsModule: FeedsModule!
    private let pulls = PRStore()
    private var prModule: PRModule!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Only one copy at a time.
        if let fd = UnixSocket.connect(path: SousPaths.socketPath) {
            close(fd)
            NSApp.terminate(nil)
            return
        }

        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            lastFrontApp = front
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(frontAppChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)

        Settings.migrateFromLegacy()
        touchBar = TouchBarController(store: store)
        store.onChange = { [weak self] in
            self?.touchBar.refresh()
            self?.updateStatusItem()
        }
        store.onNewPending = { [weak self] item in
            self?.touchBar.handleNewPending(item)
        }
        server.onMessage = { [weak self] message, reply in
            self?.store.handle(message, reply: reply)
        }
        server.onCancelled = { [weak self] box in
            self?.store.cancelled(box)
        }
        server.onTimedOut = { [weak self] box in
            self?.store.timedOut(box)
        }

        do {
            try server.start()
        } catch {
            let alert = NSAlert()
            alert.messageText = "SousBar couldn't start"
            alert.informativeText = "\(error)"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        if !PrivateTouchBar.isAvailable {
            NSLog("SousBar: system Touch Bar API not available on this macOS version")
        }
        touchBar.install()
        feedsModule = FeedsModule(store: feeds)
        prModule = PRModule(store: pulls)
        touchBar.modules = [feedsModule, prModule]
        feeds.start(interval: Settings.feedInterval)
        pulls.start(interval: Settings.prInterval)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.feeds.checkAll()
            self?.pulls.check()
        }
        setUpStatusItem()
        HookConnection.syncIfConnected()
        // After the menu bar item exists, so the app is fully up when the question appears.
        DispatchQueue.main.async {
            if Settings.hasOnboarded {
                HookConnection.offerIfNeeded()
            } else {
                OnboardingWindow.showIfNeeded()
            }
        }

        // Sessions that die without a SessionEnd (crash, kill -9, closed terminal) would
        // otherwise stay in the pill forever.
        // Also pick up sessions that were already running (e.g. after a reinstall) so they're
        // listed right away instead of after their next hook event.
        store.adoptRunning(Proc.runningAgents())
        let prune = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            self?.store.pruneDead()
            self?.store.adoptRunning(Proc.runningAgents())
        }
        RunLoop.main.add(prune, forMode: .common)
    }

    // MARK: - URL scheme

    /// The app that was in front before us, so a `sousbar://` link can hand focus back.
    private var lastFrontApp: NSRunningApplication?

    @objc private func frontAppChanged(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        lastFrontApp = app
    }

    /// For a button in MTMR, Pock, BetterTouchTool, Shortcuts, a hotkey app or a script:
    /// `sousbar://show` (launcher), `sousbar://claude`, `sousbar://open/<module>`,
    /// `sousbar://hide`, `sousbar://toggle`.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { handleURL(url) }
        // Opening a URL activates us unless the caller used `open -g`. We have no windows to
        // show, so give the keyboard back to the app you were using.
        if NSApp.isActive, NSApp.keyWindow == nil {
            lastFrontApp?.activate()
        }
    }

    private func handleURL(_ url: URL) {
        guard url.scheme?.lowercased() == "sousbar", let touchBar else { return }
        // sousbar://show and sousbar:show both work.
        let command = (url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).lowercased()
        switch command {
        case "show", "":
            touchBar.showLauncher()
        case "claude":
            touchBar.openClaude()
        case "open":
            let id = url.pathComponents.dropFirst().first ?? ""
            if id.isEmpty { touchBar.showLauncher() } else if !touchBar.open(moduleId: id.lowercased()) {
                NSLog("SousBar: no module \(id)")
            }
        case "hide", "close":
            touchBar.minimize()
        case "toggle":
            if touchBar.isPresented { touchBar.minimize() } else { touchBar.showLauncher() }
        default:
            NSLog("SousBar: unknown URL \(url)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.passAllToTerminal()
        server.stop()
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateStatusItem()
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        // The chef hat, tinted by state; a plain template (follows light/dark) when idle.
        let color: NSColor?
        if !store.pending.isEmpty {
            color = .systemOrange
        } else if store.sessions.values.contains(where: { $0.state.isWorking }) {
            color = .systemBlue
        } else if store.sessions.values.contains(where: { $0.unread }) {
            color = .systemGreen
        } else {
            color = nil
        }
        button.title = ""
        button.image = Icon.app.image(size: 17, color: color)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let sessions = store.sessionsByRecency
        if sessions.isEmpty {
            menu.addItem(disabled("No Claude Code sessions"))
        } else {
            for s in sessions {
                let state: String
                switch s.state {
                case .idle: state = "ready"
                case .thinking: state = "thinking"
                case .tool(let label): state = label
                case .waiting(let m): state = m
                case .done: state = "done"
                }
                menu.addItem(disabled("\(s.state.dot) \(s.project) — \(TextTools.truncate(state, 50))"))
            }
        }
        menu.addItem(.separator())
        menu.addItem(item("Show on Touch Bar", #selector(showBar)))
        menu.addItem(.separator())

        let auto = item("Open Touch Bar automatically for approvals", #selector(toggleAutoExpand))
        auto.state = Settings.autoExpand ? .on : .off
        menu.addItem(auto)

        let timeoutMenu = NSMenu()
        for (title, value) in [("30 seconds", 30.0), ("1 minute", 60.0), ("2 minutes", 120.0), ("5 minutes", 300.0), ("Never", 0.0)] {
            let i = item(title, #selector(setTimeoutValue(_:)))
            i.representedObject = value
            i.state = Settings.approvalTimeout == value ? .on : .off
            timeoutMenu.addItem(i)
        }
        let timeout = NSMenuItem(title: "Hand approvals to the terminal after", action: nil, keyEquivalent: "")
        timeout.submenu = timeoutMenu
        menu.addItem(timeout)

        let autoRead = item("Play new replies word by word", #selector(toggleAutoRead))
        autoRead.state = Settings.autoRead ? .on : .off
        menu.addItem(autoRead)

        let voiceMenu = NSMenu()
        for (title, id) in [("English", "en-US"), ("Tiếng Việt", "vi-VN")] {
            let i = item(title, #selector(setVoiceLocale(_:)))
            i.representedObject = id
            i.state = Settings.voiceLocale == id ? .on : .off
            voiceMenu.addItem(i)
        }
        let voiceItem = NSMenuItem(title: "Voice language", action: nil, keyEquivalent: "")
        voiceItem.submenu = voiceMenu
        menu.addItem(voiceItem)

        menu.addItem(feedsMenuItem())
        menu.addItem(pullsMenuItem())

        if LoginItem.isSupported {
            let login = item("Launch at login", #selector(toggleLaunchAtLogin))
            login.state = LoginItem.isEnabled ? .on : .off
            menu.addItem(login)
        }

        menu.addItem(.separator())
        if HookConnection.isConnected {
            menu.addItem(item("Disconnect from Claude Code…", #selector(disconnectHooks)))
        } else {
            menu.addItem(item("Connect to Claude Code…", #selector(connectHooks)))
        }
        menu.addItem(item("Setup Guide…", #selector(showSetup)))
        menu.addItem(.separator())
        menu.addItem(item("Quit SousBar", #selector(quit)))
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        return i
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    @objc private func showBar() { touchBar.present(auto: false) }

    // MARK: - Feeds

    private func feedsMenuItem() -> NSMenuItem {
        let sub = NSMenu()
        for source in feeds.sources {
            var title = source.name
            if let error = feeds.errors[source.id] {
                title += " — ⚠︎ \(error)"
            } else {
                let n = feeds.unread.filter { $0.sourceId == source.id }.count
                if n > 0 { title += " — \(n) new" }
            }
            let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let actions = NSMenu()
            let remove = item("Remove “\(source.name)”", #selector(removeFeed(_:)))
            remove.representedObject = source.id
            actions.addItem(disabled(TextTools.truncate(source.url, 60)))
            actions.addItem(remove)
            entry.submenu = actions
            sub.addItem(entry)
        }
        if feeds.sources.isEmpty { sub.addItem(disabled("No feeds yet")) }
        sub.addItem(.separator())
        sub.addItem(item("Add Feed…", #selector(addFeed)))
        let check = item("Check Now", #selector(checkFeeds))
        check.isEnabled = !feeds.sources.isEmpty
        sub.addItem(check)
        sub.addItem(item("Show Feeds on Touch Bar", #selector(openFeeds)))
        sub.addItem(.separator())
        let peek = item("Pop up new items on the Touch Bar", #selector(toggleFeedPeek))
        peek.state = Settings.feedPeek ? .on : .off
        sub.addItem(peek)
        let every = NSMenu()
        for (label, value) in [("30 seconds", 30.0), ("1 minute", 60.0), ("5 minutes", 300.0), ("15 minutes", 900.0)] {
            let i = item(label, #selector(setFeedInterval(_:)))
            i.representedObject = value
            i.state = Settings.feedInterval == value ? .on : .off
            every.addItem(i)
        }
        let everyItem = NSMenuItem(title: "Check every", action: nil, keyEquivalent: "")
        everyItem.submenu = every
        sub.addItem(everyItem)

        let unread = feeds.unread.count
        let top = NSMenuItem(title: unread > 0 ? "Feeds (\(unread) new)" : "Feeds", action: nil, keyEquivalent: "")
        top.submenu = sub
        return top
    }

    // MARK: - Pull requests

    private func pullsMenuItem() -> NSMenuItem {
        let sub = NSMenu()
        if let error = pulls.error {
            sub.addItem(disabled("⚠︎ \(TextTools.truncate(error, 70))"))
        } else if let at = pulls.lastChecked {
            let n = pulls.prs.count, mine = pulls.prs.filter(\.involvesYou).count
            sub.addItem(disabled("\(n) open · \(mine) yours or for your review · checked \(FeedDate.ago(at))"))
        }
        for (scope, total) in pulls.truncated {
            sub.addItem(disabled("“\(scope)” has \(total) open; showing the latest \(PRQuery.perScope)"))
        }
        sub.addItem(.separator())
        sub.addItem(disabled("Scopes (GitHub search)"))
        for scope in pulls.scopes {
            let entry = NSMenuItem(title: scope, action: nil, keyEquivalent: "")
            let actions = NSMenu()
            let remove = item("Remove “\(scope)”", #selector(removeScope(_:)))
            remove.representedObject = scope
            actions.addItem(remove)
            entry.submenu = actions
            sub.addItem(entry)
        }
        sub.addItem(item("Add Scope…", #selector(addScope)))
        sub.addItem(.separator())
        sub.addItem(item("Check Now", #selector(checkPulls)))
        sub.addItem(item("Show Pull Requests on Touch Bar", #selector(openPulls)))
        sub.addItem(.separator())
        let pop = NSMenu()
        for (label, value) in [("Mine and my reviews", "mine"), ("All pull requests", "all"), ("Never", "off")] {
            let i = item(label, #selector(setPRPopUp(_:)))
            i.representedObject = value
            i.state = Settings.prPopUp == value ? .on : .off
            pop.addItem(i)
        }
        let popItem = NSMenuItem(title: "Pop up on the Touch Bar for", action: nil, keyEquivalent: "")
        popItem.submenu = pop
        sub.addItem(popItem)
        let every = NSMenu()
        for (label, value) in [("30 seconds", 30.0), ("1 minute", 60.0), ("5 minutes", 300.0)] {
            let i = item(label, #selector(setPRInterval(_:)))
            i.representedObject = value
            i.state = Settings.prInterval == value ? .on : .off
            every.addItem(i)
        }
        let everyItem = NSMenuItem(title: "Check every", action: nil, keyEquivalent: "")
        everyItem.submenu = every
        sub.addItem(everyItem)

        let n = prModule?.attention.count ?? 0
        let top = NSMenuItem(title: n > 0 ? "Pull Requests (\(n) need you)" : "Pull Requests", action: nil, keyEquivalent: "")
        top.submenu = sub
        return top
    }

    @objc private func addScope() {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        field.placeholderString = "org:acme   or   repo:owner/name"
        let alert = NSAlert()
        alert.messageText = "Add a pull request scope"
        alert.informativeText = """
        Any GitHub search qualifier. SousBar shows every open PR it matches. Examples:
        • org:ins-enco: every repo in an org
        • repo:hatamania/sousbar-community: one repo
        • author:someone, team-review-requested:org/team, label:urgent
        """
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let scope = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !scope.isEmpty { pulls.add(scope: scope) }
    }

    @objc private func removeScope(_ sender: NSMenuItem) {
        if let scope = sender.representedObject as? String { pulls.remove(scope: scope) }
    }

    @objc private func checkPulls() { pulls.check() }

    @objc private func openPulls() { touchBar.open(moduleId: "prs") }

    @objc private func setPRPopUp(_ sender: NSMenuItem) {
        if let v = sender.representedObject as? String { Settings.prPopUp = v }
    }

    @objc private func setPRInterval(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? Double else { return }
        Settings.prInterval = v
        pulls.start(interval: v)
    }

    @objc private func addFeed() {
        guard let input = FeedForm.ask() else { return }
        feeds.add(name: input.name, url: input.url, username: input.username, token: input.token)
    }

    @objc private func removeFeed(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let source = feeds.sources.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "Remove “\(source.name)”?"
        alert.informativeText = "Its saved token is deleted from the Keychain too."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { feeds.remove(id) }
    }

    @objc private func checkFeeds() { feeds.checkAll() }

    @objc private func openFeeds() { touchBar.open(moduleId: "feeds") }

    @objc private func toggleFeedPeek() { Settings.feedPeek.toggle() }

    @objc private func setFeedInterval(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? Double else { return }
        Settings.feedInterval = v
        feeds.start(interval: v)
    }

    @objc private func toggleAutoExpand() { Settings.autoExpand.toggle() }

    @objc private func toggleAutoRead() { Settings.autoRead.toggle() }

    @objc private func setTimeoutValue(_ sender: NSMenuItem) {
        if let v = sender.representedObject as? Double { Settings.approvalTimeout = v }
    }

    @objc private func setVoiceLocale(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String {
            Settings.voiceLocale = id
            touchBar.refresh()
        }
    }

    @objc private func toggleLaunchAtLogin() { LoginItem.set(!LoginItem.isEnabled) }

    @objc private func showSetup() { OnboardingWindow.shared.show() }

    @objc private func connectHooks() { HookConnection.askToConnect() }

    @objc private func disconnectHooks() { HookConnection.askToDisconnect() }

    @objc private func quit() { NSApp.terminate(nil) }
}
