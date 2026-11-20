import XCTest
@testable import SpeakCore

final class HotkeyMachineTests: XCTestCase {
    func testHoldIsPushToTalk() {
        var m = HotkeyMachine()
        XCTAssertEqual(m.keyDown(at: 0), [.start])
        XCTAssertEqual(m.keyUp(at: 1.0), [.commit])
        XCTAssertEqual(m.state, .idle)
    }

    func testSingleShortTapIsDiscarded() {
        var m = HotkeyMachine()
        _ = m.keyDown(at: 0)
        XCTAssertEqual(m.keyUp(at: 0.1), [.scheduleTapTimeout(m.doubleTapWindow)])
        XCTAssertEqual(m.tapTimeout(), [.cancel])
        XCTAssertEqual(m.state, .idle)
    }

    func testDoubleTapLocksHandsFreeThenTapCommits() {
        var m = HotkeyMachine()
        _ = m.keyDown(at: 0)
        _ = m.keyUp(at: 0.1)
        XCTAssertEqual(m.keyDown(at: 0.2), [])
        XCTAssertEqual(m.state, .handsFree)
        XCTAssertEqual(m.keyUp(at: 0.25), [])       // release of 2nd tap ignored
        XCTAssertEqual(m.tapTimeout(), [])           // stale timer ignored
        XCTAssertEqual(m.keyDown(at: 5), [.commit])
        XCTAssertEqual(m.keyUp(at: 5.1), [])
    }

    func testOtherKeyWhileHoldingCancels() {
        var m = HotkeyMachine()
        _ = m.keyDown(at: 0)
        XCTAssertEqual(m.otherKeyDown(), [.cancel])
        XCTAssertEqual(m.keyUp(at: 1), [])
    }

    func testOtherKeyInHandsFreeDoesNotCancel() {
        var m = HotkeyMachine()
        _ = m.keyDown(at: 0); _ = m.keyUp(at: 0.1); _ = m.keyDown(at: 0.2)
        XCTAssertEqual(m.otherKeyDown(), [])
        XCTAssertEqual(m.escape(), [.cancel])
    }
}

final class TextCleanerTests: XCTestCase {
    let c = TextCleaner()

    func testFillers() {
        XCTAssertEqual(c.clean("Um, so I think, uh, we should ship it."), "So I think, we should ship it.")
        XCTAssertEqual(c.clean("The umbrella is here."), "The umbrella is here.")
        XCTAssertEqual(c.clean("Hmm. Okay."), "Okay.")
    }

    func testScratchThat() {
        XCTAssertEqual(c.clean("Send it Monday. Actually Tuesday, scratch that. Send it Friday."),
                       "Send it Monday. Send it Friday.")
        XCTAssertEqual(c.clean("Hello world scratch that"), "")
    }

    func testLineCommands() {
        XCTAssertEqual(c.clean("Dear Sam, new line. Thanks for the update. New paragraph. Best, Colin."),
                       "Dear Sam,\nThanks for the update.\n\nBest, Colin.")
    }

    func testReplacements() {
        var o = TextCleaner.Options()
        o.replacements = ["gemini sound": "GEMNIsound", "g w one": "GW-1"]
        let c = TextCleaner(options: o)
        XCTAssertEqual(c.clean("Open the Gemini Sound folder and load G W one."), "Open the GEMNIsound folder and load GW-1.")
        XCTAssertEqual(c.clean("geminisounds"), "Geminisounds")
    }

    func testReplacementTemplateIsLiteral() {
        var o = TextCleaner.Options()
        o.replacements = ["price": "$5"]
        XCTAssertEqual(TextCleaner(options: o).clean("The price is fine."), "The $5 is fine.")
    }

    func testSmartJoin() {
        XCTAssertEqual(SmartJoin.adapt("Hello there.", after: nil), "Hello there.")
        XCTAssertEqual(SmartJoin.adapt("Hello there.", after: "Done."), " Hello there.")
        XCTAssertEqual(SmartJoin.adapt("And then we left.", after: "We ate dinner"), " and then we left.")
        XCTAssertEqual(SmartJoin.adapt("I agree.", after: "Honestly,"), " I agree.")
        XCTAssertEqual(SmartJoin.adapt("NASA called.", after: "then"), " NASA called.")
        XCTAssertEqual(SmartJoin.adapt("Next.", after: "Done.\n"), "Next.")
        XCTAssertEqual(SmartJoin.adapt("Next.", after: "Done. "), "Next.")
        XCTAssertEqual(SmartJoin.adapt("more words", after: "some "), "more words")
        XCTAssertEqual(SmartJoin.adapt("Quote", after: "(" ), "Quote")
    }
}
