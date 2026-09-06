import csv
from pathlib import Path
import tempfile
import unittest

from run_nmr_selected_endpoints import read_selection


class NmrSelectionTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.decision = dict(selected_ncomp=50, minimum_mean_ncomp=75,
                             one_se_threshold=0.12, eligible_ncomp="50,75",
                             n_splits_requested=5, n_splits_successful=5)
        self.summary = [dict(ncomp=k, n_success=5, RMSD_mean=mean, RMSD_se=0.02)
                        for k, mean in ((5, 0.4), (50, 0.11), (75, 0.10), (165, 0.3))]

    def write(self):
        for name, rows in (("decision", [self.decision]), ("summary", self.summary)):
            with (self.root / f"nmr_component_selection_{name}.csv").open("w") as handle:
                writer = csv.DictWriter(handle, fieldnames=rows[0].keys())
                writer.writeheader()
                writer.writerows(rows)

    def test_uses_smallest_one_se_eligible_not_minimum_or_old_fixed_count(self):
        self.write()
        result = read_selection(self.root)
        self.assertEqual(result["selected_ncomp"], 50)
        self.assertEqual(result["eligible"], [50, 75])

    def test_rejects_partial_training_selection(self):
        self.decision["n_splits_successful"] = 4
        self.write()
        with self.assertRaisesRegex(ValueError, "every training split"):
            read_selection(self.root)

    def test_rejects_stale_decision(self):
        self.decision["selected_ncomp"] = 5
        self.write()
        with self.assertRaisesRegex(ValueError, "disagrees"):
            read_selection(self.root)

    def test_rejects_nonfinite_or_missing_prefix(self):
        self.summary[1]["RMSD_mean"] = "NaN"
        self.write()
        with self.assertRaisesRegex(ValueError, "nonfinite"):
            read_selection(self.root)
        self.summary[1]["RMSD_mean"] = 0.11
        self.summary[1]["n_success"] = 4
        self.write()
        with self.assertRaisesRegex(ValueError, "Incomplete"):
            read_selection(self.root)


if __name__ == "__main__":
    unittest.main()
