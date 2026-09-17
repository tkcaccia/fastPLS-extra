# Lean invariant audit

## Scope

The theorem statements in `FastPLSFormal/Invariants.lean` were compared with
the fastPLS C++ core at commit
`8b9d03eb3274801e4c59209ff19d640b198c9ade`. The audit checks whether each
formal statement accurately represents an algebraic operation used by the
implementation. It is not a proof that the C++ program refines the Lean
specification.

## Correspondence review

| Lean theorem | Core area | Audit conclusion |
| --- | --- | --- |
| `implicit_crossCovariance` | PLS-SVD and SIMPLS-family explicit/operator cross-covariance paths | Correct application of matrix multiplication associativity for the right action of the cross-covariance. |
| `compact_prediction` | Compact latent prediction in PLS-SVD, SIMPLS-family and linear-kernel paths | Correct application of associativity; no numerical or allocation claim is encoded. |
| `plssvd_latent_normal_equation` | PLS-SVD latent score-Gram solve | Correct conditional statement: if the implemented solve satisfies `H * L = D`, the retained response map satisfies the stated normal equation. The theorem does not prove that a finite-precision solve succeeds. |
| `simpls_deflation_orthogonal` | SIMPLS-family rank-one cross-covariance deflation | Correct under the explicit unit-norm assumption on the deflation direction. |
| `simpls_cached_gram_entry` | Cached response-side Gram update after SIMPLS-family deflation | Correct entrywise identity under the same unit-norm assumption. |
| `opls_weight_is_orthogonal` | OPLS removal of the predictive-weight projection from the predictor loading | Correct when the predictive weight has nonzero squared norm, matching the implementation guard. |
| `linear_kernel_symmetric` | Linear-kernel Gram construction | Correct for `X * X.transpose`. |
| `double_centering_preserves_symmetry` | Symmetric kernel double centering | Correct when the kernel and centering matrices are symmetric. |
| `centered_gram_entry` | Fold-local response Gram and kernel centering corrections | Correct expansion of the centered inner product. |
| `training_statistic_by_subtraction` | Cross-validation sufficient-statistic caching | Correct for additive statistics when training and holdout index sets are disjoint. It does not authorize reuse of non-additive or globally centered fold quantities. |

## Reproducible result

The audit command is:

```sh
./check.sh
```

The checked local run reported:

```text
Lean toolchain: Lean (version 4.34.0, arm64-apple-darwin24.6.0, Release)
Checked theorem declarations: 10
Build completed successfully (1256 jobs).
fastPLS algebraic-invariant audit: PASS
```

The resolved Mathlib revision is pinned in `lake-manifest.json`. The audit
rejects `sorry` and `admit` before invoking `lake build`.

## Interpretation

The formal statements support the exact-real algebraic legitimacy of selected
computational transformations. They do not establish floating-point error
bounds, randomized-SVD accuracy, convergence, backend equivalence, or
end-to-end correctness of the compiled implementation. They also do not prove
that the bounded-block estimator equals classical one-direction SIMPLS. The
term **SIMPLS-family** remains appropriate because the implementation retains
the sequential projection and deflation structure while changing candidate
direction generation.
