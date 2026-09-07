# Independent Python PLS benchmark

This benchmark separates two different questions:

1. `benchmark_simpls_estimator_preservation.R` tests the deterministic de Jong
   SIMPLS numerical kernel against `pls::simpls.fit`.
2. This directory compares complete prediction workflows against independent
   Python implementations: IKPLS, the compiled `pls4all` binding from
   nirs4all-methods, and scikit-learn `PLSRegression`. These packages implement
   different PLS estimators and retain different fitted objects, so the panel is
   deliberately labelled an end-to-end software comparison rather than an
   estimator-equivalence test.

The repeated small- and medium-dataset comparison uses matched matrices,
identical one-hot responses, identical component counts and splits, and final
test prediction as the common requested output. Each method runs for the
configured repetition count in a fresh process with one CPU thread. Fit time,
prediction time,
complete-process peak RSS, baseline-corrected peak RSS, and accuracy are
retained. The fastPLS rSVD row uses the release-qualified CPU/CUDA controls
(32 oversampling directions, five power iterations, seed 123) and remains labelled
approximate rather than estimator matched.

Run from the repository root:

```sh
FASTPLS_BENCH_LIB=/path/to/current/library \
python3 benchmark/ikpls_cross_language/run_benchmark.py /path/to/results
```

The runner gives `FASTPLS_BENCH_LIB` precedence over its temporary-library
default so that every row is generated with the installed current release.

The tested Python environment is pinned in `requirements.txt`; it contains
IKPLS 6.1.2, pls4all 1.0.18, scikit-learn 1.7.2 and the supporting numerical
packages. The R worker requires the reviewed fastPLS release installed in the
library selected by `R_LIBS`.

`worker_ikpls_jax.py` provides a separately labelled CUDA comparison. It records
host-to-device transfers, cold JIT compilation plus execution, steady-state execution,
device prediction, and result transfer separately. This prevents JAX compilation
timings from being compared incorrectly with a first public fastPLS call.

## Large-case float32 feasibility extension

The NMR and ImageNet extension intentionally uses float32 because a matched
float64 experiment exceeds the available memory. It uses public IKPLS 6.1.2
NumPy cross-product execution with one CPU thread. This remains a software
feasibility comparison: Improved Kernel PLS and de Jong SIMPLS are different
estimators and retain different internal objects.

Prepare NMR from an authorized RData file:

```sh
Rscript benchmark/ikpls_cross_language/export_large_float32.R \
  nmr /path/to/NMR.RData /path/to/prepared/nmr
```

Prepare ImageNet from the existing task descriptor and float-package matrices:

```sh
Rscript benchmark/ikpls_cross_language/export_large_float32.R \
  imagenet /path/to/imagenet_task.rds /path/to/prepared/imagenet
python3 benchmark/ikpls_cross_language/prepare_imagenet_float32.py \
  /path/to/prepared/imagenet
```

Run every reported component count. The default 10-GiB NMR address-space guard
prevents a structurally infeasible coefficient path from exhausting the host:

```sh
python3 benchmark/ikpls_cross_language/run_large_float32.py \
  --data-root /path/to/prepared \
  --results /path/to/results

python3 benchmark/ikpls_cross_language/summarize_large_float32.py \
  /path/to/results \
  --fastpls-imagenet /path/to/imagenet_all_results.csv
```

Conversion and centering are outside model timing. ImageNet preprocessing time
is stored separately, prediction is blocked, and each raw configuration CSV
records fitting time, prediction time, accuracy, peak process RSS, component
count, coefficient-tensor size, status, and failure text. The reported NMR
50-component tensor size is analytical: `50 * 13000 * 28355 * 4` bytes, or
68.66 GiB, before other arrays and runtime overhead.

The generated large-case table contains the current-release results used in
the manuscript. These are single-run feasibility measurements, not timing
uncertainty estimates.

## nirs4all-methods and scikit-learn panel

`worker_python_pls_panel.py` applies both the default SIMPLS and
`randomized-svd` solvers from nirs4all-methods through the published
`pls4all.sklearn.PLSRegression` binding, and applies scikit-learn
`PLSRegression` to the same exported splits. These routes use their native
float64 arithmetic, one effective CPU thread, the same component count, no
predictor or response scaling, and final held-out prediction as the common
endpoint. Classification uses the same dummy response and argmax decoding as
the IKPLS workflow. The nirs4all-methods PLS-LDA facade is not benchmarked
because version 1.0.18 supports only in-sample predictions for that estimator.

```sh
python3 benchmark/ikpls_cross_language/run_python_pls_panel.py \
  --inputs /path/to/inputs \
  --results /path/to/python_pls_results
```

The worker uses the versions in `requirements.txt`. Failures, timeouts, native
precision, package version, fitting time, prediction time, complete-process
peak RSS, accuracy or regression metrics are retained. Each runner also writes
`python_pls_environment.tsv` with the Python, package, platform and thread
contract used for that result directory.

The guarded large-case runner applies these independent Python workflows to
the prepared NMR and ImageNet stress-test objects. Its default is one isolated
feasibility run at the component count used by the current comparison;
failures, timeouts, numerical warnings, and memory-limit exits are retained.

```sh
python3 benchmark/ikpls_cross_language/run_python_pls_large.py \
  --data-root /path/to/prepared/large/data \
  --results /path/to/local/results/python_pls_large \
  --nmr-components 50 \
  --imagenet-components 100 \
  --memory-limit-gib 24 \
  --timeout 10000
```

Separate result directories, for example a repeated short-task run and a
single-run long-task extension, can be combined without refitting:

```sh
python3 benchmark/ikpls_cross_language/summarize_python_pls_panel.py \
  --rows /path/to/default_solver_results /path/to/randomized_solver_results \
  --output /path/to/combined_python_pls_results

python3 benchmark/ikpls_cross_language/summarize_python_pls_large.py \
  --rows /path/to/nmr_results /path/to/imagenet_results \
  --output /path/to/combined_python_pls_large.csv
```

## Complete selected-component panel

`export_panel_float32.R`, `worker_ikpls_panel.py`, and `run_panel.py` evaluate
IKPLS algorithm 2 on every standard benchmark task at the SIMPLS component
count selected from training data. Inputs are converted to float32 before the
timed workers start. Training-derived centering is included in fitting and
held-out prediction time. Classification tasks report accuracy, balanced
accuracy, top-5 accuracy where defined, and exact correct/test counts;
regression tasks report RMSD, Q2, and MAE. Ten isolated one-thread repetitions
are used by default, and failures remain in the status table.

```sh
Rscript benchmark/ikpls_cross_language/export_panel_float32.R \
  /path/to/tasks /path/to/selected_components.csv /path/to/inputs

PYTHONPATH=/path/to/ikpls-6.1.2 \
python3 benchmark/ikpls_cross_language/run_panel.py \
  --inputs /path/to/inputs --results /path/to/results
```
