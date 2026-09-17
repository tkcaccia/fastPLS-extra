# fastPLS-extra

Companion source repository for reproducible fastPLS benchmarks,
publication-generation code, and machine-checked algebraic invariants.

This repository is not an installable R package and does not implement PLS or
IRLBA. All supported modelling functions, including native rSVD, SIMPLS,
PLS-SVD, OPLS, kernel PLS, classification and cross-validation, belong to the
`fastPLS` package. Benchmark workers load an explicitly selected `fastPLS`
installation and write generated evidence outside both source repositories.

References to IRLBA in deposited-result labels or manuscript comparison tables
identify an external or previously deposited method. They are evidence
metadata, not executable solver code in this repository.

## License Boundary

Repository code is distributed under GPL-3 unless a file carries a more
specific notice. This does not grant rights to relicense third-party code.
Manuscript text, images and datasets require separate ownership and
redistribution checks; the code license must not be assumed to cover them.

## Boundary Checks

```sh
python3 tools/audit_distribution.py --source ../fastPLS_fresh_github \
  --output /path/outside/git/source_inventory.json
python3 tools/audit_repository_boundary.py . ../fastPLS_fresh_github
python3 -m unittest discover -s tests -v
```

The audit records package metadata, file fingerprints, explicit notices,
external includes and unresolved boundaries. Absence of a GPL comment is never
treated as proof of MIT ownership.

Historical extraction snapshots and obsolete manuscript revisions are retained
locally outside this Git checkout. They are not needed to reproduce the current
benchmark workflows.

## Machine-checked algebraic invariants

The Lean 4 project in `Phase1/formal/lean/` checks the exact-real-arithmetic
identities reported in the CMPB supplementary material. The project includes a
pinned Lean toolchain, resolved Mathlib manifest and theorem-by-theorem audit.
From the repository root, run:

```sh
cd Phase1/formal/lean
./check.sh
```

The audit reports the pinned Lean version and theorem count, rejects incomplete
proof placeholders and runs `lake build`. These proofs establish the stated
algebraic identities; they do not verify floating-point error, randomized-SVD
accuracy, or equivalence between the Lean specification and compiled code.

Shared validation runners are available here:

```sh
python3 tools/check_release_candidate.py --source /path/to/current/source \
  --out /path/to/new/check/output
Rscript tools/run_candidate_tests.R /path/to/current/library \
  /path/to/current/source/tests/testthat /path/to/new/test/results.rds
```

The source-package checker uses the existing local macOS/Metal check profile;
it is not a substitute for CUDA or Windows checks. Its output records all
remaining check notes and warnings. The installed-test runner does not install
or choose a different package: its library path must be supplied explicitly.

## Benchmark And Publication Workflows

All reusable performance, numerical-validation, and manuscript-generation code
is maintained outside the installable `fastPLS` package:

- `benchmark/` contains dataset acquisition, fixed-split benchmark
  runners, CPU/CUDA/Metal workers, component selection, qualification studies,
  and result summarizers.
- `scripts/` contains local and remote workflow launchers.
- `tools/` contains the package-specific figure, table,
  citation, notation, and manuscript audit tools.
- `config/benchmark.env.example` documents the source, data, result, and
  document-output roots used by local and remote runs.

Generated CSV, RDS, log, figure, document, and check outputs are intentionally
ignored. They remain local during development and will be published only after
the package is frozen, in a separate immutable evidence repository. Benchmark
scripts must record the installed `fastPLS` version, source identifier, fixed
task fingerprint, precision, backend, randomized controls, seed, and output
contract so that no result is silently attributed to a different package build.

Configure a run without writing evidence into either Git checkout:

```sh
cp config/benchmark.env.example config/benchmark.env
# Edit the four paths, then load them before running a workflow.
set -a
. config/benchmark.env
set +a
```

Use separate absolute paths for the package source, benchmark source, prepared
data, and generated evidence. The example configuration deliberately contains
no machine-specific defaults.

No benchmark result belongs in `tkcaccia/fastPLS` or `tkcaccia/fastPLS-extra`.
When the package is frozen, a selected immutable evidence bundle will be
created in a separate results repository.
