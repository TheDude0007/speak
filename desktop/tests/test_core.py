"""Same cases as Tests/SpeakCoreTests (Swift) so the platforms can't drift apart."""
import unittest

from speak.core import CleanerOptions, HotkeyMachine, TextCleaner


class HotkeyTests(unittest.TestCase):
    def test_hold(self):
        m = HotkeyMachine()
        self.assertEqual(m.key_down(0), ["start"])
        self.assertEqual(m.key_up(1.0), ["commit"])

    def test_single_tap_discarded(self):
        m = HotkeyMachine()
        m.key_down(0)
        self.assertEqual(m.key_up(0.1), [("schedule", m.double_tap_window)])
        self.assertEqual(m.tap_timeout(), ["cancel"])

    def test_double_tap_hands_free(self):
        m = HotkeyMachine()
        m.key_down(0); m.key_up(0.1)
        self.assertEqual(m.key_down(0.2), [])
        self.assertEqual(m.state, m.HANDS_FREE)
        self.assertEqual(m.key_up(0.25), [])
        self.assertEqual(m.tap_timeout(), [])
        self.assertEqual(m.key_down(5), ["commit"])

    def test_chord_cancels(self):
        m = HotkeyMachine()
        m.key_down(0)
        self.assertEqual(m.other_key(), ["cancel"])

    def test_toggle(self):
        m = HotkeyMachine()
        self.assertEqual(m.toggle(), ["start"])
        self.assertEqual(m.other_key(), [])
        self.assertEqual(m.toggle(), ["commit"])


class CleanerTests(unittest.TestCase):
    c = TextCleaner()

    def test_fillers(self):
        self.assertEqual(self.c.clean("Um, so I think, uh, we should ship it."), "So I think, we should ship it.")
        self.assertEqual(self.c.clean("The umbrella is here."), "The umbrella is here.")
        self.assertEqual(self.c.clean("Hmm. Okay."), "Okay.")

    def test_scratch_that(self):
        self.assertEqual(self.c.clean("Send it Monday. Actually Tuesday, scratch that. Send it Friday."),
                         "Send it Monday. Send it Friday.")
        self.assertEqual(self.c.clean("Hello world scratch that"), "")

    def test_line_commands(self):
        self.assertEqual(self.c.clean("Dear Sam, new line. Thanks for the update. New paragraph. Best, Colin."),
                         "Dear Sam,\nThanks for the update.\n\nBest, Colin.")

    def test_replacements(self):
        c = TextCleaner(CleanerOptions(replacements={"gemini sound": "GEMNIsound", "g w one": "GW-1"}))
        self.assertEqual(c.clean("Open the Gemini Sound folder and load G W one."),
                         "Open the GEMNIsound folder and load GW-1.")
        self.assertEqual(c.clean("geminisounds"), "Geminisounds")
        self.assertEqual(TextCleaner(CleanerOptions(replacements={"price": "$5"})).clean("The price is fine."),
                         "The $5 is fine.")


if __name__ == "__main__":
    unittest.main()
