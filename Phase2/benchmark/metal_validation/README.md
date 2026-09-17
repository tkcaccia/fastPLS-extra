# Local Apple Metal validation

This benchmark isolates each fit in a separate R process and records fitting
time, prediction time, predictive performance, execution status, warnings,
absolute process RSS, and baseline-corrected incremental process RSS.

Apple silicon uses unified memory. Consequently, the benchmark does not report
a separate GPU-memory value: Metal buffers and host allocations share the same
physical memory pool. The process-RSS columns are labelled as unified-process
memory and must not be compared directly with dedicated CUDA VRAM.

Run stages from the repository root:

```sh
Rscript benchmark/metal_validation/run_metal_validation.R smoke
Rscript benchmark/metal_validation/run_metal_validation.R scaling
Rscript benchmark/metal_validation/run_metal_validation.R real
Rscript benchmark/metal_validation/run_metal_validation.R nmr
Rscript benchmark/metal_validation/run_metal_validation.R model_specific
Rscript benchmark/metal_validation/run_metal_cv_validation.R
Rscript benchmark/metal_validation/run_metal_svd_reliability.R
Rscript benchmark/metal_validation/summarize_metal_validation.R \
  benchmark_results/metal_validation_20260726
Rscript benchmark/metal_validation/write_metal_validation_report.R \
  benchmark_results/metal_validation_20260726
```

The `smoke` stage tests all four PLS families, CPU and Metal backends, float64
and float32 inputs, and argmax/LDA classification. The `scaling` stage compares
PLS-SVD and SIMPLS across synthetic matrix regimes. The `real` stage uses fixed
existing task objects. The guarded NMR stage uses the full sample and predictor
dimensions but limits the response dimension unless an explicit larger limit is
requested. Model-specific runs cover OPLS orthogonal components and linear,
radial-basis, and polynomial kernel PLS. Cross-validation is reported
separately because the public Metal request may include compiled CPU stages.
