import AppKit
import XCTest
@testable import SousBar

final class RSVPTests: XCTestCase {
    func testTokenizeKeepsCodeChipsAndDropsBullets() {
        let plain = TextTools.stripMarkdown("Fixed it.\n\n- one\n- two\n\n```\na\nb\n```\nDone")
        let tokens = RSVP.tokenize(plain)
        XCTAssertEqual(tokens.map(\.text), ["Fixed", "it.", "one", "two", "‹code · 2 lines›", "Done"])
        XCTAssertNil(tokens[4].focus, "code chips are centered, not focus-aligned")
    }

    func testSentenceStarts() {
        let tokens = RSVP.tokenize("One two. Three four! Five\nSix seven")
        XCTAssertEqual(tokens.filter(\.startsSentence).map(\.text), ["One", "Three", "Five", "Six"])
    }

    func testClosingQuotesStillEndASentence() {
        XCTAssertTrue(RSVP.endsSentence("done.\""))
        XCTAssertTrue(RSVP.endsSentence("(really?)"))
        XCTAssertTrue(RSVP.endsSentence("wait…"))
        XCTAssertFalse(RSVP.endsSentence("e.g"))
        XCTAssertFalse(RSVP.endsSentence("word,"))
    }

    func testPausesFollowPunctuation() {
        let plain = RSVP.weight("word", endOfLine: false)
        XCTAssertEqual(plain, 1)
        XCTAssertGreaterThan(RSVP.weight("word,", endOfLine: false), plain)
        XCTAssertGreaterThan(RSVP.weight("word.", endOfLine: false), RSVP.weight("word,", endOfLine: false))
        XCTAssertGreaterThanOrEqual(RSVP.weight("word", endOfLine: true), RSVP.weight("word.", endOfLine: false))
    }

    func testTechnicalAndLongWordsLinger() {
        XCTAssertGreaterThan(RSVP.weight("src/lib/index.ts", endOfLine: false), 1.3)
        XCTAssertGreaterThan(RSVP.weight("48", endOfLine: false), 1.3)
        XCTAssertGreaterThan(RSVP.weight("snake_case", endOfLine: false), 1.3)
        XCTAssertGreaterThan(RSVP.weight("internationalization", endOfLine: false), 1.3)
        XCTAssertEqual(RSVP.weight("‹code · 9 lines›", endOfLine: false), 3.5)
    }

    func testFocusIndex() {
        XCTAssertEqual(RSVP.focusIndex("a"), 0)
        XCTAssertEqual(RSVP.focusIndex("read"), 1)
        XCTAssertEqual(RSVP.focusIndex("reading"), 2)
        XCTAssertEqual(RSVP.focusIndex("comprehension"), 3)
        XCTAssertEqual(RSVP.focusIndex("internationalization"), 4)
        XCTAssertEqual(RSVP.focusIndex("\"quoted\""), 3, "leading quote doesn't count")
        XCTAssertEqual(RSVP.focusIndex("—"), 0)
    }

    func testClampAndDuration() {
        XCTAssertEqual(RSVP.clamp(10), 150)
        XCTAssertEqual(RSVP.clamp(9999), 700)
        XCTAssertEqual(RSVP.clamp(330), 350)
        let word = RSVPToken(text: "word", weight: 1, startsSentence: false, focus: 1)
        XCTAssertEqual(RSVP.duration(word, at: 10, wpm: 300), 0.2, accuracy: 0.0001)
        XCTAssertEqual(RSVP.duration(word, at: 0, wpm: 300), 0.36, accuracy: 0.0001, "warm-up")
        XCTAssertEqual(RSVP.duration(word, at: 10, wpm: 600), 0.1, accuracy: 0.0001)
    }
}

final class SpeedReaderEngineTests: XCTestCase {
    private func engine(_ text: String = "One two. Three four. Five six.") -> SpeedReaderEngine {
        SpeedReaderEngine(text: text, wpm: 300)
    }

