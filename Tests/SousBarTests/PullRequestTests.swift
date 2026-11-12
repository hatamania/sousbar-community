import AppKit
import XCTest
@testable import SousBar

/// Builds GitHub GraphQL replies the way `gh api graphql` returns them.
enum GHFixture {
    static func pr(_ repo: String, _ number: Int, title: String = "A change", author: String = "ann",
                   rollup: String? = "SUCCESS", checks: [[String: Any]] = [], review: String? = "REVIEW_REQUIRED",
                   draft: Bool = false, mergeable: String = "MERGEABLE", updated: String = "2026-11-12T08:00:00Z") -> [String: Any] {
        var commit: [String: Any] = [:]
        if let rollup { commit["statusCheckRollup"] = ["state": rollup, "contexts": ["nodes": checks]] }
        return ["number": number, "title": title, "url": "https://github.com/\(repo)/pull/\(number)", "isDraft": draft,
                "updatedAt": updated, "reviewDecision": review ?? NSNull(), "mergeable": mergeable,
                "repository": ["nameWithOwner": repo], "author": ["login": author],
                "commits": ["nodes": [["commit": commit]]]]
    }

    static func run(_ name: String, _ conclusion: String?, status: String = "COMPLETED") -> [String: Any] {
        ["name": name, "status": status, "conclusion": conclusion ?? NSNull()]
    }

    static func reply(me: String = "quan", scopes: [[[String: Any]]], waiting: [(String, Int)] = [], total: [Int]? = nil) -> Data {
        var data: [String: Any] = ["viewer": ["login": me]]
        for (i, nodes) in scopes.enumerated() {
            data["s\(i)"] = ["issueCount": total?[i] ?? nodes.count, "nodes": nodes]
        }
        data["r"] = ["nodes": waiting.map { ["number": $0.1, "repository": ["nameWithOwner": $0.0]] }]
        return try! JSONSerialization.data(withJSONObject: ["data": data])
    }
}

final class PRQueryTests: XCTestCase {
    func testParsesEveryPRWithChecksAndRanksWorstFirst() throws {
        let data = GHFixture.reply(scopes: [[
            GHFixture.pr("acme/web", 1, title: "Green one", updated: "2026-11-12T09:00:00Z"),
            GHFixture.pr("acme/web", 2, title: "Broken", rollup: "FAILURE", checks: [
                GHFixture.run("Lint", "SUCCESS"), GHFixture.run("Unit", "FAILURE"),
                GHFixture.run("Build", nil, status: "IN_PROGRESS"), ["context": "ci/legacy", "state": "ERROR"],
            ]),
            GHFixture.pr("acme/api", 3, title: "Mine", author: "Quan", rollup: "PENDING"),
            GHFixture.pr("acme/api", 4, title: "Asked of me", rollup: nil),
        ]], waiting: [("acme/api", 4)])
        var error: String?
        let r = try XCTUnwrap(PRQuery.parse(data, scopes: ["org:acme"], error: &error))
        XCTAssertEqual(r.prs.map(\.title), ["Broken", "Asked of me", "Mine", "Green one"],
                       "failing, your review, running, the rest")
        let broken = r.prs[0]
        XCTAssertEqual(broken.checks.map(\.state), [.passing, .failing, .running, .failing])
        XCTAssertEqual(broken.id, "acme/web#2")
        XCTAssertTrue(r.prs[1].reviewRequested)
        XCTAssertEqual(r.prs[1].ci, .none, "no checks at all")
        XCTAssertTrue(r.prs[2].isMine, "author matches you, ignoring case")
        XCTAssertFalse(r.prs[3].involvesYou)
    }

    func testScopesOverlapWithoutDuplicates() throws {
        let pr = GHFixture.pr("acme/web", 1)
        let data = GHFixture.reply(scopes: [[pr], [pr, GHFixture.pr("acme/web", 2)]], total: [1, 80])
        var error: String?
        let r = try XCTUnwrap(PRQuery.parse(data, scopes: ["involves:@me", "org:acme"], error: &error))
        XCTAssertEqual(r.prs.count, 2)
        XCTAssertEqual(r.truncated.map(\.0), ["org:acme"], "says when a scope has more than we fetched")
    }

