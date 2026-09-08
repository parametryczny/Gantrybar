import unittest
from gantry.startup import StartupState


class StartupTests(unittest.TestCase):
    def test_sixty_percent_is_rounded_up_and_reports_are_unique(self):
        for total in range(1, 11):
            state = StartupState([str(i) for i in range(total)], clock=lambda: 0)
            threshold = (total * 3 + 4) // 5
            for index in range(threshold):
                self.assertTrue(state.loading)
                state.report(str(index)); state.report(str(index))
            self.assertFalse(state.loading)
            self.assertEqual(state.ready, threshold)

    def test_timeout_does_not_fabricate_cards(self):
        now = [0]
        state = StartupState(["a", "b"], clock=lambda: now[0])
        state.report("a")
        now[0] = 15
        self.assertFalse(state.loading)
        self.assertEqual(state.received, {"a"})
        state.report("b")
        self.assertEqual(state.received, {"a", "b"})

    def test_empty_fleet_skip_and_removal_never_restart_gate(self):
        self.assertFalse(StartupState([], clock=lambda: 0).loading)
        state = StartupState(["a", "b"], clock=lambda: 0)
        state.finish(); state.report("a"); state.remove("a")
        self.assertFalse(state.loading)
        self.assertEqual(state.received, set())

    def test_guide_is_once_and_persistent_seen_wins(self):
        state = StartupState([])
        self.assertFalse(state.claim_guide(True))
        self.assertTrue(state.claim_guide(False))
        self.assertFalse(state.claim_guide(False))

    def test_new_printer_does_not_count_toward_initial_threshold(self):
        state = StartupState(["a", "b"], clock=lambda: 0)
        state.report("new")
        self.assertTrue(state.loading)
        self.assertEqual(state.ready, 0)
        self.assertIn("new", state.received)
