# Repeated external SIMPLS timing comparison

This benchmark separates two questions that must not share the same label.

1. `estimator_kernel`: deterministic float64 SIMPLS is compared between
   `fastPLS::pls()` with CPU IRLBA and `pls::simpls.fit(stripped = TRUE)`.
   Both routes retain the complete coefficient path and final held-out class
   predictions. Scores, loadings, fitted-value arrays, and variance summaries
   are suppressed.
2. `complete_workflow`: each implementation retains its ordinary public fit
   object and final held-out predictions. The larger objects produced by the
   default workflows are measured rather than normalized away.

Every cold repetition starts in a fresh R process. Package loading and data
loading occur before the timed fit. The steady-process profile performs one
untimed fit and prediction to initialize only package/runtime state; it never
reuses fitted-model or direction state. The train/test split, component count,
float64 precision, one effective BLAS thread, and 10,000-second timeout
are common. Fit, prediction, total time, returned-object sizes, accuracy,
warnings, failures, and the number of completed repetitions are retained.

Memory is reported at three distinct levels. `process_peak_rss_mb` is the
absolute lifetime peak of the isolated R worker and therefore includes R,
loaded packages, data, and benchmark infrastructure. `prefit_process_rss_mb`
is sampled after package/data preparation and garbage collection, immediately
before fitting. `baseline_corrected_peak_increment_mb` subtracts that pre-fit
baseline from the absolute peak. It is a baseline-corrected process increment,
not an isolated measurement of algorithmic workspace. Formula-based sizes are
also reported for the explicit cross-covariance matrix, final coefficient
matrix, coefficient path, fitted/residual paths, training scores, and held-out
class-score matrix. These sizes explain the storage implied by each output
contract without conflating it with allocator or runtime overhead.

Run with:

```sh
bash scripts/run_external_simpls_timing.sh
```
