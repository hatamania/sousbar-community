import Foundation
import Security

// MARK: - Model

struct FeedItem: Equatable {
    var id: String
    var title: String
    var link: URL?
    var date: Date?
}

/// A feed you added: an RSS or Atom URL (GitHub, Jira, a blog…), with optional login.
struct FeedSource: Codable, Equatable {
    var id: String
    var name: String
    var url: String
    /// For HTTP Basic auth (Jira: your email). The token/password is in the Keychain.
    var username: String?
}

/// An item with the feed it came from (what the bar shows).
struct FeedEntry: Equatable {
    var sourceId: String
    var sourceName: String
    var item: FeedItem
}

// MARK: - Parsing (RSS 2.0, RSS 1.0/RDF, Atom)

enum FeedParser {
    static func parse(_ data: Data) -> [FeedItem]? {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        let ok = parser.parse()
        // A login page or an error page isn't an empty feed.
        guard ["rss", "feed", "rdf"].contains(delegate.root ?? ""), ok || !delegate.items.isEmpty else { return nil }
        return delegate.items
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var items: [FeedItem] = []
        /// The document's top element: rss, feed (Atom) or rdf (RSS 1.0).
        var root: String?
        private var inItem = false
        private var fields: [String: String] = [:]
        private var atomLink: String?
        private var text = ""

        private static func local(_ name: String) -> String {
            (name.split(separator: ":").last.map(String.init) ?? name).lowercased()
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            let el = Self.local(name)
            if root == nil { root = el }
            if el == "item" || el == "entry" {
                inItem = true
                fields = [:]
                atomLink = nil
            } else if inItem, el == "link", let href = attributes["href"] {
                // Atom: <link rel="alternate" href="…"/>. The first one without a rel, or alternate.
                let rel = attributes["rel"] ?? "alternate"
                if rel == "alternate", atomLink == nil { atomLink = href }
            }
            text = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, foundCDATA data: Data) {
            text += String(data: data, encoding: .utf8) ?? ""
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let el = Self.local(name)
            guard inItem else { return }
            if el == "item" || el == "entry" {
                inItem = false
                if let item = makeItem() { items.append(item) }
                return
            }
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty, fields[el] == nil { fields[el] = value }
            text = ""
        }

        private func makeItem() -> FeedItem? {
            let title = FeedText.clean(fields["title"] ?? "")
            let linkString = atomLink ?? fields["link"]
            let link = linkString.flatMap { URL(string: $0.trimmingCharacters(in: .whitespaces)) }
            let date = ["pubdate", "published", "updated", "date"].lazy.compactMap { self.fields[$0] }
                .compactMap(FeedDate.parse).first
            guard let id = fields["guid"] ?? fields["id"] ?? linkString ?? (title.isEmpty ? nil : title + (fields["pubdate"] ?? "")) else {
                return nil
            }
            return FeedItem(id: id, title: title.isEmpty ? "(untitled)" : title, link: link, date: date)
        }
    }
}

enum FeedText {
    /// Titles are often HTML (Jira's activity stream wraps names in links): tags out, entities
    /// decoded, whitespace collapsed.
    static func clean(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, char) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"),
                               ("&apos;", "'"), ("&nbsp;", " "), ("&amp;", "&")] {
            out = out.replacingOccurrences(of: entity, with: char)
        }
        return out.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

enum FeedDate {
    private static let rfc822: [DateFormatter] = [
        "EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz", "dd MMM yyyy HH:mm:ss Z",
        "EEE, dd MMM yyyy HH:mm Z",
    ].map { format in
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }

    private static let iso: [ISO8601DateFormatter] = {
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return [plain, fractional]
    }()

    static func parse(_ s: String) -> Date? {
        let s = s.trimmingCharacters(in: .whitespaces)
        for f in iso { if let d = f.date(from: s) { return d } }
        for f in rfc822 { if let d = f.date(from: s) { return d } }
        return nil
    }

    /// "now", "5m", "3h", "2d".
    static func ago(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "" }
        let s = max(0, Int(now.timeIntervalSince(date)))
        if s < 60 { return "now" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }
}

// MARK: - Tokens (Keychain)

enum FeedKeychain {
    private static let service = "local.sousbar.feeds"

