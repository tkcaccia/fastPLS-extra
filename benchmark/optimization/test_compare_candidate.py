import unittest

from compare_candidate import join


class CandidateComparisonTest(unittest.TestCase):
    def compare(self, candidate, frozen, **kwargs):
        return join(candidate, frozen, ("dataset", "precision"),
                    ("accuracy",), ("seconds",), "test", **kwargs)

    def test_missing_precision_is_not_silently_matched(self):
        with self.assertRaisesRegex(ValueError, "precision"):
            self.compare([{"dataset": "x"}], [{"dataset": "x", "precision": "float32"}])

    def test_ambiguous_saved_rows_are_retained_without_ratio(self):
        row = {"dataset": "x", "precision": "float64", "seconds": "2"}
        result = self.compare([row], [row, row])[0]
        self.assertEqual(result["match_status"], "ambiguous_frozen_rows")
        self.assertNotIn("frozen_over_candidate_seconds", result)

    def test_cross_host_times_are_not_speedups(self):
        row = {"dataset": "x", "precision": "float64", "seconds": "2", "accuracy": ".9"}
        result = self.compare([row], [dict(row, seconds="4")], time_comparable=False)[0]
        self.assertEqual(result["difference_accuracy"], 0)
        self.assertIsNone(result["frozen_over_candidate_seconds"])
        self.assertEqual(result["frozen_seconds"], 4)

    def test_failure_is_not_a_speedup(self):
        row = {"dataset": "x", "precision": "float64", "seconds": "2", "accuracy": ".9"}
        result = self.compare([dict(row, status="error")], [row])[0]
        self.assertNotIn("frozen_over_candidate_seconds", result)
        self.assertEqual(result["candidate_status"], "error")

    def test_changed_scoring_contract_keeps_values_but_not_differences(self):
        row = {"dataset": "x", "precision": "float64", "seconds": "2", "accuracy": ".9"}
        result = self.compare([row], [dict(row, accuracy=".8")],
                              metric_comparable=False, time_comparable=False)[0]
        self.assertFalse(result["metric_comparable"])
        self.assertEqual(result["candidate_accuracy"], .9)
        self.assertEqual(result["frozen_accuracy"], .8)
        self.assertNotIn("difference_accuracy", result)
        self.assertIsNone(result["frozen_over_candidate_seconds"])


if __name__ == "__main__":
    unittest.main()
