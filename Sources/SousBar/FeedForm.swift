import AppKit

/// The "Add Feed…" dialog.
enum FeedForm {
    struct Input { var name, url: String; var username, token: String? }

    static func ask() -> Input? {
        let name = field("GitHub releases")
        let url = field("https://github.com/owner/repo/releases.atom")
        let user = field("optional: Jira email")
        let token = NSSecureTextField()
        token.placeholderString = "optional: API token (kept in the Keychain)"

        let grid = NSGridView(views: [
            [label("Name"), name], [label("Feed URL"), url], [label("Username"), user], [label("Token"), token],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        for f in [name, url, user, token] { f.widthAnchor.constraint(equalToConstant: 340).isActive = true }
        grid.frame = NSRect(x: 0, y: 0, width: 420, height: 120)

        let alert = NSAlert()
        alert.messageText = "Add a feed"
        alert.informativeText = """
        Any RSS or Atom URL. For example:
        • GitHub: github.com/OWNER/REPO/releases.atom, …/commits/BRANCH.atom, or your private \
        dashboard feed (github.com/USER.private.atom?token=…, from the feed link on your GitHub dashboard)
        • Jira Cloud: SITE.atlassian.net/activity with your email as Username and an API token \
        (id.atlassian.com › Security › API tokens)
        """
        alert.accessoryView = grid
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = name
        NSApp.activate(ignoringOtherApps: true)

        while alert.runModal() == .alertFirstButtonReturn {
            var link = url.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !link.isEmpty, !link.contains("://") { link = "https://" + link }
            guard let parsed = URL(string: link), ["http", "https"].contains(parsed.scheme ?? ""), parsed.host != nil else {
                alert.informativeText = "That isn't a web address. Paste the feed's full URL (https://…)."
                continue
            }
            let title = name.stringValue.trimmingCharacters(in: .whitespaces)
            return Input(name: title.isEmpty ? (parsed.host ?? "Feed") : title, url: link,
                         username: user.stringValue.trimmingCharacters(in: .whitespaces), token: token.stringValue)
        }
        return nil
    }

    private static func field(_ placeholder: String) -> NSTextField {
        let f = NSTextField()
        f.placeholderString = placeholder
        return f
    }

    private static func label(_ s: String) -> NSTextField { NSTextField(labelWithString: s) }
}
