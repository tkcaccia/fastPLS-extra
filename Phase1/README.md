# Phase 1 CMPB analyses

This directory contains the reproducible analysis for the fastPLS biomedical
methods manuscript submitted to *Computer Methods and Programs in
Biomedicine* and its Supplementary Material. It contains analysis source only;
generated evidence must be written to `FASTPLS_RESULTS_ROOT` outside the Git
checkout.

## Main manuscript evidence

| Manuscript item | Principal analysis source |
|---|---|
| Table 1 and dataset descriptions | `benchmark/DATA_ACQUISITION.md`, `benchmark/acquire_publication_datasets.R` |
| Figure 1, independent implementations | `benchmark/current_release_evidence/`, `benchmark/benchmark_pls_package_comparison.R`, `benchmark/ikpls_cross_language/`, `tools/build_figure1_six_panel.R` |
| Figure 2A-B, CPU/CUDA execution | `benchmark/current_release_evidence/run_selected_backends.py`, `benchmark/current_release_evidence/build_figure2_float32.R` |
| Figure 2C-D, ten-fold cross-validation | `benchmark/gpu_cross_validation/`, `benchmark/current_release_evidence/build_figure2_with_cv.R` |
| Figure 3, NMR prediction | `benchmark/benchmark_nmr_component_selection.R`, `benchmark/benchmark_nmr_qualified_solver.R`, `benchmark/benchmark_nmr_deposited_reference.R`, `tools/build_nmr_figure3_family_components.R` |
| Figure 4, ImageNet/DINOv2 SIMPLS accuracy, runtime and memory | `benchmark/benchmark_imagenet_current_fused_lda.R`, `benchmark/run_imagenet_four_family_paths.sh`, `benchmark/plot_imagenet_current.R` |

## Supplementary evidence

- `benchmark/benchmark_simpls_exact_reference.R`,
  `benchmark/benchmark_simpls_estimator_preservation.R`, and
  `benchmark/controlled_scaling/` provide numerical-reference and rSVD
  qualification evidence.
- `benchmark/benchmark_simpls_multidataset_ablation.R` and its summarizers
  quantify the execution changes used by the SIMPLS-family implementation.
- `benchmark/benchmark_opls_kernel_estimator_validation.R`,
  `benchmark/benchmark_opls_kernel_setting_reliability.R`, and
  `benchmark/benchmark_kernel_sensitivity.R` support OPLS and kernel-PLS
  validation.
- `benchmark/run_current_component_selection.R`,
  `benchmark/run_current_component_path.R`, and
  `benchmark/supplement_component_paths/` generate the component-selection and
  held-out prediction paths.
- `benchmark/benchmark_float32_backend_agreement.R` records the precision and
  backend agreement results reported in the CMPB supplement.
- `benchmark/analyze_nmr_localized_error.R` generates the response-wise and
  observed-intensity-stratified NMR error summaries and Supplementary Figure
  S14 from the fixed held-out prediction objects.
- `formal/lean/` contains the pinned Lean project for the algebraic invariants
  reported in the supplementary formal-verification section.

Selected software-platform studies that are primarily discussed in the future
JSS article are canonical under `../Phase2`. CMPB figure builders may consume
their frozen result tables, but Phase 1 does not duplicate those runners.

See [`MANIFEST.csv`](MANIFEST.csv) for the figure/table-to-code mapping and
[`benchmark/README.md`](benchmark/README.md) for execution details.
