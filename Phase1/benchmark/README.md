# CMPB benchmark workflows

Run these workflows from `fastPLS-extra/Phase1`. Prepared matrices and generated
evidence are not committed. Load the root configuration first:

```sh
set -a
. ../config/benchmark.env
set +a
```

The fixed dataset sources and preprocessing contracts are documented in
[`DATA_ACQUISITION.md`](DATA_ACQUISITION.md). The high-level mapping from
manuscript items to code is in [`../MANIFEST.csv`](../MANIFEST.csv).

## Main figures

- **Figure 1:** `current_release_evidence/`,
  `benchmark_pls_package_comparison.R`, and `ikpls_cross_language/` run the
  independent-software comparison. `../tools/build_figure1_six_panel.R`
  assembles the figure.
- **Figure 2A-B:** `current_release_evidence/run_selected_backends.py` and
  `current_release_evidence/build_figure2_float32.R` generate the matched
  Linux CPU/CUDA comparison.
- **Figure 2C-D:** `gpu_cross_validation/` runs and audits the matched ten-fold
  LDA cross-validation comparison. The selected component contract is stored
  in that directory.
- **Figure 3:** `benchmark_nmr_component_selection.R`,
  `benchmark_nmr_qualified_solver.R`, `benchmark_nmr_deposited_reference.R`,
  and `nmr_protocol_helpers.R` define the NMR analysis.
- **Figure 4:** `benchmark_imagenet_current_fused_lda.R`,
  `run_imagenet_four_family_paths.sh`, and `plot_imagenet_current.R` generate
  the four-family source table and the three-panel SIMPLS accuracy, runtime,
  and memory figure used in the main manuscript.

## Supplementary analyses

- `benchmark_simpls_exact_reference.R`,
  `benchmark_simpls_estimator_preservation.R`, and `controlled_scaling/`
  provide numerical and rSVD qualification.
- `benchmark_simpls_multidataset_ablation.R` isolates the execution changes.
- `benchmark_opls_kernel_estimator_validation.R`,
  `benchmark_opls_kernel_setting_reliability.R`, and
  `benchmark_kernel_sensitivity.R` validate OPLS and kernel PLS.
- `run_current_component_selection.R`, `run_current_component_path.R`, and
  `supplement_component_paths/` produce training-only selections and held-out
  component paths.
- `benchmark_float32_backend_agreement.R` records the precision and backend
  agreement results retained in the CMPB supplement.

Multicore scaling, Metal implementation studies, complete capability matrices,
cross-language parity, and lower-level BLAS/kernel experiments belong to
[`../../Phase2`](../../Phase2/) and are not duplicated here.

Every runner must write outside the repository and record package source,
version, dataset fingerprint, split, component count, precision, backend, rSVD
controls, seed, output contract, and timing boundary.
