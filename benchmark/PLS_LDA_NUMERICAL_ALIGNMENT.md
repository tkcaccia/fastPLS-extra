# PLS-LDA numerical alignment

## Numerical path

For a PLS score matrix `T` with `q` retained components, class counts `n_c`,
and class means `mu_c`, fastPLS computes the pooled within-class covariance as

`Sigma = (T' T - sum_c n_c mu_c mu_c') / max(1, n - C)`.

No centered class-specific score blocks are materialized. For each class,
`Sigma w_c = mu_c` is solved by a Cholesky factorization followed by forward
and backward triangular solves. Neither the CPU nor CUDA implementation forms
`solve(Sigma)` explicitly.

Regularization is deterministic and scale normalized. The scale is
`s = trace(Sigma) / q` when finite and positive and `s = 1` otherwise. The
solver tries `lambda = rho * s` for `rho` equal to `1e-8`, `1e-6`, `1e-5`,
`1e-4`, `1e-3`, and `1e-2`, in that order. It advances to the next value only
when Cholesky factorization fails. This ladder is a numerical fallback, not a
tuned model hyperparameter. Prediction preserves the LDA discriminant

`delta_c(t) = t' w_c - 0.5 * mu_c' w_c + log(n_c / n)`.

The float32 CPU implementation uses float score moments, covariance,
factorization, coefficients, and prediction scores. The CUDA implementation
uses `cublasSgemm`, `cusolverDnSpotrf`, and `cusolverDnSpotrs`, and retains a
thread-local workspace so repeated fits reuse device allocations. The
double-precision and streamed large-data paths use the same covariance formula,
regularization order, Cholesky solve, and discriminant.

## Scope of the port

The following fastPLS optimizations were already equivalent or more general
and were retained without changing their mathematics:

- label-aware class-sum cross-products avoid dense one-hot responses in the
  optimized classification paths; accumulated rows are now always remapped by
  class code, so their order cannot depend on which class appears first in a
  block;
- SIMPLS can reuse `X'X` when its existing shape-based cache is applicable;
- low-level LDA kernels use contiguous integer class codes while public
  predictions are mapped back to the original factor labels;
- the CUDA PLS workspace already reuses device buffers.

The new work adds persistent float32 CPU solve buffers and a persistent CUDA
LDA workspace, and routes streamed score moments through the compiled Cholesky
solver. Fold assignments are built once and reused within a cross-validation
call. A process-global cache across independent calls was deliberately not
added because it could retain stale matrices or folds after the input data
change.

No SIMPLS deflation, PLS component construction, requested-component capping,
or classifier decision rule was changed.

## Validation

Unit tests are in `tests/testthat/test-lda-cholesky-backends.R`. They cover
singular pooled covariance, the covariance and discriminant definitions,
streamed-moment equivalence, float32 versus double agreement, and CPU/CUDA
agreement when CUDA is available.

`benchmark/benchmark_lda_backend_agreement.R` runs fixed-seed, identical-split
comparisons on MetRef, CIFAR-100, and SingleCell. It records runtime, accuracy,
prediction agreement with the previous inverse-based reference, requested and
effective component counts, the best evaluated component count, and numerical
failures. CPU and CUDA results are reported separately, and failed runs remain
in the output.

The corrected benchmark showed complete fixed-score prediction agreement for
every dataset, PLS method, and component count, with no numerical failures.
At 20 components, SIMPLS LDA accuracy was 0.8900 on MetRef, 0.7663 on
CIFAR-100, and 0.8198 on SingleCell for the legacy, CPU float32, and CUDA
float32 implementations alike. The corresponding float32 LDA-head medians
were approximately 0.019 s (CPU) and 0.006 s (CUDA) on CIFAR-100, versus
0.029 s for the inverse-based reference; on SingleCell they were 0.021 s and
0.004 s, versus 0.036 s. Public end-to-end CPU/CUDA prediction agreement was
at least 0.999916 across the tested grid.

An earlier benchmark draft used `rowsum(..., reorder = FALSE)` without always
mapping the returned row names back to class codes. On shuffled labels that
made the reference class means order-dependent. That validation error was
fixed before the results above were retained.
