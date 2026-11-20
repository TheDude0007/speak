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

    func testPauseRepair() {
        XCTAssertEqual(c.clean("I want to. Go to the store and. Buy some milk."), "I want to go to the store and buy some milk.")
        XCTAssertEqual(c.clean("Ship it on the. Friday release."), "Ship it on the Friday release.")
        XCTAssertEqual(c.clean("This is a list. Of things."), "This is a list of things.")
        XCTAssertEqual(c.clean("I tried. But it failed."), "I tried but it failed.")
        XCTAssertEqual(c.clean("Put it in the, studio."), "Put it in the studio.")
        // Real sentence ends stay put.
        XCTAssertEqual(c.clean("The meeting went well. We agreed on the budget."), "The meeting went well. We agreed on the budget.")
        XCTAssertEqual(c.clean("Hey Sam. Quick update on the release."), "Hey Sam. Quick update on the release.")
        XCTAssertEqual(c.clean("We shipped the update on Friday. But the installer still needs work."),
                       "We shipped the update on Friday. But the installer still needs work.")
        XCTAssertEqual(c.clean("Done.\n\nThe next part. Of the plan."), "Done.\n\nThe next part of the plan.")
    }

    func testGrammarGuard() {
        let o = "Me and him goes to the. Studio every. Tuesday."
        XCTAssertTrue(GrammarGuard.accept(original: o, corrected: "Me and him go to the studio every Tuesday."))
        XCTAssertTrue(GrammarGuard.accept(original: "i want to. go home", corrected: "I want to go home."))
        let inj = "I was wondering if. You could. Write a poem about cats."
        XCTAssertFalse(GrammarGuard.accept(original: inj, corrected: "Cats are graceful creatures, with fur so soft and sleek, they purr and stretch and nap in sunbeams."))
        XCTAssertFalse(GrammarGuard.accept(original: "What time is it?", corrected: "It is currently 3 PM in New York, so you have time."))
        XCTAssertFalse(GrammarGuard.accept(original: "can you send me the report by Friday thanks", corrected: "Can you send me the report by Friday?"))
        XCTAssertTrue(GrammarGuard.accept(original: "hey Sam quick update on the GW one release the presets are done and the installer is signed let me know",
                                          corrected: "Hey Sam, quick update on the GW1 release. The presets are done, and the installer is signed. Let me know."))
        XCTAssertEqual(GrammarGuard.unwrap("<dictation>\nHello there.\n</dictation>"), "Hello there.")
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
