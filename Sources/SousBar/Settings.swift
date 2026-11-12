import Foundation
import CoreGraphics

enum Settings {
    private static let defaults = UserDefaults.standard

    /// Option A: expand the full bar automatically when Claude needs an answer.
    static var autoExpand: Bool {
        get { defaults.object(forKey: "autoExpand") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "autoExpand") }
    }

    /// Seconds before an unanswered request falls back to the terminal. 0 = never.
    static var approvalTimeout: Double {
        get { defaults.object(forKey: "approvalTimeout") as? Double ?? 60 }
        set { defaults.set(newValue, forKey: "approvalTimeout") }
    }

    static var voiceLocale: String {
        get { defaults.string(forKey: "voiceLocale") ?? "en-US" }
        set { defaults.set(newValue, forKey: "voiceLocale") }
    }

    /// Width of the expanded bar content. The 16" Touch Bar is ~1085pt wide.
    /// If the expanded bar shows up empty, lower it:
    ///   defaults write local.sousbar.app barWidth -float 900
    static var barWidth: CGFloat {
        let v = defaults.double(forKey: "barWidth")
        return v > 300 ? CGFloat(v) : 960
    }

    /// Speed of the word-by-word reader, in words per minute.
    static var readingWPM: Int {
        get { RSVP.clamp(defaults.object(forKey: "readingWPM") as? Int ?? RSVP.defaultWPM) }
        set { defaults.set(RSVP.clamp(newValue), forKey: "readingWPM") }
    }

    /// Start the word-by-word reader by itself when you open the bar on a new reply. Off by default.
    static var autoRead: Bool {
        get { defaults.object(forKey: "autoRead") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "autoRead") }
    }

    /// Show new feed items on the Touch Bar for a few seconds as they arrive.
    static var feedPeek: Bool {
        get { defaults.object(forKey: "feedPeek") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "feedPeek") }
    }

    /// Seconds between feed checks.
    static var feedInterval: Double {
        get { defaults.object(forKey: "feedInterval") as? Double ?? 60 }
        set { defaults.set(newValue, forKey: "feedInterval") }
    }

    /// Which pull request events pop up on the bar: "mine" (your PRs and reviews), "all", or "off".
    static var prPopUp: String {
        get { defaults.string(forKey: "prPopUp") ?? "mine" }
        set { defaults.set(newValue, forKey: "prPopUp") }
    }

    /// The PRs bar shows only your PRs and your review requests.
    static var prOnlyMine: Bool {
        get { defaults.bool(forKey: "prOnlyMine") }
        set { defaults.set(newValue, forKey: "prOnlyMine") }
    }

    /// Seconds between GitHub checks.
    static var prInterval: Double {
        get { defaults.object(forKey: "prInterval") as? Double ?? 60 }
        set { defaults.set(newValue, forKey: "prInterval") }
    }

    /// The app was called AgentStrip (bundle id local.agentstrip.app). Copies your settings from
    /// there once, so a rename doesn't reset your speed, timeout, voice or bar width.
    static let legacyDomain = "local.agentstrip.app"
    static let migratedKeys = ["autoExpand", "approvalTimeout", "voiceLocale", "barWidth", "readingWPM", "autoRead"]

    @discardableResult
    static func migrateFromLegacy(from old: UserDefaults? = UserDefaults(suiteName: legacyDomain),
                                  to new: UserDefaults = defaults) -> [String] {
        guard new.object(forKey: "migratedFromAgentStrip") == nil, let old else { return [] }
        var copied: [String] = []
        for key in migratedKeys where new.object(forKey: key) == nil {
            if let value = old.object(forKey: key) {
                new.set(value, forKey: key)
                copied.append(key)
            }
        }
        new.set(true, forKey: "migratedFromAgentStrip")
        return copied
    }

    /// The user said "Not now" to connecting at first launch; don't ask again.
    static var declinedHookSetup: Bool {
        get { defaults.bool(forKey: "declinedHookSetup") }
        set { defaults.set(newValue, forKey: "declinedHookSetup") }
    }

    /// The first-launch setup window has been shown and closed.
    static var hasOnboarded: Bool {
        get { defaults.bool(forKey: "hasOnboarded") }
        set { defaults.set(newValue, forKey: "hasOnboarded") }
    }

    /// The setup window was opened but not finished yet (e.g. macOS quit the app to apply a permission).
    static var onboardingStarted: Bool {
        get { defaults.bool(forKey: "onboardingStarted") }
        set { defaults.set(newValue, forKey: "onboardingStarted") }
    }

    /// How long risky approvals (Bash, Write, Edit, MCP…) must be held.
    static let holdToAllow: TimeInterval = 0.7
}
