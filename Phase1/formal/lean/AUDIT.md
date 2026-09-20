# Lean invariant audit

## Scope

The theorem statements in `FastPLSFormal/Invariants.lean` were compared with
the fastPLS C++ core based on commit
`b518f75285c387632c2443a0c0989d75c9dcda48`, including the recorded source
diff SHA-256
`78cece9e8f6d2039cac95020c303556e377bbae2ee15159fb75ab18c66b73b68`.
The audit checks whether each
formal statement accurately represents an algebraic operation used by the
implementation. It is not a proof that the C++ program refines the Lean
specification.

## Correspondence review

| Lean theorem | Current C++ correspondence | Audit conclusion |
| --- | --- | --- |
| `implicit_crossCovariance` | `operators.hpp`: `CenteredCrosscovOperator::multiply`; operator paths used by PLS-SVD and the SIMPLS-family estimator | Correct application of matrix multiplication associativity for the right action of the cross-covariance. |
| `compact_prediction` | `plssvd.hpp`: `assemble_plssvd_model`; `simpls.hpp`: `predict_simpls_preprocessed`; linear-kernel prediction | Correct application of associativity; no numerical or allocation claim is encoded. |
| `plssvd_latent_normal_equation` | `plssvd.hpp`: `assemble_plssvd_model` and its latent score-Gram solve | Correct conditional statement: if the implemented solve satisfies `H * L = D`, the retained response map satisfies the stated normal equation. The theorem does not prove that a finite-precision solve succeeds. |
| `simpls_deflation_orthogonal` | `simpls.hpp`: normalized deflation direction and rank-one `crosscov` update in `fit_simpls_preprocessed` and `fit_simpls_operator` | Correct under the explicit unit-norm assumption on the deflation direction. |
| `simpls_cached_gram_entry` | `simpls.hpp`: response-side cached Gram update following the rank-one cross-covariance deflation | Correct entrywise identity under the same unit-norm assumption. |
| `opls_weight_is_orthogonal` | `opls.hpp`: projection removal in `fit_preprocessed_filter_inplace` and moment-based OPLS filtering | Correct when the predictive weight has nonzero squared norm, matching the implementation guard. |
| `linear_kernel_symmetric` | `kernels.hpp`: linear `kernel_matrix` construction | Correct for `X * X.transpose`. |
| `double_centering_preserves_symmetry` | `kernels.hpp`: `center_kernel_train` and symmetric training-kernel centring | Correct when the kernel and centering matrices are symmetric. |
| `centered_gram_entry` | `cross_validation.hpp`: `prepare_centered_training_response_gram`; `kernels.hpp`: training/test centring corrections | Correct expansion of the centered inner product. |
| `training_statistic_by_subtraction` | `cross_validation.hpp`: `dense_sufficient_statistics`, `dense_marginal_statistics`, `label_sufficient_statistics` and fold preparation | Correct for additive statistics when training and holdout index sets are disjoint. It does not authorize reuse of non-additive or globally centered fold quantities. |

## Reproducible result

The audit command is:

```sh
./check.sh
```

The recorded Linux campaign run reported:

```text
Lean toolchain: Lean (version 4.34.0, x86_64-unknown-linux-gnu, Release)
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
