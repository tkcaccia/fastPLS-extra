import csv
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("check_cifar_performance_gate.py")


def benchmark_row(host="test-host", total="1.0"):
    return {
        "dataset": "cifar100",
        "backend": "cpu",
        "precision": "float32",
        "protocol_id": "cifar100_public_simpls_rsvd_v1",
        "source_commit": "abc123",
        "host": host,
        "os": "Linux",
        "machine": "x86_64",
        "cpu_model": "Test CPU",
        "physical_memory_bytes": "34359738368",
        "r_version": "4.6.0",
        "r_platform": "x86_64-pc-linux-gnu",
        "r_blas": "/test/libblas.so",
        "fastpls_cpu_backend": "OpenBLAS: test configuration",
        "ncomp": "50",
        "oversample": "32",
        "power": "5",
        "seed": "123",
        "execution_route": "compiled CPU",
        "algorithm_variant": "block_randomized_simpls",
        "refresh_block": "50",
        "effective_oversample": "32",
        "effective_power": "5",
        "accuracy": "0.7087",
        "prediction_checksum": "3118083306",
        "fit_sec": "0.8",
        "prediction_sec": "0.2",
        "total_sec": total,
    }


def write_csv(path, rows):
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=rows[0].keys())
        writer.writeheader()
        writer.writerows(rows)


class CifarPerformanceGateTest(unittest.TestCase):
    def run_gate(self, candidate, baseline):
        return subprocess.run(
            [
                "python3",
                str(SCRIPT),
                "--candidate",
                str(candidate),
                "--baseline",
                str(baseline),
            ],
            capture_output=True,
            text=True,
            check=False,
        )

    def test_directory_ignores_generated_summary_files(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            baseline = root / "baseline"
            candidate = root / "candidate"
            baseline.mkdir()
            candidate.mkdir()
            row = benchmark_row()
            write_csv(baseline / "cpu_r1.csv", [row])
            write_csv(candidate / "cpu_r1.csv", [row])
            write_csv(candidate / "summary.csv", [{"backend": "cpu"}])
            result = self.run_gate(candidate, baseline)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("PASS: matched CIFAR-100 gate", result.stdout)

    def test_hostname_change_is_allowed(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            baseline = root / "baseline.csv"
            candidate = root / "candidate.csv"
            write_csv(baseline, [benchmark_row(host="host-a")])
            write_csv(candidate, [benchmark_row(host="host-b")])
            result = self.run_gate(candidate, baseline)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_cpu_model_change_is_rejected(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            baseline = root / "baseline.csv"
            candidate = root / "candidate.csv"
            baseline_row = benchmark_row()
            candidate_row = benchmark_row()
            candidate_row["cpu_model"] = "Different CPU"
            write_csv(baseline, [baseline_row])
            write_csv(candidate, [candidate_row])
            result = self.run_gate(candidate, baseline)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("environment field cpu_model changed", result.stderr)

    def test_native_cpu_backend_change_is_rejected(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            baseline = root / "baseline.csv"
            candidate = root / "candidate.csv"
            baseline_row = benchmark_row()
            candidate_row = benchmark_row()
            candidate_row["fastpls_cpu_backend"] = "R BLAS"
            write_csv(baseline, [baseline_row])
            write_csv(candidate, [candidate_row])
            result = self.run_gate(candidate, baseline)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(
                "environment field fastpls_cpu_backend changed", result.stderr
            )

    def test_multiple_backends_are_checked_independently(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            baseline = root / "baseline.csv"
            candidate = root / "candidate.csv"
            cpu = benchmark_row()
            cuda = benchmark_row()
            cuda["backend"] = "cuda"
            cuda["execution_route"] = "resident cuda"
            write_csv(baseline, [cpu, cuda])
            write_csv(candidate, [cpu, cuda])
            result = self.run_gate(candidate, baseline)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.count("PASS: matched CIFAR-100 gate"), 2)

    def test_backend_set_change_is_rejected(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            baseline = root / "baseline.csv"
            candidate = root / "candidate.csv"
            cpu = benchmark_row()
            cuda = benchmark_row()
            cuda["backend"] = "cuda"
            cuda["execution_route"] = "resident cuda"
            write_csv(baseline, [cpu, cuda])
            write_csv(candidate, [cpu])
            result = self.run_gate(candidate, baseline)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("backend set changed", result.stderr)

    def test_fit_regression_cannot_hide_inside_total_time(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            baseline = root / "baseline.csv"
            candidate = root / "candidate.csv"
            baseline_row = benchmark_row(total="1.0")
            candidate_row = benchmark_row(total="1.0")
            candidate_row["fit_sec"] = "0.9"
            candidate_row["prediction_sec"] = "0.1"
            write_csv(baseline, [baseline_row])
            write_csv(candidate, [candidate_row])
            result = self.run_gate(candidate, baseline)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("median fit_sec regressed", result.stderr)


if __name__ == "__main__":
    unittest.main()
