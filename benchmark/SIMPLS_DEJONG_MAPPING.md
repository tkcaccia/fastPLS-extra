# Accelerated SIMPLS execution mapped to the de Jong update

This executable-style pseudocode documents the deterministic SIMPLS path used
for estimator-preservation validation. The low-rank solver supplies only the
current dominant direction. The SIMPLS normalization, orthogonalization,
deflation, coefficient update, and component order remain sequential.

With centered `X` of dimension `n x p` and centered `Y` of dimension `n x q`,
the current cross-covariance `S = X'Y` has dimension `p x q`. The implementation
extracts its leading **left** singular direction `r` in predictor space
(`r` has length `p`) and then forms the score `t = Xr`. A mathematically
equivalent right-direction formulation would first extract a response-space
vector and map it through `S`, but that is not the convention used below or in
the compiled implementation.

```r
simpls_component_path <- function(X, Y, ncomp, dominant_left) {
  X <- sweep(X, 2L, colMeans(X), "-")
  Y <- sweep(Y, 2L, colMeans(Y), "-")
  S <- crossprod(X, Y)

  R <- matrix(0, ncol(X), ncomp)
  Q <- matrix(0, ncol(Y), ncomp)
  V <- matrix(0, ncol(X), ncomp)
  B <- matrix(0, ncol(X), ncol(Y))
  Yhat <- matrix(0, nrow(X), ncol(Y))

  for (component in seq_len(ncomp)) {
    # de Jong direction extraction from the current deflated cross-covariance.
    r <- dominant_left(S)

    # Standard SIMPLS score normalization and loadings.
    t <- X %*% r
    t_norm <- sqrt(drop(crossprod(t)))
    t <- t / t_norm
    r <- r / t_norm
    p <- drop(crossprod(X, t))
    q <- drop(crossprod(Y, t))

    # Standard SIMPLS orthogonalization and rank-one deflation.
    v <- p
    if (component > 1L) {
      previous <- V[, seq_len(component - 1L), drop = FALSE]
      v <- v - previous %*% crossprod(previous, v)
    }
    v <- v / sqrt(drop(crossprod(v)))
    S <- S - v %*% crossprod(v, S)

    # Incremental execution: algebraically identical to R[,1:k] %*% t(Q[,1:k]).
    R[, component] <- r
    Q[, component] <- q
    V[, component] <- v
    B <- B + r %*% t(q)
    Yhat <- Yhat + t %*% t(q)
  }

  list(R = R, Q = Q, V = V, B = B, fitted_centered = Yhat)
}
```

## Mapping of implementation optimizations

| Optimization | de Jong quantity preserved | Change in execution |
|---|---|---|
| Cached `X'X` for eligible tall matrices | `p = X't`, `||t||`, and the accepted `r` | Reuses an algebraically equivalent cross-product |
| Cached deflation row product | `S <- S - v(v'S)` | Evaluates `v'S` once before the rank-one update |
| Incremental coefficient update | `B_k = R_k Q_k'` | Uses `B_k = B_{k-1} + r_k q_k'` |
| Incremental fitted-response update | `Yhat_k = T_k Q_k'` | Uses `Yhat_k = Yhat_{k-1} + t_k q_k'` |
| Compact latent prediction | `X_new B_k = (X_new R_k) Q_k'` | Retains latent factors instead of every dense coefficient and prediction prefix |
| Matrix-free cross-covariance | The global operator `S = X'Y` | Evaluates `S z = X'(Y z)` and `S' u = Y'(X u)` without storing `S` |

Like `pls::simpls.fit`, the reference SIMPLS implementation in the `pls`
package, one fit supplies the sequential coefficient and fitted-value path for
components 1 through `ncomp`. fastPLS does not claim component-path generation
itself as a novelty. Its contribution is the compiled incremental execution,
compact prediction, matrix-free products, and backend-specific storage layer
summarized above.

## Cost and storage model

Let `n`, `p`, and `q` denote samples, predictors, and responses; let `A` be the
largest requested component count; and let `C` be the set of requested prefixes.
A minimally optimized compiled baseline first forms `S = X'Y` in `O(npq)` time
and `O(pq)` storage. Beyond the solver-specific direction cost, `A` sequential
SIMPLS updates require `O(A[np + nq + pq] + pA^2)` work and retain
`O(pq + (2p + q)A)` core state. Rebuilding dense coefficients and fitted values
at every requested prefix adds
`O(pq sum(C) + nq sum(C))` work. Retaining every dense prefix adds
`O(|C|(pq + nq))` storage.

Incremental updates reduce the prefix-reconstruction work to `O(Apq + Anq)`;
they do not change the SIMPLS estimator. Compact prediction retains
`R_A` and `Q_A`, requiring `O((p + q)A)` model storage and
`O(n_test A(p + q))` prediction work, instead of a dense `p` by `q`
coefficient matrix per prefix and `O(n_test pq)` prediction per prefix.
For an operator sketch of width `l`, the matrix-free route replaces the
`O(pq)` cross-covariance with `O((n + p + q)l)` working storage; each operator
pair costs `O(n(p + q)l)`. It can therefore be slower when `pq` is modest, but
substantially reduce memory when the predictor-response cross-product is large.
Caching `X'X` adds `O(np^2)` setup and `O(p^2)` storage, and is enabled only for
tall, sufficiently reused shapes where replacing repeated sample-space
products can amortize that cost. Caching the deflation row product changes a
constant factor rather than the asymptotic order.

Every deflated component requests a direction from the current operator.
IRLBA starts a new iterative solve. On ordinary CPU, CUDA, and Metal PLS
problems, rSVD starts a new seeded Gaussian sketch of the current deflated
operator with 32 oversampling directions and five power iterations. Numeric
responses with at least 64 columns and a response-to-sample ratio of at least
0.2 use 48/6; classification with at least 32 classes and no more than 20
samples per class uses 64/7. When the explicit predictor-response
cross-covariance would exceed 512 MiB, the automatic massive-matrix profile
records `oversample = 12` and `power = 2` and takes precedence over the other
profiles. In this regime, CPU,
CUDA, and Metal obtain each component from a newly initialized rank-one
randomized direction; CUDA retains the sequential state on the device.
CUDA may generate up to eight fresh candidates together for eligible large
classification workloads. Those candidates are accepted one at a time only
after the same sequential SIMPLS orthogonalization, score/loading, and
deflation updates shown above. CPU supports explicit and matrix-free sketches,
CUDA performs the large sketch products on device, and Metal performs the
large sketch products on the GPU with the reduced QR/SVD on the host.

## Exact dense-reference audit

`benchmark/benchmark_simpls_exact_reference.R` independently implements the
updates above with base R's dense LAPACK `svd()` and compares them, component
prefix by component prefix, with the compiled SIMPLS path forced to its
audit-only dense LAPACK solver. This reference is separate from both the
iterative IRLBA validation and the approximate rSVD qualification.

The fixed panel includes well-conditioned, nearly tied, rank-deficient,
highly collinear, `p < n`, `p > n`, high-response-dimensional, effective-rank
boundary, multivariate-regression, and dummy-response classification cases.
It records coefficient, fitted-value, held-out-prediction, score/loading/
projection-subspace, orthogonality, deflation, decoded-label, and convergence
results for every component prefix. Near-tied singular values are interpreted
through subspaces and predictions because individual singular vectors are not
identifiable within a tied subspace.
