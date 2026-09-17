import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from companion_tools import companion_tool


class CompanionToolsTest(unittest.TestCase):
    def test_explicit_checkout(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "tools").mkdir()
            tool = root / "tools/run_candidate_tests.R"
            tool.write_text("# fixture, never executed\n")
            with patch.dict(os.environ, {"FASTPLS_EXTRA_ROOT": str(root)}):
                self.assertEqual(companion_tool(tool.name), tool.resolve())

    def test_missing_checkout_is_informative(self):
        with tempfile.TemporaryDirectory() as tmp:
            with patch.dict(os.environ, {"FASTPLS_EXTRA_ROOT": tmp}):
                with self.assertRaisesRegex(FileNotFoundError, "FASTPLS_EXTRA_ROOT"):
                    companion_tool("run_candidate_tests.R")

    def test_reject_path_traversal(self):
        for name in ("../outside.R", "/absolute.R", "tools/relative.R"):
            with self.assertRaises(ValueError):
                companion_tool(name)


if __name__ == "__main__":
    unittest.main()
