# fastPLS CPU thread-scaling benchmark

This benchmark measures fastPLS 0.99.39 SIMPLS/rSVD fitting and held-out
prediction with one, two, and four active OpenBLAS threads. Each workload is
run five times in a fresh R process. A direct OpenBLAS probe verifies the
active thread count before each fit; the benchmark stops rather than reporting
a requested count that was not activated.

The three controlled workloads isolate sample-rich classification,
predictor-wide regression, and response-wide regression. Data generation,
fit seeds, component counts, precision, and predictions are fixed across
thread counts. The output reports median and interquartile runtime, speed-up,
parallel efficiency, predictive metric, and prediction agreement.

Run from the package root after installing the OpenBLAS-linked package:

```sh
OPENBLAS_NUM_THREADS=1 ./scripts/install_fastest_openblas.sh
./benchmark/multicore_scaling/run.sh
```

Results are written to
`publication_results/0.99.39/current_release/multicore_scaling/`.