    func testGitHubErrorsComeThrough() {
        let data = try! JSONSerialization.data(withJSONObject: ["errors": [["message": "Bad credentials"]]])
        var error: String?
        XCTAssertNil(PRQuery.parse(data, scopes: [], error: &error))
        XCTAssertEqual(error, "Bad credentials")
    }

    func testQueryHasOneSearchPerScope() {
        let q = PRQuery.graphQL(scopeCount: 2)
        XCTAssertTrue(q.contains("s0: search(query: $q0"))
        XCTAssertTrue(q.contains("s1: search(query: $q1"))
        XCTAssertFalse(q.contains("s2:"))
        XCTAssertEqual(PRQuery.search("org:acme"), "is:pr is:open archived:false org:acme")
    }

    private func pr(_ n: Int, ci: CIState = .passing, review: String? = nil, mine: Bool = false, asked: Bool = false) -> PullRequest {
        PullRequest(repo: "acme/web", number: n, title: "PR \(n)", url: nil, author: mine ? "me" : "ann", isDraft: false,
                    reviewDecision: review, mergeable: nil, ci: ci, checks: [], updatedAt: nil, isMine: mine, reviewRequested: asked)
    }

    func testEvents() {
        XCTAssertEqual(PRQuery.events(old: nil, new: [pr(1)]), [], "first check: nothing is news")
        let now = Date()
        let events = PRQuery.events(
            old: [pr(1, ci: .running, mine: true), pr(2, ci: .passing), pr(3), pr(4, review: "REVIEW_REQUIRED", mine: true)],
            new: [pr(1, ci: .passing, mine: true), pr(2, ci: .failing), pr(3, asked: true),
                  pr(4, review: "CHANGES_REQUESTED", mine: true), pr(5), pr(6, asked: true)], now: now)
        XCTAssertEqual(events.map(\.kind), [.ciPassed, .ciFailed, .reviewRequested, .changesRequested, .opened, .reviewRequested])
        XCTAssertEqual(events.map(\.pr.number), [1, 2, 3, 4, 5, 6])
    }

    func testWhatPopsUp() {
        let now = Date()
        let othersFailed = PREvent(kind: .ciFailed, pr: pr(1, ci: .failing), date: now)
        let othersPassed = PREvent(kind: .ciPassed, pr: pr(2), date: now)
        let minePassed = PREvent(kind: .ciPassed, pr: pr(3, mine: true), date: now)
        XCTAssertFalse(othersFailed.popsUp("mine"))
        XCTAssertTrue(minePassed.popsUp("mine"))
        XCTAssertTrue(othersFailed.popsUp("all"))
        XCTAssertFalse(othersPassed.popsUp("all"), "someone else's green build isn't news")
        XCTAssertFalse(minePassed.popsUp("off"))
    }

    func testExplainsGhProblems() {
        func explain(_ stderr: String) -> String {
            PRStore.explain(GHCLI.Output(stdout: nil, stderr: stderr, status: 1), parseError: nil)
        }
        XCTAssertEqual(explain("To get started with GitHub CLI, please run:  gh auth login"), "gh is logged out: run gh auth login")
        XCTAssertEqual(explain("error connecting to api.github.com\ncould not resolve host"), "offline")
        XCTAssertEqual(explain("API rate limit exceeded"), "GitHub rate limit; trying again later")
    }
}

final class PRModuleTests: XCTestCase {
    private var store: Store!
    private var bar: TouchBarController!
    private var pulls: PRStore!
    private var module: PRModule!
    private var queries: [[String: String]] = []
    private var opened: [URL] = []

    override func setUp() {
        Settings.prPopUp = "mine"
        Settings.prOnlyMine = false
        store = Store()
        bar = TouchBarController(store: store)
        bar.systemPresent = { _, _ in }
        bar.systemMinimize = { _ in }
        let defaults = UserDefaults(suiteName: "sousbar-prs-\(UUID().uuidString)")!
        defaults.set(["involves:@me", "org:acme"], forKey: "prScopes")
        pulls = PRStore(defaults: defaults)
        pulls.query = { [unowned self] _, vars in queries.append(vars); return GHCLI.Output(stdout: nil, stderr: "", status: 0) }
        module = PRModule(store: pulls)
        module.openURL = { [unowned self] in opened.append($0) }
        bar.modules = [module]
        deliver([GHFixture.pr("acme/web", 1, title: "Green one"),
                 GHFixture.pr("acme/web", 2, title: "My running one", author: "quan", rollup: "PENDING")])
    }

