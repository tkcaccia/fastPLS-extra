import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location(
    "blas_bindings", Path(__file__).parents[1] / "multicore_scaling/verify_blas_bindings.py"
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class BlasBindingsTest(unittest.TestCase):
    def bindings(self, provider):
        return "\n".join(
            f"123: binding file /lib/fastPLS.so [0] to {provider} [0]: normal symbol `{s}'"
            for s in ("dgemm_", "dgemv_", "dsyrk_")
        )

    def test_actual_openblas_bindings(self):
        self.assertEqual(len(module.verify(self.bindings("/lib/libopenblas.so.0"))), 3)

    def test_linked_but_not_used_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "not using OpenBLAS"):
            module.verify(self.bindings("/lib/libblas.so.3"))

    def test_unrelated_library_does_not_count(self):
        with self.assertRaisesRegex(ValueError, "Missing actual"):
            module.verify(self.bindings("/lib/libopenblas.so.0").replace("fastPLS.so", "R.so"))


if __name__ == "__main__":
    unittest.main()