    private static func query(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: id]
    }

    static func token(for id: String) -> String? {
        var q = query(id)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setToken(_ token: String?, for id: String) {
        SecItemDelete(query(id) as CFDictionary)
        guard let token, !token.isEmpty else { return }
        var q = query(id)
        q[kSecValueData as String] = Data(token.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }
}

// MARK: - Store: your feeds, polling, what's new

final class FeedStore {
    private let defaults: UserDefaults
    /// Fetches a URL. Swappable for tests.
    var fetch: (URLRequest, @escaping (Data?, HTTPURLResponse?, Error?) -> Void) -> Void = { request, done in
        URLSession.shared.dataTask(with: request) { data, response, error in
            done(data, response as? HTTPURLResponse, error)
        }.resume()
    }
    /// Reads a feed's token. Swappable so tests never touch the Keychain.
    var token: (String) -> String? = FeedKeychain.token(for:)
    var storeToken: (String?, String) -> Void = FeedKeychain.setToken(_:for:)

    private(set) var sources: [FeedSource]
    /// Latest items per feed, newest first.
    private(set) var items: [String: [FeedItem]] = [:]
    /// New since you last looked, newest first.
    private(set) var unread: [FeedEntry] = []
    /// Last error per feed ("HTTP 401", "not a feed"…), cleared on success.
    private(set) var errors: [String: String] = [:]
    /// Item ids already seen, per feed (kept across launches so a restart doesn't re-announce).
    private var seen: [String: [String]]
    private var etags: [String: String] = [:]
    private var timer: Timer?

    /// Called on the main thread after a check. `new` = items that weren't there before.
    var onUpdate: ((_ new: [FeedEntry]) -> Void)?

    static let maxItemsPerFeed = 50
    private static let maxSeenPerFeed = 300

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        sources = (defaults.data(forKey: "feeds")).flatMap { try? JSONDecoder().decode([FeedSource].self, from: $0) } ?? []
        seen = defaults.dictionary(forKey: "feedSeen") as? [String: [String]] ?? [:]
    }

    // MARK: Editing

    @discardableResult
    func add(name: String, url: String, username: String?, token: String?) -> FeedSource {
        let source = FeedSource(id: UUID().uuidString, name: name, url: url,
                                username: username?.isEmpty == false ? username : nil)
        if let token, !token.isEmpty { storeToken(token, source.id) }
        sources.append(source)
        saveSources()
        check(source)
        return source
    }

    func remove(_ id: String) {
        sources.removeAll { $0.id == id }
        items[id] = nil
        errors[id] = nil
        unread.removeAll { $0.sourceId == id }
        seen[id] = nil
        defaults.set(seen, forKey: "feedSeen")
        storeToken(nil, id)
        saveSources()
        onUpdate?([])
    }

    private func saveSources() {
        defaults.set(try? JSONEncoder().encode(sources), forKey: "feeds")
    }

    // MARK: Reading

    /// Everything recent across feeds, newest first (what the bar shows when nothing is unread).
    var recent: [FeedEntry] {
        let all = sources.flatMap { s in (items[s.id] ?? []).map { FeedEntry(sourceId: s.id, sourceName: s.name, item: $0) } }
        return Array(all.sorted { ($0.item.date ?? .distantPast) > ($1.item.date ?? .distantPast) }.prefix(30))
    }

    func markRead(_ entry: FeedEntry) {
        unread.removeAll { $0 == entry }
        onUpdate?([])
    }

    func markAllRead() {
        unread = []
        onUpdate?([])
    }

    // MARK: Polling

    func start(interval: TimeInterval) {
        timer?.invalidate()
        let t = Timer(timeInterval: max(15, interval), repeats: true) { [weak self] _ in self?.checkAll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        checkAll()
    }

    func checkAll() { sources.forEach(check) }

    func request(for source: FeedSource) -> URLRequest? {
        guard let url = URL(string: source.url), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        r.setValue("application/atom+xml, application/rss+xml, application/xml;q=0.9, */*;q=0.8", forHTTPHeaderField: "Accept")
        if let user = source.username, let pass = token(source.id) {
            r.setValue("Basic " + Data("\(user):\(pass)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        } else if let pass = token(source.id) {
            r.setValue("Bearer \(pass)", forHTTPHeaderField: "Authorization")
        }
        if let etag = etags[source.id] { r.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        return r
    }

    func check(_ source: FeedSource) {
        guard let request = request(for: source) else {
            errors[source.id] = "not a web address"
            onUpdate?([])
            return
        }
        fetch(request) { [weak self] data, response, error in
            DispatchQueue.main.async { self?.received(source.id, data, response, error) }
        }
    }

    /// Internal so tests can feed responses in directly.
    func received(_ id: String, _ data: Data?, _ response: HTTPURLResponse?, _ error: Error?) {
        guard let source = sources.first(where: { $0.id == id }) else { return } // removed meanwhile
        if let error {
            errors[id] = (error as NSError).localizedDescription
            onUpdate?([])
            return
        }
        if let status = response?.statusCode {
            if status == 304 { return }
            guard (200..<300).contains(status) else {
                errors[id] = status == 401 || status == 403 ? "HTTP \(status): check the login" : "HTTP \(status)"
                onUpdate?([])
                return
            }
        }
        guard let data, let parsed = FeedParser.parse(data) else {
            errors[id] = "not an RSS or Atom feed"
            onUpdate?([])
            return
        }
        if let etag = response?.value(forHTTPHeaderField: "ETag") { etags[id] = etag }
        errors[id] = nil

        let sorted = parsed.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        items[id] = Array(sorted.prefix(Self.maxItemsPerFeed))

        let firstLook = seen[id] == nil
        let known = Set(seen[id] ?? [])
        let fresh = sorted.filter { !known.contains($0.id) }
        seen[id] = Array((fresh.map(\.id) + (seen[id] ?? [])).prefix(Self.maxSeenPerFeed))
        defaults.set(seen, forKey: "feedSeen")

        // The first time we see a feed, everything in it is old news: don't announce 50 items.
        let new = firstLook ? [] : fresh.map { FeedEntry(sourceId: id, sourceName: source.name, item: $0) }
        unread = (new + unread).sorted { ($0.item.date ?? .distantPast) > ($1.item.date ?? .distantPast) }
        onUpdate?(new)
    }
}
