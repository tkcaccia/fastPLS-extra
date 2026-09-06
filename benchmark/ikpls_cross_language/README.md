# IKPLS cross-language benchmark

This benchmark separates two different questions:

1. `benchmark_simpls_estimator_preservation.R` tests the deterministic de Jong
   SIMPLS numerical kernel against `pls::simpls.fit`.
2. This directory compares complete prediction workflows against the independent
   Python `ikpls` package. IKPLS implements Dayal-MacGregor Improved Kernel PLS,
   so this is deliberately labelled an end-to-end software comparison rather
   than an estimator-equivalence test.

The repeated small- and medium-dataset comparison uses float64 matrices,
training-derived column centering applied once before either implementation,
identical one-hot responses, identical component counts and splits, and final
test prediction as the common requested output. Each method runs three times
in a fresh process with one CPU thread. Fit time, prediction time,
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

The Python worker requires `ikpls==6.1.2`, NumPy, pandas, and psutil. The R
worker requires the reviewed fastPLS release installed in the library selected
by `R_LIBS`.

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
