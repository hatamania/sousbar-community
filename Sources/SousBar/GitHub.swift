import Foundation

// MARK: - Model

enum CIState: String, Equatable {
    case passing, failing, running, none

    /// From a statusCheckRollup / check state.
    init(rollup: String?) {
        switch rollup?.uppercased() {
        case "SUCCESS": self = .passing
        case "FAILURE", "ERROR": self = .failing
        case "PENDING", "EXPECTED": self = .running
        default: self = .none
        }
    }

    var symbol: String {
        switch self {
        case .passing: return "✓"
        case .failing: return "✗"
        case .running: return "⋯"
        case .none: return ""
        }
    }
}

struct PRCheck: Equatable {
    var name: String
    var state: CIState
}

struct PullRequest: Equatable {
    /// "owner/repo#123"
    var id: String { "\(repo)#\(number)" }
    var repo: String
    var number: Int
    var title: String
    var url: URL?
    var author: String
    var isDraft: Bool
    /// APPROVED, CHANGES_REQUESTED, REVIEW_REQUIRED, or nil (no review needed).
    var reviewDecision: String?
    /// MERGEABLE, CONFLICTING, UNKNOWN
    var mergeable: String?
    var ci: CIState
    var checks: [PRCheck]
    var updatedAt: Date?
    /// You opened it.
    var isMine: Bool
    /// Someone asked you to review it.
    var reviewRequested: Bool

    /// Your PRs and the ones waiting on your review.
    var involvesYou: Bool { isMine || reviewRequested }

    /// Lower = shown first: failing CI, your review, changes requested, running, the rest.
    var rank: Int {
        if ci == .failing { return 0 }
        if reviewRequested { return 1 }
        if reviewDecision == "CHANGES_REQUESTED" { return 2 }
        if ci == .running { return 3 }
        return 4
    }

    var repoName: String { repo.split(separator: "/").last.map(String.init) ?? repo }
}

/// Something worth telling you about, found by comparing two checks.
struct PREvent: Equatable {
    enum Kind: Equatable { case opened, ciFailed, ciPassed, reviewRequested, approved, changesRequested }
    var kind: Kind
    var pr: PullRequest
    var date: Date

    var label: String {
        switch kind {
        case .opened: return "New PR"
        case .ciFailed: return "✗ CI failed"
        case .ciPassed: return "✓ CI passed"
        case .reviewRequested: return "Review requested"
        case .approved: return "✓ Approved"
        case .changesRequested: return "Changes requested"
        }
    }

    /// Pops up on the bar under `policy` ("mine", "all", "off").
    func popsUp(_ policy: String) -> Bool {
        switch policy {
        case "off": return false
        case "all": return pr.involvesYou || kind != .ciPassed // someone else's green build isn't news
        default: return pr.involvesYou
        }
    }
}

// MARK: - Query

enum PRQuery {
    /// Always searched (not shown as a scope), to know which PRs wait on your review.
    static let reviewMarker = "review-requested:@me"

    /// Results per scope. GitHub's search caps a page at 100.
    static let perScope = 50

    static func search(_ scope: String) -> String { "is:pr is:open archived:false \(scope)" }

    /// One GraphQL call for every scope: `s0…sN` are your scopes, `r` the review marker.
    static func graphQL(scopeCount: Int) -> String {
        let vars = (0..<scopeCount).map { "$q\($0): String!" } + ["$r: String!"]
        let searches = (0..<scopeCount).map {
            "s\($0): search(query: $q\($0), type: ISSUE, first: \(perScope)) { issueCount nodes { ...pr } }"
        }
        return """
        query(\(vars.joined(separator: ", "))) {
          viewer { login }
          \(searches.joined(separator: "\n  "))
          r: search(query: $r, type: ISSUE, first: 100) { nodes { ... on PullRequest { number repository { nameWithOwner } } } }
        }
        fragment pr on PullRequest {
          number title url isDraft updatedAt reviewDecision mergeable
          repository { nameWithOwner } author { login }
          commits(last: 1) { nodes { commit { statusCheckRollup { state contexts(first: 40) { nodes {
            ... on CheckRun { name status conclusion }
            ... on StatusContext { context state }
          } } } } } }
        }
        """
    }