    private func deliver(_ prs: [[String: Any]], waiting: [(String, Int)] = []) {
        pulls.received(GHCLI.Output(stdout: GHFixture.reply(scopes: [[], prs], waiting: waiting), stderr: "", status: 0),
                       scopes: ["involves:@me", "org:acme"])
    }

    private var buttons: [HoldButton] { bar.itemViews.compactMap { $0 as? HoldButton } }
    private var strip: String? { bar.itemViews.compactMap { $0 as? ScrollingTextView }.first?.string }

    func testShowsAllPRsNotJustMine() {
        bar.open(moduleId: "prs")
        XCTAssertTrue(buttons.contains { $0.title == "#2 web" }, "running first: \(buttons.map(\.title))")
        XCTAssertEqual(module.list.count, 2)
        buttons.first { $0.title == "All" }?.onComplete?()
        XCTAssertEqual(module.list.map(\.number), [2], "Mine = yours and your reviews")
        buttons.first { $0.title == "Mine" }?.onComplete?()
        XCTAssertEqual(module.list.count, 2)
    }

    func testMyFailingBuildPopsUpAndTintsTheLauncher() {
        XCTAssertFalse(bar.isPresented, "the first check is quiet")
        deliver([GHFixture.pr("acme/web", 1, title: "Green one"),
                 GHFixture.pr("acme/web", 2, title: "My running one", author: "quan", rollup: "FAILURE",
                              checks: [GHFixture.run("Unit", "FAILURE"), GHFixture.run("Lint", "SUCCESS")])])
        XCTAssertTrue(bar.isPeeking)
        XCTAssertEqual(bar.mode, .module("prs"))
        XCTAssertTrue(strip?.hasPrefix("✗ CI failed") ?? false, strip ?? "")
        XCTAssertTrue(strip?.contains("Unit ✗") ?? false, "checks listed, failing first: \(strip ?? "")")
        XCTAssertEqual(module.tint, .systemRed)
        XCTAssertEqual(module.title, "PRs · 1")
    }

    func testSomeoneElsesFailureOnlyPopsUpWhenAskedFor() {
        deliver([GHFixture.pr("acme/web", 1, title: "Green one", rollup: "FAILURE"),
                 GHFixture.pr("acme/web", 2, title: "My running one", author: "quan", rollup: "PENDING")])
        XCTAssertFalse(bar.isPresented)

        Settings.prPopUp = "all"
        deliver([GHFixture.pr("acme/web", 1, title: "Green one", rollup: "FAILURE"),
                 GHFixture.pr("acme/web", 2, title: "My running one", author: "quan", rollup: "PENDING"),
                 GHFixture.pr("acme/web", 3, title: "Brand new")])
        XCTAssertTrue(bar.isPeeking, "a new PR, under All")
    }

    func testReviewRequestPopsUp() {
        deliver([GHFixture.pr("acme/web", 1, title: "Green one"),
                 GHFixture.pr("acme/web", 2, title: "My running one", author: "quan", rollup: "PENDING")],
                waiting: [("acme/web", 1)])
        XCTAssertTrue(bar.isPeeking)
        XCTAssertTrue(strip?.hasPrefix("Review requested") ?? false, strip ?? "")
        XCTAssertEqual(module.tint, .systemOrange)
    }

    func testHoldRefreshesAndOpenGoesToThePR() {
        bar.open(moduleId: "prs")
        let card = buttons.first { $0.title == "#2 web" }
        XCTAssertEqual(card?.subtitle, "⋯ 1 running", "CI at a glance")
        card?.onComplete?()
        XCTAssertEqual(buttons.first { $0.title == "#2 web" }?.subtitle, "Checking…")
        let exp = expectation(description: "check")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exp.fulfill() }
        wait(for: [exp], timeout: 1)
        XCTAssertEqual(queries.last?["q1"], "is:pr is:open archived:false org:acme")
        XCTAssertEqual(queries.last?["r"], "is:pr is:open archived:false review-requested:@me")

