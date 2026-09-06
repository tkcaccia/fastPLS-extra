import tempfile
import unittest
from pathlib import Path

from supplement_stages import build_supplement_stages


class SupplementStagesTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.kwargs = dict(source=self.root / "source", library=self.root / "library",
                           results=self.root / "results", tasks=self.root / "tasks",
                           accelerator="cuda", baseline=self.root / "baseline")

    def test_missing_inputs_are_explicit_not_silently_complete(self):
        stages, pending = build_supplement_stages(**self.kwargs)
        self.assertEqual([stage["name"] for stage in stages],
                         ["simpls_exact_reference", "controlled_scaling", "matched_shapes", "simpls_ablation"])
        self.assertIn("multicore_scaling", {item["panel"] for item in pending})
        self.assertIn("external_numerical_references", {item["panel"] for item in pending})
        self.assertEqual(stages[1]["environment"]["FASTPLS_SCALING_SKIP_INSTALL"], "true")
        self.assertNotIn("worker_ikpls.py", str(stages))

    def test_cross_language_runs_only_candidate_fastpls(self):
        inputs = self.root / "inputs"
        for dataset in ("breast", "metref", "cifar100"):
            folder = inputs / dataset
            folder.mkdir(parents=True)
            (folder / "metadata.tsv").write_text("key\tvalue\n")
        stages, _ = build_supplement_stages(**self.kwargs, cross_language_inputs=inputs)
        stage = next(s for s in stages if s["name"] == "cross_language_fastpls_only")
        self.assertEqual(stage["environment"]["FASTPLS_IKPLS_IMPLEMENTATIONS"],
                         "fastPLS_irlba,fastPLS_rsvd")
        self.assertEqual(stage["environment"]["FASTPLS_IKPLS_INPUTS"], str(inputs))

    def test_repeated_partition_uses_saved_protocol_not_runner_defaults(self):
        path = self.kwargs["baseline"] / "repeated_outer/metref"
        path.mkdir(parents=True)
        data = self.root / "original.RData"
        data.touch()
        (path / "repeated_outer_manifest.txt").write_text(
            f"source: {data}\nbackend: cpu\nsvd_method: rsvd\n"
            "outer_train_fraction: 0.800\nouter_seeds: 101,211\n"
            "inner_kfold: 5\nmethods: simpls,opls\nclassifiers: argmax,lda\n"
            "inner_seed: 9101\nfit_seed: 123\n"
        )
        stages, _ = build_supplement_stages(**self.kwargs)
        stage = next(s for s in stages if s["name"] == "repeated_outer_metref")
        self.assertIn("--svd_method=rsvd", stage["command"])
        self.assertIn("--outer_seeds=101,211", stage["command"])
        self.assertIn("--inner_kfold=5", stage["command"])

    def test_float32_nmr_has_separate_timing_and_memory_runs(self):
        stages, _ = build_supplement_stages(**self.kwargs, nmr=self.root / "nmr.RData")
        nmr = [s for s in stages if s["name"].startswith("nmr_float32_")]
        self.assertEqual(len(nmr), 30)
        self.assertEqual(len({s["name"] for s in nmr}), 30)
        for stage in nmr:
            self.assertIn("--precision=float32", stage["command"])
            self.assertNotIn("--precision=float64", stage["command"])
            self.assertIn("--replicates=1" if stage["name"].endswith("_memory")
                          else "--replicates=3", stage["command"])
            self.assertNotIn("cuda_irlba", stage["name"])

    def test_frozen_multicore_library_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "frozen"):
            build_supplement_stages(**self.kwargs,
                                    openblas_library=self.root / "frozen_library",
                                    openblas_root=self.root / "openblas")


if __name__ == "__main__":
    unittest.main()
