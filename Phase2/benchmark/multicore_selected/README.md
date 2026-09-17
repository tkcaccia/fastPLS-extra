# Selected-workload CPU multicore benchmark

This benchmark compares one and four requested CPU cores on the same 13
float32 family-dataset workloads used for Figure 2. It includes PLS-SVD,
SIMPLS, OPLS and linear kernel PLS. Classification uses argmax so that the
thread comparison isolates the PLS route; regression uses continuous
prediction. Component counts, rSVD automatic controls, seed, preprocessing and
returned outputs are unchanged between the paired runs.

Each cell is measured in three fresh R processes. Total time includes fitting
and held-out prediction. Absolute peak process RSS includes the R runtime,
loaded data, linked numerical libraries, model fitting and prediction. The
runtime ratio is one-core time divided by four-core time; values above one
favour four cores. The memory ratio is four-core peak RSS divided by one-core
peak RSS; values below one favour four cores.

Linux runs require the OpenBLAS-linked package build used for the publication
benchmarks. macOS runs use Apple Accelerate. `run_platform.sh` records the
compiled numerical-library provider and requests the thread count both through
the process environment and the public `options(n.cores=...)` mechanism.

Results must be written outside the Git checkout. The script never changes a
model parameter in response to timing results.
