# CPU LDA solver comparison

This experiment compares the current float32 workspace Cholesky and float64
LAPACK Cholesky implementations with precision-mirrored alternatives. The
candidate code is derived from the owned current fastPLS implementation,
not from an external PLS package. It is experimental and is not installed by
the R package.

All methods use the same pooled covariance, class priors, discriminant and
regularization sequence. No inverse is formed. This is an LDA-stage benchmark
on synthetic score matrices, not a full PLS or manuscript-dataset benchmark.

Configure with FASTPLS_SOURCE pointing to current development fastPLS and
BLA_VENDOR=OpenBLAS. Run the built lda_audit first, then run:

```sh
python3 run.py --binary /path/to/build/lda_benchmark --out /new/results/path
```

The worker reports OpenBLAS configuration and its runtime thread setting.
Threads 1, 2 and 4 are tested serially. Each n/score/precision combination has
one untimed warm-up and 15 measured repetitions per solver, with alternating
solver order. Scores are generated from the same double-precision random
sequence and converted before timing. Timers separate moments, solve and
held-out prediction; total excludes PLS fitting, score generation, conversion
and process startup. Raw repetitions, medians and IQRs are retained. An
OpenBLAS thread setting does not imply every small operation uses every core.

The two initial runs are exploratory: lda_cpu_comparison_20260905 used
precision-specific random sequences; lda_cpu_matched_precision_20260905
overlapped briefly with compilation. Use lda_cpu_final_20260905 for the
matched-precision timing summary. Do not treat these synthetic results as
real-dataset validation or peak-memory evidence.

The singular-covariance audit showed about 1.96% float32 weight disagreement
between workspace and LAPACK despite small backward residuals and equal
regularization levels. A universal production replacement therefore requires
real PLS-score prediction/metric validation, not merely these timing results.
