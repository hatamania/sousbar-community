import AppKit
import XCTest
@testable import SousBar

final class FeedParserTests: XCTestCase {
    func testRSS() throws {
        let xml = """
        <?xml version="1.0"?><rss version="2.0"><channel><title>Blog</title><link>https://blog</link>
        <item><title>Second &amp; last</title><link>https://blog/2</link><guid>b2</guid>
          <pubDate>Tue, 10 Nov 2026 09:00:00 +0000</pubDate></item>
        <item><title><![CDATA[First <b>post</b>]]></title><link>https://blog/1</link>
          <pubDate>Mon, 09 Nov 2026 09:00:00 GMT</pubDate></item>
        </channel></rss>
        """
        let items = try XCTUnwrap(FeedParser.parse(Data(xml.utf8)))
        XCTAssertEqual(items.map(\.title), ["Second & last", "First post"])
        XCTAssertEqual(items.map(\.id), ["b2", "https://blog/1"], "guid, else the link")
        XCTAssertEqual(items[0].link?.absoluteString, "https://blog/2")
        XCTAssertNotNil(items[1].date)
    }

    /// GitHub's feeds are Atom: <link href> attributes, <id>, <updated>.
    func testGitHubAtom() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom" xmlns:media="http://search.yahoo.com/mrss/">
          <id>tag:github.com,2008:https://github.com/o/r/releases</id><title>Release notes</title>
          <link rel="alternate" href="https://github.com/o/r/releases"/>
          <entry>
            <id>tag:github.com,2008:Repository/1/v1.2.0</id>
            <updated>2026-11-12T08:30:00Z</updated>
            <link rel="alternate" type="text/html" href="https://github.com/o/r/releases/tag/v1.2.0"/>
            <title>v1.2.0</title>
            <content type="html">&lt;p&gt;Notes&lt;/p&gt;</content>
            <author><name>someone</name></author>
          </entry>
        </feed>
        """
        let items = try XCTUnwrap(FeedParser.parse(Data(xml.utf8)))
        XCTAssertEqual(items.count, 1, "the feed's own id/link/title aren't an item")
        XCTAssertEqual(items[0].title, "v1.2.0")
        XCTAssertEqual(items[0].id, "tag:github.com,2008:Repository/1/v1.2.0")
        XCTAssertEqual(items[0].link?.absoluteString, "https://github.com/o/r/releases/tag/v1.2.0")
        XCTAssertEqual(items[0].date, ISO8601DateFormatter().date(from: "2026-11-12T08:30:00Z"))
    }

    /// Jira's activity stream: HTML titles, and nested objects with their own id/title/link.
    func testJiraActivityStream() throws {
        let xml = """
        <feed xmlns="http://www.w3.org/2005/Atom" xmlns:activity="http://activitystrea.ms/spec/1.0/">
          <entry>
            <id>urn:uuid:aaa</id>
            <title type="html">&lt;a href="https://x/people/1"&gt;Ann Lee&lt;/a&gt; changed the status to Done on &lt;a href="https://x/browse/SB-12"&gt;SB-12&lt;/a&gt;</title>
            <published>2026-11-12T08:00:00.123Z</published>
            <link rel="alternate" href="https://x/browse/SB-12"/>
            <activity:object><id>urn:obj</id><title>SB-12</title><link rel="alternate" href="https://x/other"/></activity:object>
          </entry>
        </feed>
        """
        let item = try XCTUnwrap(FeedParser.parse(Data(xml.utf8))?.first)
        XCTAssertEqual(item.title, "Ann Lee changed the status to Done on SB-12")
        XCTAssertEqual(item.id, "urn:uuid:aaa")
        XCTAssertEqual(item.link?.absoluteString, "https://x/browse/SB-12")
        XCTAssertNotNil(item.date, "fractional seconds")
    }

    func testNotAFeed() {
        XCTAssertNil(FeedParser.parse(Data("<html><body>login</body>".utf8)).flatMap { $0.isEmpty ? nil : $0 })
    }

    func testAgo() {
        let now = Date()
        XCTAssertEqual(FeedDate.ago(now.addingTimeInterval(-30), now: now), "now")
        XCTAssertEqual(FeedDate.ago(now.addingTimeInterval(-300), now: now), "5m")
        XCTAssertEqual(FeedDate.ago(now.addingTimeInterval(-7200), now: now), "2h")
    }
}

final class FeedStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var store: FeedStore!
    private var requests: [URLRequest] = []
    private var tokens: [String: String] = [:]
    private var updates: [[FeedEntry]] = []

    override func setUp() {
        defaults = UserDefaults(suiteName: "sousbar-feeds-\(UUID().uuidString)")
        store = makeStore()
    }

    private func makeStore() -> FeedStore {
        let s = FeedStore(defaults: defaults)
        s.fetch = { [unowned self] r, _ in requests.append(r) } // answered by hand via received()
        s.token = { [unowned self] in tokens[$0] }
        s.storeToken = { [unowned self] t, id in tokens[id] = t }
        s.onUpdate = { [unowned self] in updates.append($0) }
        return s
    }

    static func rss(_ ids: [String]) -> Data {
        let items = ids.enumerated().map { i, id in
            "<item><title>Item \(id)</title><guid>\(id)</guid><link>https://x/\(id)</link>" +
            "<pubDate>Thu, 12 Nov 2026 0\(i):00:00 +0000</pubDate></item>"
        }.joined()
        return Data("<rss><channel>\(items)</channel></rss>".utf8)
    }

    private func ok(_ id: String, _ data: Data, status: Int = 200) {
        let r = HTTPURLResponse(url: URL(string: "https://x")!, statusCode: status, httpVersion: nil, headerFields: [:])
        store.received(id, data, r, nil)
    }

    func testFirstCheckIsQuietThenNewItemsAreAnnounced() {
        let feed = store.add(name: "Jira", url: "https://x/feed", username: nil, token: nil)
        XCTAssertEqual(requests.count, 1, "checks right away")
        ok(feed.id, Self.rss(["a", "b"]))
        XCTAssertEqual(updates.last, [], "existing items aren't news")
        XCTAssertEqual(store.recent.map(\.item.id), ["b", "a"], "but they're there to browse, newest first")
        XCTAssertTrue(store.unread.isEmpty)

        ok(feed.id, Self.rss(["a", "b", "c"]))
        XCTAssertEqual(updates.last?.map(\.item.id), ["c"])
        XCTAssertEqual(store.unread.map(\.sourceName), ["Jira"])

        ok(feed.id, Self.rss(["a", "b", "c"]))
        let count = updates.count
        ok(feed.id, Self.rss(["a", "b", "c"]))
        XCTAssertEqual(updates.count, count, "nothing changed: no redraw")
        store.markAllRead()
        XCTAssertTrue(store.unread.isEmpty)
    }

    func testSeenItemsSurviveARestart() {
        let feed = store.add(name: "GH", url: "https://x/feed", username: nil, token: nil)
        ok(feed.id, Self.rss(["a"]))
        store = makeStore()
        XCTAssertEqual(store.sources.map(\.name), ["GH"])
        ok(feed.id, Self.rss(["a", "b"]))
        XCTAssertEqual(updates.last?.map(\.item.id), ["b"], "a was seen before the restart")
    }

    func testBasicAuthForJira() throws {
        let feed = store.add(name: "Jira", url: "https://site.atlassian.net/activity", username: "me@x.com", token: "tok")
        let auth = try XCTUnwrap(requests.last?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(auth, "Basic " + Data("me@x.com:tok".utf8).base64EncodedString())
        store.remove(feed.id)
        XCTAssertNil(tokens[feed.id], "removing a feed deletes its token")
    }

    func testErrorsAreReportedAndCleared() {
        let feed = store.add(name: "Jira", url: "https://x/feed", username: nil, token: nil)
        ok(feed.id, Data(), status: 401)
        XCTAssertEqual(store.errors[feed.id], "HTTP 401: check the login")
        ok(feed.id, Data("<html>sign in</html>".utf8))
        XCTAssertEqual(store.errors[feed.id], "not an RSS or Atom feed")
        ok(feed.id, Self.rss(["a"]))
        XCTAssertNil(store.errors[feed.id])
    }

    func testRejectsNonWebURLs() {
        let feed = store.add(name: "Bad", url: "file:///etc/passwd", username: nil, token: nil)
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(store.errors[feed.id], "not a web address")
    }
}

final class FeedsModuleTests: XCTestCase {
    private var store: Store!
    private var bar: TouchBarController!
    private var feeds: FeedStore!
    private var module: FeedsModule!
    private var opened: [URL] = []
    private var feedId = ""
    /// Requests waiting for a response, oldest first.
    private var answer: [(Data?, HTTPURLResponse?, Error?) -> Void] = []

    /// Answers the oldest request and lets the main queue deliver it.
    private func respond(_ data: Data?, status: Int = 200) {
        let r = HTTPURLResponse(url: URL(string: "https://x")!, statusCode: status, httpVersion: nil, headerFields: [:])
        answer.removeFirst()(data, r, nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    private var chip: HoldButton? { buttons.first { $0.title == "GitHub" } }

    override func setUp() {
        Settings.feedPeek = true
        store = Store()
        bar = TouchBarController(store: store)
        bar.systemPresent = { _, _ in }
        bar.systemMinimize = { _ in }
        feeds = FeedStore(defaults: UserDefaults(suiteName: "sousbar-feeds-\(UUID().uuidString)")!)
        feeds.fetch = { [unowned self] _, done in answer.append(done) }
        feeds.token = { _ in nil }
        feeds.storeToken = { _, _ in }
        module = FeedsModule(store: feeds)
        module.openURL = { [unowned self] in opened.append($0) }
        bar.modules = [module]
        feedId = feeds.add(name: "GitHub", url: "https://x/feed", username: nil, token: nil).id
        deliver(["a"])
    }

    private func deliver(_ ids: [String]) {
        let r = HTTPURLResponse(url: URL(string: "https://x")!, statusCode: 200, httpVersion: nil, headerFields: [:])
        feeds.received(feedId, FeedStoreTests.rss(ids), r, nil)
    }

    private var buttons: [HoldButton] { bar.itemViews.compactMap { $0 as? HoldButton } }
    private var texts: [String] {
        bar.itemViews.compactMap { ($0 as? NSTextField)?.stringValue ?? ($0 as? ScrollingTextView)?.string }
    }

    func testNewItemPopsUpOnTheBar() {
        XCTAssertFalse(bar.isPresented, "the first check is quiet")
        deliver(["a", "b"])
        XCTAssertTrue(bar.isPresented)
        XCTAssertTrue(bar.isPeeking)
        XCTAssertEqual(bar.mode, .module("feeds"))
        XCTAssertTrue(texts.contains { $0.hasPrefix("Item b") }, "\(texts)")
        XCTAssertEqual(buttons.first?.title, "", "the launcher button leads")
        XCTAssertTrue(buttons.contains { $0.title == "GitHub" })
    }

    func testTouchingItKeepsItOpen() {
        deliver(["a", "b"])
        // Open ↗ is the second-to-last module button before ✓ and hide.
        let open = buttons[buttons.count - 3]
        open.onComplete?()
        XCTAssertFalse(bar.isPeeking)
        XCTAssertEqual(opened.map(\.absoluteString), ["https://x/b"])
        XCTAssertTrue(feeds.unread.isEmpty, "opening an item marks it read")
    }

    func testNoPopUpWhenTurnedOffOrBusy() {
        Settings.feedPeek = false
        deliver(["a", "b"])
        XCTAssertFalse(bar.isPresented)
        Settings.feedPeek = true

        store.handle(["event": "PermissionRequest", "input": [
            "session_id": "s", "tool_name": "Bash", "tool_input": ["command": "ls"]]], reply: ReplyBox())
        deliver(["a", "b", "c"])
        XCTAssertFalse(bar.isPeeking, "never on top of an approval")
    }

    func testLauncherShowsTheUnreadCount() {
        deliver(["a", "b", "c"])
        bar.showLauncher()
        XCTAssertTrue(buttons.contains { $0.title == "Feeds · 2" }, "\(buttons.map(\.title))")
    }

    func testEmptyStateSaysHowToAdd() {
        feeds.remove(feedId)
        bar.open(moduleId: "feeds")
        XCTAssertTrue(texts.contains { $0.contains("Add Feed") }, "\(texts)")
    }
}

final class FeedContentTests: XCTestCase {
    func testHTMLBodyBecomesOneReadableLine() {
        let html = "<p>First &amp; <b>bold</b> paragraph.</p>\n<ul><li>one</li><li>two</li></ul><br/>Tail"
        XCTAssertEqual(FeedText.plain(html), "First & bold paragraph. · one · two · Tail")
    }

    func testParserKeepsTheFullestBody() throws {
        let xml = """
        <rss xmlns:content="http://purl.org/rss/1.0/modules/content/"><channel><item><guid>1</guid><title>T</title>
        <description>Short teaser</description>
        <content:encoded><![CDATA[<p>The whole story.</p><p>Second part.</p>]]></content:encoded>
        </item></channel></rss>
        """
        let item = try XCTUnwrap(FeedParser.parse(Data(xml.utf8))?.first)
        XCTAssertEqual(item.content, "The whole story. · Second part.")
    }

    func testAtomEscapedHTMLContent() throws {
        let xml = """
        <feed xmlns="http://www.w3.org/2005/Atom"><entry><id>x</id><title>v2</title>
        <content type="html">&lt;h2&gt;Changes&lt;/h2&gt;&lt;ul&gt;&lt;li&gt;Faster&lt;/li&gt;&lt;/ul&gt;</content></entry></feed>
        """
        XCTAssertEqual(try XCTUnwrap(FeedParser.parse(Data(xml.utf8))?.first).content, "Changes · Faster")
    }

    func testLongContentIsCapped() {
        let long = String(repeating: "word ", count: 5000)
        XCTAssertLessThanOrEqual(FeedText.plain(long).count, FeedText.maxContent + 1)
    }
}

final class ScrollPhysicsTests: XCTestCase {
    func testFollowsTheFinger() {
        var p = ScrollPhysics(maxOffset: 500)
        p.drag(by: -120) // finger moves left: text moves left, you read further
        XCTAssertEqual(p.offset, 120)
        p.drag(by: 20)
        XCTAssertEqual(p.offset, 100)
    }

    func testGlidesAfterAFlickAndSlowsDown() {
        var p = ScrollPhysics(maxOffset: 5000)
        p.release(fingerVelocity: -800)
        var steps = 0, last: CGFloat = 0
        while p.step(1.0 / 60) {
            steps += 1
            XCTAssertGreaterThan(p.offset, last)
            last = p.offset
        }
        XCTAssertGreaterThan(p.offset, 150, "a flick carries on")
        XCTAssertLessThan(steps, 60 * 4, "and comes to rest")
    }

    func testStopsAtTheEnds() {
        var p = ScrollPhysics(maxOffset: 100, offset: 90)
        p.release(fingerVelocity: -2000)
        while p.step(1.0 / 60) {}
        XCTAssertEqual(p.offset, 100)

        p.release(fingerVelocity: 2000)
        while p.step(1.0 / 60) {}
        XCTAssertEqual(p.offset, 0)
    }

    func testRubberBandsPastAnEndAndSpringsBack() {
        var p = ScrollPhysics(maxOffset: 100)
        p.drag(by: 10) // already at the start: pulls a little past it
        p.drag(by: 40)
        XCTAssertLessThan(p.offset, 0)
        XCTAssertGreaterThan(p.offset, -40, "resists")
        p.release(fingerVelocity: 0)
        while p.step(1.0 / 60) {}
        XCTAssertEqual(p.offset, 0)
    }

    func testProgress() {
        XCTAssertEqual(ScrollPhysics(maxOffset: 200, offset: 50).progress, 0.25)
        XCTAssertEqual(ScrollPhysics(maxOffset: 0).progress, 1, "everything fits")
    }
}

extension FeedsModuleTests {
    func testHoldingTheFeedNameChecksItNow() {
        answer.removeAll() // the check from adding it
        bar.open(moduleId: "feeds")
        XCTAssertEqual(chip?.subtitle, "hold ↻")

        chip?.onComplete?() // the hold filled up
        XCTAssertEqual(answer.count, 1, "fetched right away")
        XCTAssertEqual(chip?.subtitle, "Checking…")

        respond(FeedStoreTests.rss(["a", "b", "c"]))
        XCTAssertEqual(chip?.subtitle, "2 new")
        XCTAssertTrue(texts.contains { $0.hasPrefix("Item c") }, "shows the newest: \(texts)")

        chip?.onComplete?()
        respond(FeedStoreTests.rss(["a", "b", "c"]))
        XCTAssertEqual(chip?.subtitle, "Up to date")

        chip?.onComplete?()
        respond(Data(), status: 401)
        XCTAssertEqual(chip?.subtitle, "⚠︎ HTTP 401: check the login")
    }

    func testRefreshStatusGoesAway() {
        FeedsModule.statusDuration = 0.05
        defer { FeedsModule.statusDuration = 3 }
        answer.removeAll()
        bar.open(moduleId: "feeds")
        chip?.onComplete?()
        respond(FeedStoreTests.rss(["a"]))
        XCTAssertEqual(chip?.subtitle, "Up to date")
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(chip?.subtitle, "hold ↻")
    }
}
