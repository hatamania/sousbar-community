import AppKit
import SousCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = Store()
    private let server = HookServer()
    private var touchBar: TouchBarController!
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Only one copy at a time.
        if let fd = UnixSocket.connect(path: SousPaths.socketPath) {
            close(fd)
            NSApp.terminate(nil)
            return
        }

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
