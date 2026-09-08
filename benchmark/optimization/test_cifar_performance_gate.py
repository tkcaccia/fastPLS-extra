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
        "r_version": "4.6.0",
        "r_platform": "x86_64-pc-linux-gnu",
        "r_blas": "/test/libblas.so",
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

    def test_environment_change_is_rejected(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            baseline = root / "baseline.csv"
            candidate = root / "candidate.csv"
            write_csv(baseline, [benchmark_row(host="host-a")])
            write_csv(candidate, [benchmark_row(host="host-b")])
            result = self.run_gate(candidate, baseline)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("environment field host changed", result.stderr)


if __name__ == "__main__":
    unittest.main()