    struct Result: Equatable {
        var prs: [PullRequest]
        /// Scopes that matched more than we fetched: (scope, total).
        var truncated: [(String, Int)]
        static func == (a: Result, b: Result) -> Bool {
            a.prs == b.prs && a.truncated.map(\.0) == b.truncated.map(\.0) && a.truncated.map(\.1) == b.truncated.map(\.1)
        }
    }

    /// Parses the response; nil if it isn't one (the error message is in `error`).
    static func parse(_ data: Data, scopes: [String], error: inout String?) -> Result? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            error = "unexpected reply from GitHub"
            return nil
        }
        if let errors = json["errors"] as? [[String: Any]], json["data"] == nil || json["data"] is NSNull {
            error = errors.first?["message"] as? String ?? "GitHub returned an error"
            return nil
        }
        guard let d = json["data"] as? [String: Any] else {
            error = "unexpected reply from GitHub"
            return nil
        }
        let me = ((d["viewer"] as? [String: Any])?["login"] as? String ?? "").lowercased()
        let waiting: Set<String> = Set(((d["r"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []).compactMap {
            guard let n = $0["number"] as? Int, let repo = ($0["repository"] as? [String: Any])?["nameWithOwner"] as? String
            else { return nil }
            return "\(repo)#\(n)"
        })

        var byId: [String: PullRequest] = [:]
        var order: [String] = []
        var truncated: [(String, Int)] = []
        for (i, scope) in scopes.enumerated() {
            guard let s = d["s\(i)"] as? [String: Any] else { continue }
            let nodes = s["nodes"] as? [[String: Any]] ?? []
            if let total = s["issueCount"] as? Int, total > nodes.count { truncated.append((scope, total)) }
            for node in nodes {
                guard var pr = pullRequest(node, me: me) else { continue }
                pr.reviewRequested = waiting.contains(pr.id)
                if byId[pr.id] == nil { order.append(pr.id) }
                byId[pr.id] = pr
            }
        }
        let prs = order.compactMap { byId[$0] }.sorted {
            $0.rank != $1.rank ? $0.rank < $1.rank : ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast)
        }
        return Result(prs: prs, truncated: truncated)
    }

    private static func pullRequest(_ n: [String: Any], me: String) -> PullRequest? {
        guard let number = n["number"] as? Int,
              let repo = (n["repository"] as? [String: Any])?["nameWithOwner"] as? String else { return nil }
        let author = (n["author"] as? [String: Any])?["login"] as? String ?? "ghost"
        let commit = (((n["commits"] as? [String: Any])?["nodes"] as? [[String: Any]])?.first?["commit"] as? [String: Any])
        let rollup = commit?["statusCheckRollup"] as? [String: Any]
        let contexts = (rollup?["contexts"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
        let checks: [PRCheck] = contexts.compactMap { c in
            if let name = c["name"] as? String { // CheckRun
                let state: CIState
                if (c["status"] as? String)?.uppercased() != "COMPLETED" {
                    state = .running
                } else {
                    switch (c["conclusion"] as? String)?.uppercased() {
                    case "SUCCESS", "NEUTRAL", "SKIPPED": state = .passing
                    case "FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE": state = .failing
                    default: state = .none
                    }
                }
                return PRCheck(name: name, state: state)
            }
            if let name = c["context"] as? String { // commit status
                return PRCheck(name: name, state: CIState(rollup: c["state"] as? String))
            }
            return nil
        }
        return PullRequest(
            repo: repo, number: number, title: n["title"] as? String ?? "",
            url: (n["url"] as? String).flatMap(URL.init(string:)), author: author,
            isDraft: n["isDraft"] as? Bool ?? false,
            reviewDecision: n["reviewDecision"] as? String, mergeable: n["mergeable"] as? String,
            ci: CIState(rollup: rollup?["state"] as? String), checks: checks,
            updatedAt: (n["updatedAt"] as? String).flatMap(FeedDate.parse),
            isMine: !me.isEmpty && author.lowercased() == me, reviewRequested: false)
    }

    /// What changed between two checks. Nothing on the first one (it's all old news).
    static func events(old: [PullRequest]?, new: [PullRequest], now: Date = Date()) -> [PREvent] {
        guard let old else { return [] }
        let before = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [PREvent] = []
        for pr in new {
            guard let was = before[pr.id] else {
                out.append(PREvent(kind: pr.reviewRequested ? .reviewRequested : .opened, pr: pr, date: now))
                continue
            }
            if pr.ci == .failing, was.ci != .failing { out.append(PREvent(kind: .ciFailed, pr: pr, date: now)) }
            if pr.ci == .passing, was.ci == .running { out.append(PREvent(kind: .ciPassed, pr: pr, date: now)) }
            if pr.reviewRequested, !was.reviewRequested { out.append(PREvent(kind: .reviewRequested, pr: pr, date: now)) }
            if pr.reviewDecision != was.reviewDecision {
                if pr.reviewDecision == "APPROVED" { out.append(PREvent(kind: .approved, pr: pr, date: now)) }
                if pr.reviewDecision == "CHANGES_REQUESTED" { out.append(PREvent(kind: .changesRequested, pr: pr, date: now)) }
            }
        }
        return out
    }
}

// MARK: - gh CLI

/// Runs your installed `gh` (so SousBar never stores a GitHub token).
enum GHCLI {
    /// Where gh usually lives. An app started from Finder doesn't get your shell's PATH.
    static let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "~/.local/bin/gh", "~/bin/gh",
                             "/usr/bin/gh", "/opt/local/bin/gh"].map { NSString(string: $0).expandingTildeInPath }

    static var path: String? = {
        if let p = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return p }
        // Last resort: ask a login shell.
        let out = run("/bin/zsh", ["-lc", "command -v gh"], timeout: 5)
        let p = out.stdout.flatMap { String(data: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines)
        return p.flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil }
    }()

    struct Output { var stdout: Data?; var stderr: String; var status: Int32 }

    static func run(_ exe: String, _ args: [String], timeout: TimeInterval = 30) -> Output {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["GH_PROMPT_DISABLED"] = "1"
        env["NO_COLOR"] = "1"
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return Output(stdout: nil, stderr: "\(error)", status: -1) }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errText = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        killer.cancel()
        return Output(stdout: data, stderr: errText, status: p.terminationStatus)
    }

    /// `gh api graphql` with string variables.
    static func graphQL(_ query: String, variables: [String: String]) -> Output {
        guard let gh = path else {
            return Output(stdout: nil, stderr: "gh isn't installed (brew install gh, then gh auth login)", status: -1)
        }
        var args = ["api", "graphql", "-f", "query=\(query)"]
        for (k, v) in variables.sorted(by: { $0.key < $1.key }) { args += ["-f", "\(k)=\(v)"] }
        return run(gh, args)
    }
}

