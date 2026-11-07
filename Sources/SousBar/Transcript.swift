import Foundation

enum Transcript {
    /// The text of Claude's last turn (everything after your last prompt),
    /// read from the session's JSONL transcript.
    static func lastAssistantText(path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }

        let size = handle.seekToEndOfFile()
        let window: UInt64 = 2_000_000
        let start = size > window ? size - window : 0
        handle.seek(toFileOffset: start)
        let data = handle.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self)

        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        if start > 0, !lines.isEmpty { lines.removeFirst() } // probably cut mid-line

        var parts: [String] = []
        for line in lines.reversed() {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            if obj["isSidechain"] as? Bool == true { continue }
            let type = obj["type"] as? String
            let message = obj["message"] as? [String: Any]

            if type == "assistant", let content = message?["content"] as? [[String: Any]] {
                let texts = content.compactMap { block -> String? in
                    block["type"] as? String == "text" ? block["text"] as? String : nil
                }
                let joined = texts.joined(separator: "\n")
                if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    parts.insert(joined, at: 0)
                }
            } else if type == "user" {
                // A real prompt (not a tool result) marks the start of this turn.
                if message?["content"] is String { break }
                if let content = message?["content"] as? [[String: Any]],
                   content.contains(where: { $0["type"] as? String == "text" }) { break }
            }
        }
        let result = parts.joined(separator: "\n\n")
        return result.isEmpty ? nil : result
    }
}