    func testPlaysToTheEndThenStops() {
        let e = engine()
        e.play()
        var steps = 0
        while e.advance() { steps += 1 }
        XCTAssertEqual(steps, 5)
        XCTAssertFalse(e.isPlaying)
        XCTAssertTrue(e.isAtEnd)
        XCTAssertEqual(e.progress, 1)
        e.play()
        XCTAssertEqual(e.index, 0, "play at the end starts over")
    }

    func testSentenceJumps() {
        let e = engine()
        e.nextSentence(); XCTAssertEqual(e.current?.text, "Three")
        e.nextSentence(); XCTAssertEqual(e.current?.text, "Five")
        e.nextSentence(); XCTAssertEqual(e.current?.text, "six.", "stops at the last word")
        e.previousSentence(); XCTAssertEqual(e.current?.text, "Five")
        e.advance()
        e.previousSentence(); XCTAssertEqual(e.current?.text, "Five", "mid-sentence goes to this sentence's start")
        e.previousSentence(); XCTAssertEqual(e.current?.text, "Three")
        e.previousSentence(); e.previousSentence(); XCTAssertEqual(e.index, 0)
    }

    func testWarmupRestartsAfterJump() {
        let e = engine("a b c d e f g h. i j k")
        e.play()
        for _ in 0..<6 { e.advance() }
        let cruising = e.currentDuration
        e.nextSentence()
        XCTAssertGreaterThan(e.currentDuration, cruising, "slower start after a jump")
    }

    func testSpeedSteps() {
        let e = engine()
        e.faster(); XCTAssertEqual(e.wpm, 350)
        for _ in 0..<20 { e.faster() }; XCTAssertEqual(e.wpm, 700)
        for _ in 0..<20 { e.slower() }; XCTAssertEqual(e.wpm, 150)
    }

    func testEmptyText() {
        let e = engine("")
        e.play()
        XCTAssertFalse(e.isPlaying)
        XCTAssertNil(e.current)
        XCTAssertFalse(e.advance())
    }
}

final class SpeedReaderViewTests: XCTestCase {
    /// The point of the method: every word's focus letter is centered on the same x.
    func testFocusLetterLandsOnTheAnchor() {
        let anchor: CGFloat = 150
        let attrs: [NSAttributedString.Key: Any] = [.font: SpeedReaderView.font]
        func width(_ s: String) -> CGFloat { (s as NSString).size(withAttributes: attrs).width }
        for word in ["a", "read", "reading", "comprehension", "\"quoted\"", "internationalization"] {
            let f = RSVP.focusIndex(word)
            let x = SpeedReaderView.origin(of: word, focus: f, anchorX: anchor, width: 500)
            let center = x + width(String(word.prefix(f))) + width(String(Array(word)[f])) / 2
            XCTAssertEqual(center, anchor, accuracy: 0.01, word)
        }
    }

    func testChipIsCentered() {
        let x = SpeedReaderView.origin(of: "‹code›", focus: nil, anchorX: 50, width: 400)
        let w = ("‹code›" as NSString).size(withAttributes: [.font: SpeedReaderView.font]).width
        XCTAssertEqual(x, (400 - w) / 2, accuracy: 0.01)
    }

    func testSpeedChangesAreRemembered() {
        let saved = Settings.readingWPM
        defer { Settings.readingWPM = saved }
        Settings.readingWPM = 300
        let v = SpeedReaderView(text: "a b c", wpm: Settings.readingWPM)
        v.faster(); v.faster()
        XCTAssertEqual(Settings.readingWPM, 400)
        v.slower()
        XCTAssertEqual(Settings.readingWPM, 350)
    }

    func testTogglePlayPause() {
        let v = SpeedReaderView(text: "one two three", wpm: 300)
        var states: [Bool] = []
        v.onStateChange = { states.append($0) }
        v.toggle(); v.toggle()
        XCTAssertEqual(states, [true, false])
        XCTAssertFalse(v.isPlaying)
    }
}
