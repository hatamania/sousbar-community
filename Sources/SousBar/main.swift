import AppKit

signal(SIGPIPE, SIG_IGN)

// Build-time helper used by install.sh: SousBar --write-iconset <dir>
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--write-iconset" {
    exit(AppIcon.writeIconset(to: CommandLine.arguments[2]) ? 0 : 1)
}

let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
// Accessory = no Dock icon, never steals focus from the app you're working in.
app.setActivationPolicy(.accessory)
app.run()