// MARK: - Store

final class PRStore {
    private let defaults: UserDefaults
    /// Runs one GraphQL query. Swappable for tests. Called off the main thread.
    var query: (String, [String: String]) -> GHCLI.Output = GHCLI.graphQL(_:variables:)

    /// GitHub search qualifiers, one per line in the menu: `org:acme`, `repo:o/r`, `involves:@me`…
    private(set) var scopes: [String]
    private(set) var prs: [PullRequest] = []
    private(set) var truncated: [(String, Int)] = []
    private(set) var error: String?
    private(set) var lastChecked: Date?
    /// The latest thing that happened to each PR (shown on its card for a while).
    private(set) var recentEvents: [String: PREvent] = [:]
    private var loaded = false
    private var inFlight = false
    private var timer: Timer?

    /// Main thread, after every check that changed something. `events` = what's new.
    var onUpdate: ((_ events: [PREvent]) -> Void)?

    static let defaultScopes = ["involves:@me"]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        scopes = defaults.stringArray(forKey: "prScopes") ?? []
    }

    /// First run: your PRs plus every org you're in.
    var needsDefaultScopes: Bool { defaults.stringArray(forKey: "prScopes") == nil }

    func setScopes(_ new: [String]) {
        var seen = Set<String>()
        scopes = new.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        defaults.set(scopes, forKey: "prScopes")
        loaded = false // a different set of PRs: don't announce them all
        check()
    }

    func add(scope: String) { setScopes(scopes + [scope]) }
    func remove(scope: String) { setScopes(scopes.filter { $0 != scope }) }

    // MARK: Checking

    func start(interval: TimeInterval) {
        timer?.invalidate()
        let t = Timer(timeInterval: max(15, interval), repeats: true) { [weak self] _ in self?.check() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        check()
    }

    enum CheckResult: Equatable { case changed(Int), upToDate, failed(String) }

    /// Fetches every scope now. `done` runs on the main thread.
    func check(done: ((CheckResult) -> Void)? = nil) {
        if needsDefaultScopes {
            fetchDefaultScopes(then: done)
            return
        }
        guard !scopes.isEmpty else {
            let result = finish(error: "No scopes. Add one from the menu bar chef hat › Pull Requests.")
            done?(result)
            return
        }
        guard !inFlight else { done?(.upToDate); return }
        inFlight = true
        let scopes = self.scopes
        var vars = ["r": PRQuery.search(PRQuery.reviewMarker)]
        for (i, s) in scopes.enumerated() { vars["q\(i)"] = PRQuery.search(s) }
        let q = PRQuery.graphQL(scopeCount: scopes.count)
        let run = query
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let out = run(q, vars)
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight = false
                guard scopes == self.scopes else { return } // scopes changed meanwhile; that check is coming
                let result = self.received(out, scopes: scopes)
                done?(result)
            }
        }
    }

    /// Internal so tests can feed a reply in directly.
    @discardableResult
    func received(_ out: GHCLI.Output, scopes: [String]) -> CheckResult {
        var message: String?
        guard let data = out.stdout, !data.isEmpty, let result = PRQuery.parse(data, scopes: scopes, error: &message) else {
            return finish(error: Self.explain(out, parseError: message))
        }
        lastChecked = Date()
        let events = PRQuery.events(old: loaded ? prs : nil, new: result.prs)
        let changed = result.prs != prs || error != nil || !loaded
        loaded = true
        prs = result.prs
        truncated = result.truncated
        error = nil
        for e in events { recentEvents[e.pr.id] = e }
        let open = Set(prs.map(\.id))
        recentEvents = recentEvents.filter { open.contains($0.key) && Date().timeIntervalSince($0.value.date) < 3600 }
        if changed || !events.isEmpty { onUpdate?(events) }
        return changed ? .changed(events.count) : .upToDate
    }

    private func finish(error message: String) -> CheckResult {
        if error != message {
            error = message
            onUpdate?([])
        }
        return .failed(message)
    }

    static func explain(_ out: GHCLI.Output, parseError: String?) -> String {
        let err = out.stderr.lowercased()
        if err.contains("isn't installed") { return out.stderr }
        if err.contains("auth login") || err.contains("not logged") || err.contains("401") {
            return "gh is logged out: run gh auth login"
        }
        if err.contains("rate limit") { return "GitHub rate limit; trying again later" }
        if err.contains("could not resolve") || err.contains("dial tcp") || err.contains("timeout") { return "offline" }
        if let parseError { return parseError }
        let line = out.stderr.split(separator: "\n").first.map(String.init) ?? ""
        return line.isEmpty ? "gh failed (\(out.status))" : line
    }

    /// Asks GitHub which orgs you're in: scopes = involves:@me + org:… for each.
    private func fetchDefaultScopes(then done: ((CheckResult) -> Void)?) {
        guard !inFlight else { done?(.upToDate); return }
        inFlight = true
        let run = query
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let out = run("query { viewer { organizations(first: 50) { nodes { login } } } }", [:])
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight = false
                let json = out.stdout.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
                let nodes = (((json?["data"] as? [String: Any])?["viewer"] as? [String: Any])?["organizations"]
                    as? [String: Any])?["nodes"] as? [[String: Any]]
                guard let nodes else {
                    done?(self.finish(error: Self.explain(out, parseError: nil)))
                    return
                }
                self.setScopes(Self.defaultScopes + nodes.compactMap { $0["login"] as? String }.map { "org:\($0)" })
                done?(.upToDate)
            }
        }
    }
}
