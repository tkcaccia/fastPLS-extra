# Metal operation-split benchmark

The public `backend = "metal"` route is a fixed mathematical partition, not a
dataset-level backend selector. Persistent Metal workspaces evaluate fitting
products involving the training sample matrix. CPU code performs centering and scaling, reduced
factorizations, sequential PLS orthogonalization and deflation, coefficient
updates, prediction, classification, and R output assembly. No complete CPU
route is selected from the dimensions of a dataset.

Use the release-evidence driver to compare this route with the CPU backend for
PLS-SVD, SIMPLS, OPLS, and kernel PLS:

```sh
python3 benchmark/current_release_evidence/run_selected_backends.py \
  --library /path/to/installed/fastPLS/library \
  --task-dir /path/to/prepared/tasks \
  --selected /path/to/training-selected-components.csv \
  --output /path/outside/this/repository/metal_selected.csv \
  --backends cpu metal \
  --precision float32 \
  --repetitions 3 \
  --source-id release-source-id
```

Input conversion occurs before the timer starts. Every worker is a fresh R
process, so timings include first-use Metal setup. The driver records fitting
and held-out prediction separately, monitors process memory from a pre-fit
baseline, stores the execution route and effective rSVD controls, and writes
results only to the caller-supplied location outside the repository.

The selected-component manifest must be produced from training data only and
contain `dataset`, `family`, and `selected_ncomp`. Runtime ratios are
interpretable only together with the paired predictive metric and execution
status.
