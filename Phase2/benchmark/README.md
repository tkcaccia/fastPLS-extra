# JSS software benchmarks

Run these workflows from `fastPLS-extra/Phase2` after loading
`../config/benchmark.env` from the repository root. This phase examines the
software implementation and interfaces; it does not reproduce the CMPB
independent-package comparison.

The subdirectories cover multicore scaling, precision, Metal and native GPU
execution, compiled cross-validation, response-Gram kernels, shared-core
migration, and compiled LDA. Each workflow must write generated evidence
outside the repository and retain the source identifier, toolchain, numerical
library, thread count, precision, backend, and timing boundary.

See [`../MANIFEST.csv`](../MANIFEST.csv) for the planned JSS evidence map.
