import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "publication_preservation",
    Path(__file__).resolve().parents[1] / "tools/preserve_publication_material.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class PreservationTests(unittest.TestCase):
    def test_scope_and_byte_preservation(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "source"
            files = {
                "benchmark/run.R": "stop('not executed')\n",
                "benchmark/__pycache__/cache.py": "exclude",
                "publication_results/summary.csv": "time\n1\n",
                "publication_results/private.rds": "exclude",
                "publication_results/untracked.csv": "exclude",
            }
            for name, value in files.items():
                path = source / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(value)
            out = Path(tmp) / "archive"
            with patch.object(module.subprocess, "check_output", side_effect=[
                "publication_results/summary.csv\0publication_results/private.rds\0",
                "base-commit\n",
            ]):
                module.preserve(source, out)
            report = json.loads((out / "manifest.json").read_text())
            self.assertEqual({r["path"] for r in report["files"]},
                             {"benchmark/run.R", "publication_results/summary.csv"})
            for row in report["files"]:
                self.assertEqual((out / "files" / row["path"]).read_bytes(),
                                 (source / row["path"]).read_bytes())
            self.assertEqual(report["base_commit"], "base-commit")

    def test_reject_nested_destination(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp)
            with self.assertRaises(ValueError):
                module.preserve(source, source / "nested")

    def test_reject_symlink(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp)
            (source / "benchmark").mkdir()
            (source / "target.R").write_text("not executed")
            (source / "benchmark/run.R").symlink_to(source / "target.R")
            with patch.object(module.subprocess, "check_output", return_value=""):
                with self.assertRaises(ValueError):
                    module.select_files(source)


if __name__ == "__main__":
    unittest.main()
