# fastPLS mathematical and pseudocode audit

Date: 2026-09-19

## Scope

This audit compared the C++17 implementation in `fastPLS` with the algorithm
descriptions in the CMPB manuscript, CMPB supplement, JSS draft, vignette, and
reference documentation. It covered rSVD, PLS-SVD, SIMPLS, OPLS, linear and
nonlinear kernel PLS, LDA, single and nested cross-validation, prediction,
evaluation metrics, permutation inference, Pearson correlation, and VIP.

The audited package checkout was commit
`b518f75285c387632c2443a0c0989d75c9dcda48` plus the explicitly recorded local
changes whose binary-diff SHA-256 is
`78cece9e8f6d2039cac95020c303556e377bbae2ee15159fb75ab18c66b73b68`.
This is the frozen source used by the current CMPB evidence campaign. The
document generator checkout was commit
`044e5f2f2ccd7e73c18e56641e73be1bd6c29fe5` plus its recorded current changes.

## Dimensional conventions

Let `X` be `n x p`, `Y` be `n x q`, and let `a` denote a retained component
count. The centered cross-covariance is `S0 = X'Y`, of size `p x q`.

| Quantity | Dimension | Meaning |
|---|---:|---|
| `R_a` or `U_a` | `p x a` | predictor-space latent directions |
| `T_a = X R_a` or `X U_a` | `n x a` | training scores |
| `Q_a` | `q x a` | SIMPLS response loadings |
| `V_a` | `q x a` | PLS-SVD response singular directions |
| `H_a = T_a'T_a` | `a x a` | PLS-SVD score Gram matrix |
| `D_a` | `a x a` | retained singular values |
| `W_a` | `a x q` | PLS-SVD latent response map |

The documents reserve `C` for the set of requested component counts and use
`G` for the number of classes. `L_a` denotes the solution of
`H_a L_a = D_a`, and `W_a = L_a V_a'`. The cross-validation algorithm uses
`I_train,h` and `I_hold,h` for row-index sets so that `T_a` remains reserved for
the PLS score matrix. Algorithms 1 and 2 define `A = max(C)` for the maximal
fitted path and use `a ∈ C` for a returned prefix.

## Algorithm findings

### Randomized SVD

The implementation follows a randomized range finder with optional power
iterations, QR orthonormalization, a reduced decomposition, and mapping to the
original space. The direct and operator implementations use compatible
singular-triplet residual and orthogonality checks.

Two reduced-Gram paths compared eigenvalues of `B B'`, which are squared
singular values, against a first-power singular-value tolerance. This was not
scale invariant and could discard valid components for small-magnitude data.
The threshold is now squared and scaled by the largest Gram eigenvalue. Related
unit-scale floors were removed from the portable float32 QR, eigensolver, SVD,
and pivoted linear solve. Scale-sensitive regression tests were added.

### PLS-SVD

The implementation and pseudocode agree. With
`S0 approximately U D V'`, the score matrix is `T = XU` and the least-squares
latent map satisfies

`W_a = (T_a'T_a)^(-1) D_a V_a'`.

The code does not form the inverse. It solves `H_a L_a = D_a` by Cholesky,
using a general linear solve only as a numerical fallback, and stores
`W_a = L_a V_a'`. Prediction is `(Xnew U_a) W_a`, followed by restoration of
the training-response mean. This derivation also confirms that `V_a` alone is
not a response regression loading.

### SIMPLS

For a one-direction refresh, the source follows the de Jong recurrence:

1. obtain a leading left direction `r` from the current deflated `S`;
2. form and normalize `t = Xr` and `p = X't`;
3. set `c = S0'r = Y't`;
4. orthogonalize `p` against the retained deflation basis to obtain unit `v`;
5. compute `h = v'S` once and update `S <- S - vh`.

When `G = S'S` is cached, `G <- G - h'h` is exact for unit `v`. Compact
prediction `(Xnew R_a)Q_a'` is algebraically the same as applying
`B_a = R_a Q_a'` without storing every dense coefficient prefix.

The direct-fit serializer retains the complete requested path when numerical
rank or response variation yields fewer directions than requested. A requested
prefix `a` is evaluated with `min(a,e)`, where `e` is the completed direction
count; positions above `e` repeat the last estimable prediction, coefficient
path, and LDA score. If `e = 0`, regression uses the training-response mean and
classification uses the documented class-prior or constant-class fallback.
The returned requested and effective component counts remain distinct.

Some eligible large routes obtain several candidates from one deflated state
and consume them sequentially. The second and later candidates were not solved
from the intervening deflated states. This is therefore an approximate
SIMPLS-family block estimator, not exact de Jong SIMPLS. The current manuscript,
JSS pseudocode, and vignette state this distinction. Headline results from the
block route must not be described as exact estimator preservation.

### OPLS

The OPLS pseudocode agrees with the source. For each orthogonal component it
forms a predictive weight `w`, score `t = Xf w`, and loading
`p = Xf't/(t't)`. It constructs

`wo = p - w(w'p)/(w'w)`,

normalizes `wo`, forms `to = Xf wo`, computes `po = Xf'to/(to'to)`, and updates
`Xf <- Xf - to po'`. Prediction applies the stored filters in extraction order
before the SIMPLS predictive core. Every orthogonal component is estimated
inside the relevant training population.

### Kernel PLS

The linear route correctly reuses the ordinary standardized predictor matrix
and avoids an `n x n` Gram matrix. The RBF and polynomial definitions agree
with the implementation. Training uses double centering. A test cross-kernel is
centered with its own row means, the stored training column means, and the
training grand mean. Nonlinear kernel storage is quadratic in `n`, and the
pre-allocation guard is part of the public mathematical contract.

