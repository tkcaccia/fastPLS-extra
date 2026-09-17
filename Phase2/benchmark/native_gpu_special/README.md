# Native GPU OPLS and nonlinear kernel PLS

This directory validates the fully resident CUDA and Metal implementations of
OPLS and nonlinear kernel PLS. Fitting, OPLS filtering, nonlinear Gram-matrix
construction and centering, randomized decomposition, prediction, and optional
LDA remain on the requested device. R orchestrates calls and assembles returned
summaries; unavailable routes raise errors instead of falling back to CPU.

`validate_cuda.R` and `validate_metal.R` compare focused regression and
classification cases with precision-matched CPU models. `real_dataset_worker.R`
runs one isolated real-data case and records its execution status. Generated
CSV files belong in a local results directory outside this repository.

Nonlinear kernel PLS necessarily materializes an `n x n` Gram matrix. The
resident implementations reject workloads whose estimated live device storage
is unsafe. This is a mathematical storage limit of the tested formulation, not
a reason to substitute linear PLS or CPU execution.
