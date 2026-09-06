# Workflow launchers

These launchers orchestrate the benchmark runners in `../benchmark`. They do
not contain package implementation code and must not write generated evidence
inside either Git checkout.

Before a local run, load `../config/benchmark.env` created from
`../config/benchmark.env.example`. Remote launchers additionally require an
explicit remote source directory, installed package library, data root, and
results root. A launcher must keep CPU and accelerator timing panels isolated;
concurrent GPU workloads invalidate timing comparisons.

Current entry points are listed in `../benchmark/MANIFEST.csv`. Obsolete
manuscript-assembly utilities are isolated in `../archive/` and are not current
evidence generators.

`run_candidate_nmr_cuda.sh` is the current isolated CUDA launcher for matched
PLS-SVD and SIMPLS NMR runs in float32 and float64 at 50 and 165 components.
It requires every source, input, library, and output root explicitly and skips
only complete result files.
