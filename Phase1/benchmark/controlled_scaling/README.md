# Controlled SIMPLS scaling benchmark

This benchmark varies one dimension at a time while holding the remaining
synthetic-data parameters fixed. It measures the shape-dependent execution
claims made for fastPLS SIMPLS rather than treating heterogeneous real datasets
as a scaling experiment.

The publication profile also adds a joint-shape validation: 24 deterministic
Latin-hypercube development cases and 16 independently generated holdout cases
vary the principal dimensions together. The automatic, forced-explicit, and
forced-implicit routes are compared on every interaction case. Only the
holdout partition is used to report route-choice accuracy.

The publication profile sweeps sample count, predictor dimension, response
dimension, retained components, requested component prefixes, effective
cross-covariance rank, class count, and explicit cross-covariance size. Every
scenario is compared with a fixed-control float64 CPU-IRLBA fit generated from
the same synthetic matrices. The explicit/implicit crossover panel forces both
routes; all other panels test automatic routing.

The rank sweep uses a noise-free low-rank response so that the rank of the
population cross-covariance is controlled. Other regression sweeps add fixed
Gaussian response noise, and the class-count sweep uses labels generated from
a fixed-dimensional latent score model.

Automatic routes use the public release policy: PLS-SVD uses 32 oversampling
directions and five power iterations, ordinary SIMPLS-family problems use 32
and five, and SIMPLS-family problems whose explicit cross-covariance would
exceed 512 MiB use 12 and two. Forced explicit and implicit qualification
routes use 32 directions and five iterations. Every executed control and seed
is recorded in the raw output.

Each run uses a fresh R process. Fit and prediction time are recorded
separately. An external 20-ms sampler records process RSS and, on CUDA systems,
per-process and total GPU memory. Incremental host RSS is the sampled peak minus
RSS immediately before fitting. Numerical agreement is evaluated only after
the memory-sampling window closes, so loading the deterministic reference does
not contaminate candidate memory measurements.

Run a local smoke test:

```sh
bash scripts/run_controlled_scaling.sh \
  benchmark_results/controlled_scaling_smoke smoke cpu,metal 1
```

Run the publication CPU/CUDA grid on a CUDA host:

```sh
FASTPLS_SCALING_TIMEOUT_SEC=600 \
bash scripts/run_controlled_scaling.sh \
  benchmark_results/controlled_scaling_cuda publication cpu,cuda 3
```

Primary outputs are `controlled_scaling_raw.csv`,
`controlled_scaling_summary.csv`, `explicit_implicit_crossover.csv`,
`interaction_route_validation.csv`,
`interaction_route_validation_summary.csv`,
`failures_and_numerical_discordance.csv`, and four PDF figures. Failed and
timed-out routes remain in the raw and failure tables.

CPU runs record `cpu_profile`, the loaded BLAS library, requested threads, and
runtime-reported BLAS threads. A multithread claim is accepted only when the
optimized BLAS and active thread count are independently verified.
