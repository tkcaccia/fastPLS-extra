# Selected-workload float32 versus float64 benchmark

This benchmark compares float32 and float64 execution without changing the
dataset split, requested component count, model family, prediction head,
randomized-SVD controls, seed, output contract, or CPU thread count used for
the current Figure 2 workloads.

The paired routes are Linux CPU, Linux CUDA, and macOS CPU. Metal is not
included because the public Metal route does not support float64. Each cell is
measured in three fresh processes. Input conversion occurs before the monitored
fit-and-prediction boundary.

`run_float64_platform.sh` runs the missing float64 measurements.
`build_figures.R` combines those measurements with the matching current-release
float32 evidence and generates the runtime and absolute peak process-RSS ratio
figures. Raw results must be written outside this Git checkout.

