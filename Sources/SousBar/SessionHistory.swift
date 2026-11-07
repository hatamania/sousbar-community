import AppKit

/// A conversation Claude Code saved for a folder (~/.claude/projects/<folder>/<id>.jsonl).
struct PastSession: Equatable {
    let id: String
    let title: String
    let updated: Date
}

/// Reads Claude Code's per-folder session history. Read-only; never writes there.
enum SessionHistory {
    static var projectsRoot: String { NSHomeDirectory() + "/.claude/projects" }

    /// Claude Code names a folder's history directory after its path, with every
    /// character that isn't a letter or digit turned into "-".
    static func encode(_ cwd: String) -> String {
        String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    /// The history directory: next to the live transcript if we know it, else derived from the path.
    static func directory(cwd: String, transcriptPath: String?) -> String {
        if let t = transcriptPath, !t.isEmpty { return (t as NSString).deletingLastPathComponent }
        return projectsRoot + "/" + encode(cwd)
    }

    /// Newest first. Only top-level `<id>.jsonl` files are sessions (subagent transcripts live in subfolders).
    static func list(in dir: String, limit: Int = 60) -> [PastSession] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        let files: [(id: String, path: String, date: Date)] = names.compactMap { name in
            guard name.hasSuffix(".jsonl") else { return nil }
            let path = dir + "/" + name
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  (attrs[.type] as? FileAttributeType) == .typeRegular,
                  let date = attrs[.modificationDate] as? Date else { return nil }
            return (String(name.dropLast(6)), path, date)
        }
        return files.sorted { $0.date > $1.date }.prefix(limit).compactMap { f in
            guard let title = title(ofTranscript: f.path) else { return nil } // no real prompt yet: skip
            return PastSession(id: f.id, title: title, updated: f.date)
        }
    }

    private static var titleCache: [String: (Date, String?)] = [:]
    private static let cacheLock = NSLock()

    /// Your own title (/rename), else Claude's generated title, else the last prompt, else the first one.
    /// Titles are repeated through the file, so the end of it is enough; the start is the fallback.
    static func title(ofTranscript path: String) -> String? {
        let date = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date ?? .distantPast
        cacheLock.lock()
        if let (cachedDate, title) = titleCache[path], cachedDate == date { cacheLock.unlock(); return title }
        cacheLock.unlock()

        let found = scanTitle(path)
        cacheLock.lock()
        titleCache[path] = (date, found)
        cacheLock.unlock()
        return found
    }

    private static func scanTitle(_ path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = handle.seekToEndOfFile()

        // Titles repeat through the file, so the newest ones are near the end. Read a small tail
        // first and widen only if it had none; scan backwards and parse at most one line per kind.
        for tail: UInt64 in [64 * 1024, 1024 * 1024] {
            handle.seek(toFileOffset: size > tail ? size - tail : 0)
            var custom: String?, ai: String?, last: String?
            for line in lines(handle.readDataToEndOfFile()).reversed() {
                if custom == nil, line.contains("\"custom-title\""), let t = field(line, "customTitle") {
                    custom = t
                    break // the best kind of title; nothing older can beat it
                }
                if ai == nil, line.contains("\"ai-title\""), let t = field(line, "aiTitle") { ai = t }
                else if last == nil, line.contains("\"last-prompt\""), let t = field(line, "lastPrompt") { last = t }
            }
            if let t = custom ?? ai ?? last { return tidy(t) }
            if size <= tail { break }
        }

        // Short or old files: the first prompt you typed.
        handle.seek(toFileOffset: 0)
        for line in lines(handle.readData(ofLength: 256 * 1024)) where line.contains("\"type\":\"user\"") {
            guard let obj = parse(line), obj["isSidechain"] as? Bool != true,
                  let message = obj["message"] as? [String: Any] else { continue }
            if let text = message["content"] as? String, let t = tidy(text) { return t }
            if let blocks = message["content"] as? [[String: Any]],
               let text = blocks.first(where: { $0["type"] as? String == "text" })?["text"] as? String,
               let t = tidy(text) { return t }
        }
        return nil
    }

    private static func lines(_ data: Data) -> [Substring] {
        String(decoding: data, as: UTF8.self).split(separator: "\n")
    }

    private static func parse(_ line: Substring) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
    }

    private static func field(_ line: Substring, _ key: String) -> String? {
        parse(line)?[key] as? String
    }

    /// One line, no markup or command noise, at most 80 characters.
    static func tidy(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("<") { return nil } // command/system wrappers like <command-name>, <local-command-stdout>
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return s.isEmpty ? nil : TextTools.truncate(s, 80)
    }

    /// "now", "5m ago", "3h ago", "2d ago", else a short date.
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let s = max(0, now.timeIntervalSince(date))
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m ago" }
        if s < 86400 { return "\(Int(s / 3600))h ago" }
        if s < 7 * 86400 { return "\(Int(s / 86400))d ago" }
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        return f.string(from: date)
    }
}

/// One row in the session picker.
struct PickerEntry: Equatable {
    enum Kind: Equatable {
        case live(SessionStatus) // running now: tap to switch
        case past                // from history: hold to resume
    }
    let id: String
    let title: String
    let subtitle: String
    let kind: Kind
}

enum SessionPicker {
    /// The chip's list: every running session in any folder, most recent first.
    /// Line 1 is the conversation's name; line 2 is "folder · status".
    static func active(live: [AgentSession], status: (AgentSession) -> SessionStatus,
                       title: (AgentSession) -> String?, subtitleWidth: CGFloat? = nil) -> [PickerEntry] {
        live.map { s in
            let st = status(s)
            return PickerEntry(id: s.id, title: title(s) ?? "New session",
                               subtitle: folderAndStatus(s.project, st.label, width: subtitleWidth), kind: .live(st))
        }
    }

    static let subtitleFont = NSFont.systemFont(ofSize: 11)

    /// "folder · Status", shortening the folder (never the status) to fit `width`.
    static func folderAndStatus(_ folder: String, _ status: String, width: CGFloat?) -> String {
        let tail = " · \(status)"
        guard let width else { return folder + tail }
        let tailWidth = ceil((tail as NSString).size(withAttributes: [.font: subtitleFont]).width)
        return TextTools.truncate(folder, toWidth: max(12, width - tailWidth), font: subtitleFont) + tail
    }

    /// The list button's view of one folder: its running sessions, then its saved history (newest first).
    /// Nothing from other folders; those are in the chip's list.
    static func entries(folder: String, live: [AgentSession], status: (AgentSession) -> SessionStatus,
                        title: (AgentSession) -> String? = { _ in nil },
                        history: [PastSession], now: Date = Date()) -> [PickerEntry] {
        let titles = Dictionary(history.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
        let here = live.filter { $0.cwd == folder }
        let hereIds = Set(here.map(\.id))
        return here.map { s in
            let st = status(s)
            return PickerEntry(id: s.id, title: titles[s.id] ?? title(s) ?? "New session",
                               subtitle: st.label, kind: .live(st))
        } + history.filter { !hereIds.contains($0.id) }.map {
            PickerEntry(id: $0.id, title: $0.title, subtitle: SessionHistory.relative($0.updated, now: now), kind: .past)
        }
    }
}
