import Foundation
import SousCore

/// Adds/removes our hook entries in ~/.claude/settings.json without touching anything else.
enum Installer {
    static var settingsPath: String { NSHomeDirectory() + "/.claude/settings.json" }

    /// (event, matcher, timeout seconds)
    static let events: [(String, String?, Int)] = [
        ("SessionStart", nil, 5),
        ("SessionEnd", nil, 5),
        ("UserPromptSubmit", nil, 5),
        ("PreToolUse", "*", 5),
        ("PostToolUse", "*", 5),
        ("PermissionRequest", "*", 600),
        ("Notification", nil, 5),
        ("Stop", nil, 5),
    ]

    /// Which agent these hooks are for. Every entry says so, so other agents can be added later
    /// without rewriting what's already in the user's settings.
    static let agent = "claude-code"

    static var command: String { "'\(SousPaths.hookBinary)' --agent \(agent)" }

    /// Our entries, including ones from before the rename (AgentStrip), which install replaces.
    static func isOurs(_ hook: Any) -> Bool {
        guard let command = (hook as? [String: Any])?["command"] as? String else { return false }
        return command.contains("sousbar-hook") || command.contains("agentstrip-hook")
    }

    static func removeOurs(from hooks: [String: Any]) -> [String: Any] {
        var result = hooks
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let cleaned: [[String: Any]] = groups.compactMap { group in
                var group = group
                guard var list = group["hooks"] as? [Any] else { return group }
                list.removeAll(where: isOurs)
                if list.isEmpty { return nil }
                group["hooks"] = list
                return group
            }
            if cleaned.isEmpty { result.removeValue(forKey: event) } else { result[event] = cleaned }
        }
        return result
    }

    /// Replaces any existing SousBar entries with a fresh set. Safe to run repeatedly.
    static func addOurs(to existing: [String: Any]) -> [String: Any] {
        var hooks = removeOurs(from: existing)
        for (event, matcher, timeout) in events {
            var group: [String: Any] = [
                "hooks": [["type": "command", "command": command, "timeout": timeout]],
            ]
            if let matcher { group["matcher"] = matcher }
            var groups = hooks[event] as? [[String: Any]] ?? []
            groups.append(group)
            hooks[event] = groups
        }
        return hooks
    }

    static func load() -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: settingsPath) else { return [:] }
        guard let data = FileManager.default.contents(atPath: settingsPath) else { return nil }
        if data.isEmpty { return [:] }
        return Wire.decode(data)
    }

    static func save(_ settings: [String: Any]) -> Bool {
        let dir = (settingsPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return false }
        return FileManager.default.createFile(atPath: settingsPath, contents: data)
    }

    static func backup() {
        guard FileManager.default.fileExists(atPath: settingsPath) else { return }
        let stamp = Int(Date().timeIntervalSince1970)
        let dest = settingsPath + ".sousbar-backup-\(stamp)"
        try? FileManager.default.copyItem(atPath: settingsPath, toPath: dest)
        print("Backed up settings to \(dest)")
    }

    static func install() -> Int32 {
        guard var settings = load() else {
            print("Couldn't parse \(settingsPath). Fix the JSON first; nothing was changed.")
            return 1
        }
        backup()
        settings["hooks"] = addOurs(to: settings["hooks"] as? [String: Any] ?? [:])
        guard save(settings) else {
            print("Couldn't write \(settingsPath).")
            return 1
        }
        print("Installed SousBar hooks into \(settingsPath). Restart running Claude Code sessions to pick them up.")
        return 0
    }

    static func uninstall() -> Int32 {
        guard var settings = load() else {
            print("Couldn't parse \(settingsPath); nothing was changed.")
            return 1
        }
        backup()
        let hooks = removeOurs(from: settings["hooks"] as? [String: Any] ?? [:])
        if hooks.isEmpty { settings.removeValue(forKey: "hooks") } else { settings["hooks"] = hooks }
        guard save(settings) else { return 1 }
        print("Removed SousBar hooks from \(settingsPath).")
        return 0
    }
}
