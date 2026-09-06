# fastPLS-extra

Companion source repository for fastPLS extensions, reproducible benchmarks,
and publication-generation code. This directory has not yet been published.

It now contains an installable development R package named `fastPLSextra`.
Install the current development fastPLS headers first, then use
`R CMD INSTALL /path/to/fastPLS-extra`. Its initial `irlba()` and `pls_irlba()`
interfaces support explicit CPU float64 SVD, SIMPLS and PLS-SVD. Models can
be serialized and used with `predict()`. `irlba_crossprod(x, y, ncomp)`
decomposes the uncentered product `t(x) %*% y` through shared native operators,
without allocating that product. Implicit PLS fitting, float32 and GPU companion
routes have not yet been migrated; unsupported inputs are not silently
converted. This is not a release-ready replacement for every former IRLBA path.

The intended dependency direction is `fastPLS-extra -> fastPLS`, never the
reverse. Native rSVD, SIMPLS, PLS-SVD, OPLS, kernel PLS, classification and
cross-validation remain in fastPLS. IRLBA integration and manuscript experiments
belong here. Moving a solver must not duplicate the PLS engines or silently
substitute a different estimator.

## License Boundary

The companion code is distributed under GPL-3, retaining any more specific
third-party notices. This does not grant rights to relicense third-party code.
Manuscript text, images and datasets require separate ownership and redistribution
checks; the code license must not be assumed to cover them.

The adapter includes the native PLS headers from the installed fastPLS
package; it does not copy SIMPLS or PLS-SVD into this repository. The C solver
sources in `src/` originate from the preserved GPL distribution. The local
adaptation initializes its convergence flag explicitly. Dense full-subspace
decompositions are identified separately in convergence records. Iterative
nonconvergence raises an error, rather than returning an unchecked model.

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

See [MIGRATION.md](MIGRATION.md) for the implementation and validation gates.

Historical extraction snapshots and obsolete manuscript revisions are retained
locally outside this Git checkout. They are not needed to build the companion
package or reproduce the current benchmark workflows.

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

The working main package no longer compiles the bundled IRLBA sources.
To verify the companion against saved comparison data without executing the
old main-package IRLBA path:

```sh
Rscript tools/check_companion.R /path/to/current/companion/library \
  /path/to/local/reference/records.rds \
  /path/to/new/comparison/output
```

This executes only the current companion. The second argument is a read-only
96-case result archive, not a package to load or execute.

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
