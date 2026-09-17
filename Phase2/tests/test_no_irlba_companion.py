from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class NoIrlbaCompanionTests(unittest.TestCase):
    def test_obsolete_package_files_are_absent(self):
        obsolete = (
            "DESCRIPTION",
            "NAMESPACE",
            "R/interface.R",
            "R/RcppExports.R",
            "man/pls_irlba.Rd",
            "src/interface.cpp",
            "src/RcppExports.cpp",
            "src/irlba.c",
            "src/irlba.h",
            "src/irlba_workspace.h",
        )
        self.assertEqual([name for name in obsolete if (ROOT / name).exists()], [])

    def test_active_code_does_not_call_the_removed_companion(self):
        forbidden = (
            "fastPLSextra::",
            "library(fastPLSextra)",
            "requireNamespace(\"fastPLSextra\"",
            "pls_irlba(",
            "extra_pls_cpp",
            "extra_predict_cpp",
        )
        hits = []
        for folder in ("Phase1", "Phase2"):
            for path in (ROOT / folder).rglob("*"):
                if not path.is_file() or "__pycache__" in path.parts:
                    continue
                if ".lake" in path.parts or "tests" in path.parts:
                    continue
                try:
                    text = path.read_text()
                except UnicodeDecodeError:
                    continue
                for token in forbidden:
                    if token in text:
                        hits.append(f"{path.relative_to(ROOT)}: {token}")
        self.assertEqual(hits, [])

    def test_companion_build_products_are_absent(self):
        suffixes = {".o", ".so", ".dll", ".dylib"}
        products = [
            str(path.relative_to(ROOT))
            for path in ROOT.rglob("*")
            if path.is_file()
            and ".git" not in path.parts
            and ".lake" not in path.parts
            and path.suffix.lower() in suffixes
        ]
        products.extend(
            str(path.relative_to(ROOT))
            for path in ROOT.glob("fastPLSextra_*.tar.gz")
        )
        self.assertEqual(products, [])


if __name__ == "__main__":
    unittest.main()
