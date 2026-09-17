import importlib.util
from pathlib import Path
import tempfile
import unittest


TOOL = Path(__file__).parents[1] / "tools" / "audit_distribution.py"
SPEC = importlib.util.spec_from_file_location("audit_distribution", TOOL)
audit = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(audit)


class AuditTest(unittest.TestCase):
    def inspect(self, name, text):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
            return audit.inspect_file(root, name, True)

    def test_no_notice_does_not_mean_mit(self):
        row = self.inspect("src/model.cpp", "int f() { return 1; }\n")
        self.assertEqual(row["decision"], "ownership_review_pending")
        self.assertEqual(row["license_evidence"], [])

    def test_claimed_mit_does_not_confirm_permissions(self):
        row = self.inspect("src/model.cpp", "// SPDX-License-Identifier: MIT\n")
        self.assertEqual(row["spdx_headers"], ["MIT"])
        self.assertEqual(row["decision"], "ownership_review_pending")

    def test_irlba_and_matrix_are_explicit(self):
        row = self.inspect("src/irlba.c", '#include <Matrix_stubs.c>\n')
        self.assertEqual(row["decision"], "gpl_companion")
        self.assertIn("matrix_c_interface_dependency", row["findings"])

    def test_embedded_recovery_is_not_missed(self):
        row = self.inspect("src/model.cpp", "auto x = irlba_float32_operator(A);\n")
        self.assertIn("contains_irlba_interface_or_implementation", row["findings"])

    def test_r_adapter_is_not_standalone(self):
        row = self.inspect("src/model.cpp", '#include <RcppArmadillo.h>\n')
        self.assertIn("r_interface_dependency_not_standalone_core", row["findings"])

    def test_description_continuations(self):
        fields = audit.package_fields("Imports: Rcpp,\n    float\nLicense: GPL-3\n")
        self.assertEqual(fields["Imports"], "Rcpp, float")

    def test_symlink_not_followed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "external").symlink_to("/nonexistent")
            row = audit.inspect_file(root, "external", False)
            self.assertEqual(row["decision"], "symlink_requires_review")


if __name__ == "__main__":
    unittest.main()
