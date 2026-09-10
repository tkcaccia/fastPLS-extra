# Cross-validation invariant-work benchmark

This benchmark evaluates exact work moved outside the fold-fit loop. The
current candidate derives each linear SIMPLS training-fold predictor Gram
matrix from the full-data and held-out raw cross-products, then applies the
training-fold centering and scaling algebraically. Fold assignment,
training-only preprocessing, model fitting, prediction, and scoring are
unchanged.

`run_fold_gram_ablation.R` compares the optimized and legacy paths with fixed
folds and randomized-SVD seeds. Set `FASTPLS_LIBRARY` to the library containing
the candidate package. Results should be written outside this repository.

```sh
FASTPLS_LIBRARY=/path/to/R/library \
Rscript run_fold_gram_ablation.R /path/to/output.csv
```

The environment variable `FASTPLS_CV_FOLD_GRAM_CACHE=0` is an internal
benchmark ablation only; it is not part of the public R API.