### LDA

The implementation and main manuscript now use the same pooled covariance:

`Sigma = [T'T - sum_g n_g mu_g mu_g'] / max(1, n - G)`.

The regularization scale is `s = trace(Sigma)/a`, where `a` is the retained
score dimension, not response dimension `q`. The code tries
`lambda = rho s` for `rho = 10^-8, 10^-6, 10^-5, 10^-4, 10^-3, 10^-2`, in
that order and only advances after Cholesky failure. It solves
`(Sigma + lambda I)w_c = mu_c` and evaluates

`delta_c(t) = t'w_c - 0.5 mu_c'w_c + log(n_c/n)`.

No explicit covariance inverse or Gauss-Jordan elimination is used.

### Cross-validation and permutation inference

The compiled CV pseudocode agrees with the source. Full-data sufficient
statistics are reused only under guarded routes. Fold training statistics are
obtained by subtracting held-out contributions, after which centering and
scaling are calculated from the training fold only. Nonlinear kernels remain
fold local. Nested validation recreates or derives caches inside each outer
training partition and does not share response information across an outer
boundary.

The executable pseudocode states the nested procedure without recursion:
Steps 2-10 are applied to inner folds formed exclusively within each outer
training partition, the selected prefix is refitted on that complete outer
training partition, and only then is its outer holdout predicted.

Constant-response and rank-deficient folds retain every requested component
position by repeating the last estimable result. Zero-direction folds use the
training mean for regression or the class-prior/constant-class classification
fallback. These rules are the same in single CV, nested CV, and direct fitting.

Independent-test `Q2` uses the training-response mean. Cross-validated `Q2`
uses fold-training means. Training `R2Y` remains distinct from both. Monte Carlo
permutation p-values use `(b + 1)/(B + 1)`, exclude failed null fits from `B`,
and report failures. Grouped permutations exchange complete groups only within
equal-size strata while retaining fixed fold plans and solver seeds.

## Auxiliary-statistics corrections

`evaluate(..., na.rm = FALSE)` previously omitted incomplete pairs but reported
the unfiltered sample count. It now stops explicitly when incomplete values are
present. Classification macro precision and macro F1 now average over observed
classes and assign zero contribution when an observed class is never predicted.
An all-missing classification score row now remains missing instead of silently
decoding to the first class.

The standard component-wise VIP formula is valid for direct SIMPLS, where the
stored score and response-loading decomposition has the required meaning. It is
not the same quantity for PLS-SVD, OPLS, or nonlinear kernel PLS: PLS-SVD uses a
prefix-specific score-Gram correction, OPLS first transforms predictor space,
and nonlinear kernel weights index training observations. `ViP()` now supports
direct SIMPLS and the direct linear-kernel SIMPLS route and stops explicitly for
the other cases. The vignette and reference example were updated accordingly.

`fastcor()` is mathematically Pearson correlation: centering followed by unit
Euclidean normalization gives the same correlation because the common variance
divisor cancels.

## Pseudocode and document corrections

- CMPB Algorithm 1 matches the implemented one-direction and bounded-block
  SIMPLS-family paths, explicitly identifies the block approximation, and
  documents truncated and zero-direction prediction paths.
- CMPB Algorithm 2 and JSS Algorithm 2 now use distinct score-Gram, solve, and
  latent-map symbols.
- The main manuscript now gives the exact LDA covariance, regularization, solve,
  and discriminant instead of referring to a nonexistent supplementary
  algorithm.
- The stale reference to `Algorithm S3` was replaced by a reference to the
  compiled cross-validation workflow.
- CMPB Algorithm 3 now reserves `C` for requested component counts, uses
  explicit training and holdout index sets, and gives a nonrecursive nested-CV
  procedure.
- Supplementary Algorithms S1 and S2 match the implemented OPLS and kernel PLS
  execution, including requested component paths, effective-rank truncation and
  training-only LDA fitting. JSS Algorithms 3-5 retain the corresponding
  software-oriented descriptions of OPLS, kernel PLS and CV execution.
- The vignette now uses retained score dimension `a` in the LDA scale and uses
  the same PLS-SVD notation as the manuscripts.
- No warm-start direction rule appears in the current documents or public
  algorithm descriptions.

## Verification

- All 13 standalone C++ core tests passed after the numerical-threshold changes.
- A fresh macOS arm64 package installation completed with Apple Accelerate and
  the compiled Metal objects.
- The complete installed R test suite passed, with platform-specific
  CUDA/Metal/Windows tests skipped when their runtime was unavailable. No test
  failed.
- Focused tests passed for rSVD recovery, PLS prediction, LDA, OPLS, kernel PLS,
  CV sufficient statistics, Q2 definitions, evaluation metrics, and VIP scope.
- The CMPB manuscript, CMPB supplement, and JSS draft were regenerated and
  rendered without clipped algorithm tables.
- `R CMD check --no-manual` completed with status `OK` on the code-identical,
  vignette-enabled `fastPLS_0.3.tar.gz`; both vignette sources were rebuilt.

## Scientific wording that must be retained

1. Call the block path an approximate SIMPLS-family estimator, not exact de
   Jong SIMPLS.
2. Do not infer rSVD accuracy from finite factors alone; report controls, seed,
   route, and numerical diagnostics with approximate results.
3. Distinguish independent-test Q2, cross-validated Q2, and training R2Y.
4. Describe nonlinear kernel PLS as an `O(n^2)` storage method.
5. Describe Metal as an operation-split CPU/Metal route and CUDA as native only
   for the stages that remain device resident in the audited implementation.
6. Interpret VIP only for the supported direct SIMPLS representation.
