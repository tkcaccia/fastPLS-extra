# fastPLS publication benchmarks

This directory contains only the workflows used by the current fastPLS
manuscript. Prepared real-data matrices are not committed. Dataset sources,
redistribution status, and acquisition commands are documented in
[`DATA_ACQUISITION.md`](DATA_ACQUISITION.md).

Before running a workflow, set `FASTPLS_SOURCE_ROOT`, `FASTPLS_DATA_ROOT`, and
`FASTPLS_RESULTS_ROOT` as shown in `../config/benchmark.env.example`. Generated
evidence must be written below `FASTPLS_RESULTS_ROOT`, which must be outside
both Git repositories.

All publication runs must use the package version stated in `DESCRIPTION` and
record effective model family, backend, precision, component count, scaling,
classification head, rSVD oversampling, power iterations, seed, timing scope,
and execution status. PLS-SVD and standalone `fastsvd()` use 32 oversampling
directions and five power iterations. Accelerated SIMPLS, OPLS, and kernel-PLS
use 32 directions and five iterations for ordinary shapes. For a massive
cross-covariance, the profile records `oversample = 12` and `power = 1`.
Component-wise routes use a newly initialized randomized direction at every
deflation step; the bounded CUDA float32 route can instead refresh an
independent candidate block before returning to component-wise calculations.
Results from older package
versions are not part of the publication evidence retained in this repository.

## Numerical validation

- `benchmark_simpls_exact_reference.R` compares SIMPLS with a dense numerical
  reference on controlled problems.
- `benchmark_simpls_estimator_preservation.R` tests component, coefficient,
  score-subspace, and prediction agreement against `pls::simpls.fit()` and
  keeps the iterative and approximate solver analyses separate.
- `benchmark_opls_kernel_estimator_validation.R` and
  `benchmark_opls_kernel_setting_reliability.R` validate OPLS and linear,
  polynomial, and radial-basis kernel PLS settings.
- `controlled_scaling/` performs multi-seed rSVD qualification and controlled
  scaling over sample count, predictor and response dimensions, retained
  components, requested prefixes, rank, class count, and cross-covariance
  storage.

Run the controlled audit with:

```sh
scripts/run_controlled_scaling.sh RESULTS_DIR qualification cpu,metal 3
scripts/run_controlled_scaling.sh RESULTS_DIR qualification cuda 3
```

## Performance and memory

- `run_current_component_selection.R` performs ten-fold training-only
  component selection for all 11 non-NMR real-data tasks and each PLS family.
  Its `selected_components.csv` output is the required component manifest for
  the selected-backend and independent-package publication workflows;
  inherited counts are disabled by default.
- `run_current_component_path.R` measures predictive performance, fitting and
  prediction time, absolute process RSS, and baseline-corrected host RSS over
  prespecified sparse component checkpoints plus each training-selected value.
  CPU and the requested accelerator are measured in fresh processes with five
  repetitions; any accelerator/backend mismatch is rejected. The companion
  `plot_current_component_path.R` creates one dataset-specific figure and a
  component-outcome correlation table for each hardware platform.
  `plot_combined_component_paths.R` combines the completed CUDA and Metal raw
  tables into the 11 CPU/CUDA/Metal component-path figures used in the
  Supplement.
- `external_simpls_timing/` compares fixed-control float64 CPU-IRLBA SIMPLS with
  `pls::simpls.fit()` under minimum-common-output and public-workflow
  contracts. It records repeated cold-process and steady-state timings,
  baseline and peak process RSS, prediction agreement, and failures.
- `benchmark_pls_package_comparison.R` and
  `../scripts/remote_run_pls_package_comparison.sh` compare the public SIMPLS
  workflow with independent R implementations at the training-selected
  SIMPLS component count. Set `FASTPLS_SELECTED_COMPONENTS_CSV` to the current
  manifest before starting the workflow. Each method-dataset pair receives at
  least three fresh-process runs; pairs whose first successful fit plus
  prediction is under one second receive ten runs to stabilize sub-second
  timing summaries.
- `benchmark_simpls_multidataset_ablation.R` isolates cached deflation
  products, incremental coefficients, compact prediction, conditional
  cross-product caching, and matrix-free products.
- `benchmark_cv_compiled_vs_r_loop.R` and
  `../scripts/run_cv_compiled_vs_r_loop.sh` compare the compiled ten-fold
  SIMPLS engine with an explicit R-level fold loop using identical folds,
  estimators, automatic rSVD controls, classification heads, predictions, and
  training-selected component counts. Unavailable accelerator requests are
  retained as errors and are never rerouted to CPU.
- `metal_validation/` compares matched CPU, CUDA, and Metal execution while
  retaining prediction agreement and memory accounting.
- `benchmark_float32_backend_agreement.R` pairs float32 and float64 results by
  family, backend, and endpoint.
- `backend_family_smoke.R` exercises PLS-SVD, SIMPLS, OPLS, and linear,
  radial-basis, and polynomial kernel PLS for regression and argmax/LDA
  classification in float64 and float32 on one explicitly selected backend.
  It stops rather than substituting CPU when CUDA or Metal is unavailable.
- `multicore_scaling/` measures SIMPLS/rSVD with one, two, and four verified
  OpenBLAS threads across sample-rich, predictor-wide, and response-wide
  controlled workloads. Five fresh-process repetitions report total fitting
  plus prediction time, speed-up, efficiency, and prediction agreement.

## Biomedical and large-scale applications

- `benchmark_nmr_component_selection.R`, `benchmark_nmr_qualified_solver.R`,
  and `benchmark_nmr_deposited_reference.R` use the
  fixed preprocessing and split defined by
  `nmr_protocol_helpers.R`, including predictor water-region handling,
  training-only component selection, matched 165-component implementation
  comparisons, per-spectrum and response-wise errors, and observed-versus-
  predicted spectra.
  The deposited-reference wrapper requires the separately published
  `fastsimpls` source and does not redistribute it.
- `benchmark_nmr_rsvd_control_sweep.R` compares explicit rSVD controls and
  seeds with a fixed CPU-IRLBA prediction under the same NMR protocol. It is
  the release check for the automatic massive-cross-covariance profile.
- The ImageNet scripts assess float32 DINOv2 feature processing as an
  exploratory foundation-model embedding stress test. The manuscript reports
  this separately from biomedical predictive validation.
- `ikpls_cross_language/` contains the matched comparison with IKPLS,
  nirs4all-methods and scikit-learn, including guarded NMR and ImageNet
  feasibility extensions. Estimators, native precision, warnings, failures
  and retained-output contracts remain explicit.

## Provenance

`write_run_provenance.R` records the package version, analysis script, dataset
identifier, split, seed, and session information. Reader-facing manuscript and
package documentation identify release versions and complete numerical
controls; file checksums are not included in those documents.

## Result layout

Only results generated with the frozen package version will be eligible for the
publication evidence bundle. During development, all raw results, summaries,
figures, and rendered documents remain below the external
`FASTPLS_RESULTS_ROOT`; they are not committed here. Intermediate matrices,
older release results, and analyses not reported in the paper will remain local
and will not enter the later evidence repository.
