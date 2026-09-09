# MIT core migration checks

These scripts validate the dependency-free `fastPLS` core and its R package
adapters without storing benchmark results in the package repository.

## All-family smoke matrix

`smoke_all_families.R` exercises PLS-SVD, SIMPLS, OPLS, nonlinear kernel PLS,
regression, classification, and LDA for the requested backends and precisions.

```sh
Rscript smoke_all_families.R LIBRARY OUTPUT_CSV cpu,metal
Rscript smoke_all_families.R LIBRARY OUTPUT_CSV cpu,cuda
```

Unsupported routes must return an informative error; they must not silently
fall back to CPU.

## CIFAR-100 benchmark

`cifar_worker.R` performs one fresh-process SIMPLS/rSVD fit and held-out
prediction at 50 components. `run_cifar_replicates.sh` repeats the worker and
adds a replicate identifier to a local CSV result.

```sh
./run_cifar_replicates.sh \
    LIBRARY TASK_RDS cpu float32 11 /tmp/cifar-cpu.csv
```

The input object must contain `Xtrain`, `Ytrain`, `Xtest`, and `Ytest`. Keep raw
benchmark outputs outside `tkcaccia/fastPLS`; publish them only with a frozen
release in the dedicated results archive.
