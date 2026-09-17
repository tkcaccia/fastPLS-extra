# fastPLS machine-checked algebraic invariants

This Lean 4 project checks exact-real-arithmetic identities used by the fastPLS
execution paths. It covers implicit cross-covariance products, compact latent
prediction, the PLS-SVD latent normal equation, SIMPLS-family deflation
orthogonality, the exact cached SIMPLS Gram update, the OPLS orthogonal weight,
linear and centered kernel symmetry, centered Gram entries, and subtraction of
held-out sufficient statistics in cross-validation.

The proofs establish the stated identities for finite matrices and vectors over
the real numbers. They do not establish floating-point accuracy, randomized-SVD
error bounds, convergence, equivalence to classical de Jong SIMPLS, or
correspondence between this specification and compiled C++/CUDA/Metal code.

The bounded-block estimator is therefore described as SIMPLS-family. The Lean
proofs confirm algebraic invariants retained by its projection, deflation and
prediction updates; they do not classify the estimator or prove that its
candidate directions equal those of the one-direction SIMPLS recurrence.

## Check the proofs

Install Lean through `elan`, then run the complete audit:

```sh
./check.sh
```

The audit prints the Lean version and theorem count, rejects `sorry` and
`admit`, and runs `lake build`. The pinned Lean toolchain is recorded in
`lean-toolchain`; `lake-manifest.json` records the resolved Mathlib revision
used for the reported proof build. `lake exe cache get` may be run first to
obtain the optional Mathlib cache. Do not run `lake update` when reproducing
the build, because it can resolve newer dependency revisions and modify the
manifest.

The same audit is run by `.github/workflows/lean-formal.yml`.
