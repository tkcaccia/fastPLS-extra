# Phase 2 JSS analyses

This directory contains analysis planned for the future *Journal of
Statistical Software* article. The phase is intentionally separated from the
CMPB biomedical and independent-software comparison. It focuses on the
software itself: architecture, interfaces, numerical libraries, hardware
execution, compiled validation, and reproducible public workflows.

## Planned evidence

- `benchmark/mit_core_migration/` and `tools/test_resident_*` exercise the
  shared C++ core and interface ownership boundaries.
- `benchmark/multicore_scaling/` and `benchmark/multicore_selected/` evaluate
  one-, two-, and four-core execution with verified BLAS thread counts.
- `benchmark/precision_selected/` evaluates float32/float64 agreement and
  complete-process runtime and memory.
- `benchmark/metal_validation/`, `benchmark/metal_operation_split/`, and
  `benchmark/native_gpu_special/` examine hybrid Metal and native accelerator
  execution.
- `benchmark/cross_validation_hoisting/` and
  `benchmark/benchmark_cv_compiled_vs_r_loop.R` isolate compiled validation and
  leakage-free sufficient-statistics reuse.
- `benchmark/response_gram/` benchmarks the sample-space response Gram kernel
  across BLAS and specialized compiled implementations.
- `tools/update_cross_language_manuscript.py` and the interface-validation
  tools support the R, Python, and MATLAB software comparison.
- `benchmark/lda_cpu/` and `benchmark/benchmark_lda_backend_agreement.R`
  evaluate the compiled LDA implementation independently of the CMPB package
  comparison.

The future JSS case study may reuse the fixed NMR task definition, but it must
generate its own software-focused evidence and must not copy the CMPB
cross-package comparison into Phase 2.

See [`MANIFEST.csv`](MANIFEST.csv) for the planned section-to-code mapping.
