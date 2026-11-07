import AppKit

enum TextTools {
    private static func replace(_ s: String, _ pattern: String, _ template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }

    /// Markdown → plain text that reads well on a one-line strip.
    /// Code blocks become a chip like ‹code · 12 lines›.
    static func stripMarkdown(_ markdown: String) -> String {
        var out: [String] = []
        var inCode = false
        var codeLines = 0

        func codeChip() -> String { "‹code · \(codeLines) line\(codeLines == 1 ? "" : "s")›" }

        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if inCode { out.append(codeChip()) } else { codeLines = 0 }
                inCode.toggle()
                continue
            }
            if inCode {
                codeLines += 1
                continue
            }
            if line.isEmpty { continue }
            // Table separator rows: |---|:---:|
            if line.range(of: #"^\|?\s*:?-{3,}"#, options: .regularExpression) != nil { continue }

            var l = line
            l = replace(l, #"^#{1,6}\s*"#, "")
            l = replace(l, #"^[-*+]\s+"#, "• ")
            l = replace(l, #"^>\s?"#, "")
            if l.hasPrefix("|") {
                l = l.trimmingCharacters(in: CharacterSet(charactersIn: "| "))
                    .components(separatedBy: "|")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .joined(separator: " · ")
            }
            l = replace(l, #"!?\[([^\]]+)\]\([^)]+\)"#, "$1")
            l = replace(l, #"(\*\*|__)(.+?)\1"#, "$2")
            l = replace(l, #"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*"#, "$1")
            l = replace(l, #"`([^`]+)`"#, "$1")
            out.append(l)
        }
        if inCode { out.append(codeChip()) }
        return out.joined(separator: "\n")
    }

    private static func sentences(_ line: String) -> [String] {
        var result: [String] = []
        line.enumerateSubstrings(in: line.startIndex..., options: .bySentences) { sub, _, _, _ in
            if let s = sub?.trimmingCharacters(in: .whitespaces), !s.isEmpty { result.append(s) }
        }
        return result.isEmpty ? [line] : result
    }

    /// Packs whole sentences into pages that fit `width` points.
    static func paginate(_ text: String, width: CGFloat, font: NSFont) -> [String] {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        func fits(_ s: String) -> Bool { (s as NSString).size(withAttributes: attrs).width <= width }

        var units: [String] = []
        for line in text.components(separatedBy: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            units.append(contentsOf: sentences(line))
        }

        var pages: [String] = []
        var current = ""
        for unit in units {
            if !fits(unit) {
                // Long sentence: break it on word boundaries.
                if !current.isEmpty { pages.append(current) }
                current = ""
                for word in unit.split(separator: " ") {
                    let candidate = current.isEmpty ? String(word) : current + " " + word
                    if fits(candidate) || current.isEmpty {
                        current = candidate
                    } else {
                        pages.append(current)
                        current = String(word)
                    }
                }
                continue
            }
            let candidate = current.isEmpty ? unit : current + " " + unit
            if fits(candidate) {
                current = candidate
            } else {
                pages.append(current)
                current = unit
            }
        }
        if !current.isEmpty { pages.append(current) }
        return pages.isEmpty ? [""] : pages
    }

    static func truncate(_ s: String, _ max: Int) -> String {
        s.count <= max ? s : String(s.prefix(max - 1)) + "…"
    }

    /// Cuts `s` (adding "…") so it fits `width` points in `font`.
    static func truncate(_ s: String, toWidth width: CGFloat, font: NSFont) -> String {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        func fits(_ t: String) -> Bool { ceil((t as NSString).size(withAttributes: attrs).width) <= width }
        if fits(s) { return s }
        var lo = 0, hi = s.count // binary search on how many characters fit before the "…"
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if fits(String(s.prefix(mid)).trimmingCharacters(in: .whitespaces) + "…") { lo = mid } else { hi = mid - 1 }
        }
        return String(s.prefix(lo)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Shortens the longest button labels until they fit in `budget` points, so a row never
    /// grows wider than the Touch Bar (which would make the whole bar show up empty).
    /// `padding` is each button's width beyond its text; `minWidth` matches HoldButton's minimum.
    static func fitLabels(_ labels: [String], budget: CGFloat, font: NSFont,
                          startAt: Int = 18, floor: Int = 4,
                          padding: CGFloat = 22, minWidth: CGFloat = 44, spacing: CGFloat = 6) -> [String] {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        func total(_ ls: [String]) -> CGFloat {
            ls.reduce(0) { sum, l in
                sum + max(minWidth, ceil((l as NSString).size(withAttributes: attrs).width) + padding) + spacing
            }
        }
        // Trim the longest label one character at a time, so short labels stay whole.
        var limits = labels.map { min($0.count, startAt) }
        var result = zip(labels, limits).map { truncate($0, $1) }
        while total(result) > budget,
              let i = limits.indices.filter({ limits[$0] > floor }).max(by: { limits[$0] < limits[$1] }) {
            limits[i] -= 1
            result[i] = truncate(labels[i], limits[i])
        }
        return result
    }
}

enum ToolText {
    /// Tools that only read. These can be allowed with a single tap;
    /// everything else needs a hold.
    static let readOnly: Set<String> = [
        "Read", "Glob", "Grep", "LS", "WebSearch", "WebFetch", "NotebookRead", "TodoWrite",
    ]

    static func displayName(_ tool: String) -> String {
        if tool.hasPrefix("mcp__") {
            let parts = tool.dropFirst(5).components(separatedBy: "__")
            return parts.joined(separator: "·")
        }
        return tool
    }

    private static func shortPath(_ value: Any?) -> String {
        guard let path = value as? String else { return "" }
        let comps = path.split(separator: "/")
        return comps.suffix(2).joined(separator: "/")
    }

    private static func compactJSON(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes]),
              let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }

    /// One-line description of what the tool is about to do.
    static func summary(_ tool: String, _ input: [String: Any]) -> String {
        switch tool {
        case "Bash":
            return (input["command"] as? String ?? "").replacingOccurrences(of: "\n", with: " ⏎ ")
        case "Edit", "MultiEdit", "Write", "Read":
            return shortPath(input["file_path"])
        case "NotebookEdit", "NotebookRead":
            return shortPath(input["notebook_path"])
        case "WebFetch":
            return input["url"] as? String ?? ""
        case "WebSearch":
            return input["query"] as? String ?? ""
        case "Glob", "Grep":
            return input["pattern"] as? String ?? ""
        case "Task", "Agent":
            return input["description"] as? String ?? ""
        case "ExitPlanMode":
            return "Approve the plan"
        default:
            return compactJSON(input)
        }
    }

    /// Full detail for the reader panel (Markdown).
    static func detail(_ tool: String, _ input: [String: Any]) -> String {
        switch tool {
        case "Bash":
            let desc = (input["description"] as? String).map { "\($0)\n\n" } ?? ""
            return "\(desc)```\n\(input["command"] as? String ?? "")\n```"
        case "ExitPlanMode":
            return input["plan"] as? String ?? ""
        default:
            guard let data = try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
                  let s = String(data: data, encoding: .utf8) else { return "" }
            return "```\n\(s)\n```"
        }
    }

    static func shortLabel(_ tool: String, _ input: [String: Any]) -> String {
        let s = summary(tool, input)
        let name = displayName(tool)
        return s.isEmpty ? name : "\(name): \(TextTools.truncate(s, 60))"
    }
}

/// Claude Code's "don't ask again" suggestions (`permission_suggestions` on PermissionRequest).
/// SousBar never writes rules of its own: Always sends these back unchanged as `updatedPermissions`.
enum AlwaysRules {
    /// Keeps only well-formed entries (objects with a string `type`).
    static func usable(_ raw: Any?) -> [[String: Any]] {
        (raw as? [Any] ?? []).compactMap { $0 as? [String: Any] }.filter { $0["type"] is String }
    }

    private static func place(_ destination: Any?) -> String? {
        switch destination as? String {
        case "session": return "for this session"
        case "localSettings": return "in this project"
        case "projectSettings": return "in this project (shared settings)"
        case "userSettings": return "in all projects"
        case "cliArg": return "for this run"
        default: return nil
        }
    }

    private static func rule(_ r: [String: Any]) -> String? {
        guard let tool = r["toolName"] as? String else { return nil }
        let name = ToolText.displayName(tool)
        guard let content = r["ruleContent"] as? String, !content.isEmpty else { return name }
        return "\(name)(\(content))"
    }

    private static func describeOne(_ s: [String: Any]) -> String {
        var what: String
        switch s["type"] as? String {
        case "addRules", "replaceRules":
            let rules = (s["rules"] as? [[String: Any]] ?? []).compactMap(rule)
            what = rules.isEmpty ? "these tools" : rules.joined(separator: ", ")
            if let behavior = s["behavior"] as? String, behavior != "allow" { what = "\(behavior): \(what)" }
        case "setMode":
            what = "\(s["mode"] as? String ?? "a different") mode"
        case "addDirectories":
            let dirs = (s["directories"] as? [String] ?? []).map { ($0 as NSString).abbreviatingWithTildeInPath }
            what = "access to " + (dirs.isEmpty ? "more folders" : dirs.joined(separator: ", "))
        default:
            what = "a permission change"
        }
        if let place = place(s["destination"]) { what += " \(place)" }
        return what
    }

    /// "Bash(npm run build:*) in this project", or nil when there's nothing to offer.
    static func describe(_ suggestions: [[String: Any]]) -> String? {
        guard !suggestions.isEmpty else { return nil }
        return suggestions.map(describeOne).joined(separator: "; ")
    }
}
