# fastPLS-extra

Reproducibility repository for the fastPLS publication programme. The source
is divided by publication phase so that the biomedical methods study and the
later software paper do not share an ambiguous analysis directory.

## Publication phases

- [`Phase1/`](Phase1/) contains the analysis used by the *Computer Methods and
  Programs in Biomedicine* manuscript and its Supplementary Material. It
  includes dataset acquisition, independent-software benchmarks, CPU/CUDA
  comparisons, component paths, numerical validation, NMR and ImageNet
  analyses, figure and table builders, and the Lean algebraic-invariant proofs.
- [`Phase2/`](Phase2/) contains work for the future *Journal of Statistical
  Software* article. It covers software architecture, cross-language parity,
  installation and numerical libraries, multicore scaling, Metal execution,
  precision and capability studies, compiled validation, and lower-level
  matrix-kernel experiments.
- [`archive/`](archive/) contains obsolete development experiments and one-off
  publication-cycle utilities. Archived code is not evidence for either
  manuscript.

The detailed evidence maps are [`Phase1/MANIFEST.csv`](Phase1/MANIFEST.csv) and
[`Phase2/MANIFEST.csv`](Phase2/MANIFEST.csv). Run phase-specific commands from
the corresponding phase directory so that paths such as `benchmark/...`,
`scripts/...`, and `tools/...` resolve consistently.

## Repository boundary

This repository is not an installable package and does not implement the
public fastPLS API. The modelling implementation belongs to the MIT-licensed
`fastPLS` repository. Generated data, benchmark results, figures, rendered
documents, package libraries, and check outputs are intentionally excluded
from this Git repository. They remain in an external results root until a
frozen evidence release is deposited.

Copy [`config/benchmark.env.example`](config/benchmark.env.example) to the
ignored `config/benchmark.env`, edit the absolute paths, and load it before
running either phase:

```sh
cp config/benchmark.env.example config/benchmark.env
set -a
. config/benchmark.env
set +a
cd Phase1  # or: cd Phase2
```

Every benchmark must record the fastPLS source identifier, installed version,
dataset and split fingerprint, precision, backend, component count, rSVD
controls, seed, output contract, timing boundary, and execution status.

## Shared checks

The repository-level checks are stored with the software phase because they
audit packaging and source ownership:

```sh
python3 -m unittest discover -s Phase2/tests -v
python3 Phase2/tools/audit_repository_boundary.py . /path/to/fastPLS
```

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

## License

Repository code is distributed under GPL-3 unless a file carries a more
specific notice. This does not grant rights to relicense third-party code.
Manuscript text, figures, and datasets require separate ownership and
redistribution review.
