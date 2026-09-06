import unittest

from compare_replays import aggregate_folds, compare


class ReplayComparisonTest(unittest.TestCase):
    def test_fold_aggregation_matches_unweighted_complete_folds_only(self):
        rows = [{"dataset": "x", "fold": str(i), "candidate_metric": str(i),
                 "status": "success"} for i in range(1, 6)]
        self.assertEqual(aggregate_folds(rows, ("dataset",))[0]["candidate_cv_metric"], 3)
        for invalid in (rows[:-1], rows + rows[:1],
                        rows[:-1] + [dict(rows[-1], status="error")],
                        rows[:-1] + [dict(rows[-1], candidate_metric="NA")]):
            result = aggregate_folds(invalid, ("dataset",))[0]
            self.assertEqual(result["status"], "error")
            self.assertIsNone(result["candidate_cv_metric"])

    def test_audit_failure_is_retained_and_not_hidden(self):
        current = [{"dataset": "x", "metric": ".8", "status": "success"}]
        old = [{"dataset": "x", "fast": ".7", "reference": ".9", "status": "failed_approximation_criteria"}]
        row = compare(current, old, ("dataset",), "metric", "fast", "reference")[0]
        self.assertAlmostEqual(row["candidate_minus_frozen"], .1)
        self.assertAlmostEqual(row["candidate_minus_stored_external"], -.1)
        self.assertEqual(row["frozen_status"], "failed_approximation_criteria")
        self.assertEqual(row["reference_execution"], "none")

    def test_missing_and_duplicate_rows_do_not_produce_differences(self):
        current = [{"dataset": "x", "metric": ".8"}]
        old = [{"dataset": "x", "fast": ".7"}]
        row = compare(current, old * 2, ("dataset",), "metric", "fast")[0]
        self.assertIsNone(row["candidate_minus_frozen"])
        self.assertEqual(row["match_status"], "ambiguous_stored_rows")
        row = compare(current, [], ("dataset",), "metric", "fast")[0]
        self.assertEqual(row["match_status"], "missing_stored_row")


if __name__ == "__main__":
    unittest.main()
