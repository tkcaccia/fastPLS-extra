import csv
from pathlib import Path
import tempfile
import unittest

from run_metal_nmr_workspace import verify_table


class NmrResultChecks(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / "results.csv"
        self.row = dict(replicate="1", status="success", backend="metal",
                        precision="float32", ncomp="50", protocol_version="nmr_matched_v2",
                        conversion_in_fit_time="FALSE", fit_time_sec="2", predict_time_sec="1",
                        total_time_sec="3", RMSD="0.001", Q2="-0.1")

    def write(self, rows):
        with self.path.open("w", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=list(self.row))
            writer.writeheader()
            writer.writerows(rows)

    def test_complete_result(self):
        self.write([self.row])
        self.assertEqual(verify_table(self.path, "float32", 50, 1), 1)

    def test_partial_and_duplicate_results(self):
        for rows in ([self.row], [self.row, self.row]):
            self.write(rows)
            with self.assertRaises(ValueError):
                verify_table(self.path, "float32", 50, 2)

    def test_invalid_protocol_or_metrics(self):
        for change in (dict(conversion_in_fit_time="TRUE"), dict(RMSD="nan"),
                       dict(backend="cpu"), dict(status="error"), dict(ncomp="165")):
            self.write([dict(self.row, **change)])
            with self.assertRaises(ValueError):
                verify_table(self.path, "float32", 50, 1)

    def test_cuda_cpu_and_solver_identity(self):
        for backend in ("cpu", "cuda"):
            self.row.update(backend=backend, family="simpls", solver="rsvd", seed="124")
            self.write([self.row])
            self.assertEqual(verify_table(self.path, "float32", 50, 1,
                backend, "simpls", "rsvd", 124), 1)
            with self.assertRaises(ValueError):
                verify_table(self.path, "float32", 50, 1, backend, "plssvd", "rsvd", 124)
            with self.assertRaises(ValueError):
                verify_table(self.path, "float32", 50, 1, backend, "simpls", "irlba", 124)
            with self.assertRaises(ValueError):
                verify_table(self.path, "float32", 50, 1, backend, "simpls", "rsvd", 123)

    def test_profile_run_is_not_timing_evidence(self):
        self.row["profiled"] = "TRUE"
        self.write([self.row])
        with self.assertRaises(ValueError):
            verify_table(self.path, "float32", 50, 1)