        buttons[buttons.count - 2].onComplete?() // ↗, before hide
        XCTAssertEqual(opened.map(\.absoluteString), ["https://github.com/acme/web/pull/2"])
    }

    func testGhProblemsShowOnTheBar() {
        pulls.received(GHCLI.Output(stdout: nil, stderr: "please run: gh auth login", status: 1), scopes: ["involves:@me", "org:acme"])
        XCTAssertEqual(pulls.error, "gh is logged out: run gh auth login")
        bar.open(moduleId: "prs")
        XCTAssertTrue(buttons.contains { $0.subtitle == "⚠︎ gh is logged out: run gh auth login" }, "the list stays; the card flags the problem")
    }
}

extension PRModuleTests {
    private func many(_ n: Int) -> [[String: Any]] {
        (1...n).map { GHFixture.pr("acme/web", $0, title: "PR \($0)", updated: "2026-11-12T0\($0 % 10):00:00Z") }
    }

    func testTappingTheCardListsEveryPR() throws {
        deliver(many(3))
        bar.open(moduleId: "prs")
        let card = try XCTUnwrap(buttons.first { $0.title.hasPrefix("#") })
        XCTAssertNotNil(card.onTap, "tap lists, hold refreshes")
        card.onTap?()
        XCTAssertTrue(module.showingList)
        let titles = buttons.map(\.title).filter { $0.hasPrefix("#") }
        XCTAssertEqual(titles.count, 3, "\(titles)")

        // Pick the last one: back to its card.
        let pick = try XCTUnwrap(buttons.last { $0.title.hasPrefix("#") })
        let picked = pick.title
        pick.onComplete?()
        XCTAssertFalse(module.showingList)
        XCTAssertEqual(buttons.first { $0.title.hasPrefix("#") }?.title, picked)
    }

    func testListPagesAndBack() throws {
        deliver(many(9))
        bar.open(moduleId: "prs")
        module.showList()
        let perPage = module.perPage
        XCTAssertLessThan(perPage, 9, "needs paging at this width")
        let first = buttons.filter { $0.title.hasPrefix("#") }.map(\.title)
        XCTAssertEqual(first.count, perPage)
        buttons[buttons.count - 3].onComplete?() // ↓, then All, then hide
        let second = buttons.filter { $0.title.hasPrefix("#") }.map(\.title)
        XCTAssertTrue(Set(first).isDisjoint(with: second), "next page: \(first) vs \(second)")

        buttons[1].onComplete?() // ‹ back, right after the launcher button
        XCTAssertFalse(module.showingList)
    }

    func testListFitsTheBar() {
        deliver(many(9))
        bar.open(moduleId: "prs")
        module.showList()
        let widths = bar.container.fittingSize.width + bar.rightContainer.fittingSize.width + TouchBarController.itemGap
        XCTAssertLessThanOrEqual(widths, Settings.barWidth + 1)
    }

    func testListSubtitleSaysWhatMatters() {
        func pr(_ edit: (inout PullRequest) -> Void) -> PullRequest {
            var p = PullRequest(repo: "a/b", number: 1, title: "", url: nil, author: "ann", isDraft: false, reviewDecision: nil,
                                mergeable: nil, ci: .passing, checks: [], updatedAt: nil, isMine: false, reviewRequested: false)
            edit(&p)
            return p
        }
        XCTAssertEqual(PRModule.listSubtitle(pr { $0.ci = .failing; $0.reviewRequested = true }), "✗ 1 failing")
        XCTAssertEqual(PRModule.listSubtitle(pr { $0.reviewRequested = true }), "your review")
        XCTAssertEqual(PRModule.listSubtitle(pr { $0.mergeable = "CONFLICTING" }), "conflicts")
        XCTAssertEqual(PRModule.listSubtitle(pr { $0.reviewDecision = "APPROVED" }), "✓ approved")
        XCTAssertEqual(PRModule.listSubtitle(pr { _ in }), "ann")
    }
}
