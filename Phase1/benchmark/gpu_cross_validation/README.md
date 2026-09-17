# GPU cross-validation audit

This workflow measures cross-validation separately from a single fit and
prediction. Generated results are written only to a caller-supplied directory
outside this repository.

By default, a task object containing `Xtrain`/`Ytrain` and
`Xtest`/`Ytest` uses only the training partition for cross-validation.
Pass `--data-scope=all` only for an explicitly designated computational
stress test; it must not be used for training-only model selection reported
against the original test set.

The public interface is unchanged. In particular, `constrain` is converted to
one deterministic group-aware fold assignment with the package helper, and
the same assignment is used by every implementation being compared. Rows
sharing a constraint value must never occur in different folds.

## Current implementation audit

Fold assignment remains on the host because it is deterministic and preserves
the public `constrain` semantics. The compiled CPU and Metal routes calculate
eligible full-data sums, sums of squares, class sums, predictor-response
products, and predictor Gram matrices once. Fold-training quantities are then
recovered by subtracting the held-out contribution. Caches are bounded so an
extreme response matrix, such as NMR, is not duplicated merely to avoid a
matrix product.

For eligible tall SIMPLS classification tasks, the same statistics also avoid
materializing each training-fold matrix. The fold predictor Gram matrix and
class-wise predictor sums are projected through the fitted SIMPLS rotations to
obtain the score Gram matrix and class-score sums required by pooled-covariance
LDA. The existing Cholesky LDA solver is then applied to those moments. This is
an algebraic reorganization only: fold centering and scaling, model fitting,
held-out projection, class priors, and the public prediction path remain
fold-specific. The package activates this route from problem dimensions; it is
not a user-tuned modelling option.

The resident CUDA SIMPLS CV route uploads `X` and the response once, gathers
fold rows on device, and keeps standardization, model fitting, score projection,
prediction, and metric reduction on the GPU. When device memory permits,
regression CV forms the full predictor-response product once and subtracts the
held-out product for each fold. Transfers of requested public predictions and
aggregate metrics are included in elapsed time. Unsupported routes fail
explicitly rather than falling back to CPU.

Every fold fits one maximal component path and projects its test matrix once.
Requested component prefixes are evaluated from the shared latent scores.
When `classifier=argmax,lda` is supplied to the benchmark worker, the public
tuning layer fits the PLS representation once through the LDA run and derives
argmax from the retained PLS response-score path. Fold assignment, solver seed,
selected components, and classifier semantics are unchanged.

`--fold-cache=off` disables the sufficient-statistic caches only for a matched
benchmark ablation. It is not a public modelling option. The benchmark worker
uses `--fold-cache=on` by default.

Worker output contains both `prediction_signature`, a byte-exact repeatability
check, and `numerical_prediction_signature`, which rounds numeric prediction
quantities to 12 significant digits before hashing. Use the latter for cache
ablations whose mathematically equivalent accumulation order may differ at
floating-point roundoff; retain the former for repeated runs of one unchanged
route.

## Study design

Run at least five fresh-process repetitions after one unreported warm-up. Use
the same task object, precision, folds, seed, component path, classifier, and
rSVD controls for each paired comparison. The panel should include:

- a small classification task (MetRef);
- medium/large low-predictor tasks (Retina and Tabula Muris);
- a high-sample image-embedding task (CIFAR-100);
- extreme multivariate regression (NMR); and
- synthetic shape controls varying `n`, `p`, `q`, and component-path length.

Report total CV time, one-fit-plus-prediction time, median and IQR, absolute and
incremental host RSS, baseline-corrected device memory, selected component,
metric difference, prediction agreement or relative prediction error, number
of accelerator contexts, and estimated host/device bytes. Cold-context and
steady-state measurements must be shown separately.

The worker labels a fresh process as `--context-mode=cold`. With
`--context-mode=warm`, it performs one unreported complete CV run in the same
process before timing. Fold and prediction fingerprints are recorded to verify
paired numerical identity.

`--workload=cv` measures the complete public cross-validation call.
`--workload=one_fold` measures one fit and prediction using the first
precomputed held-out fold, allowing the CV multiplier to be reported without
changing fold construction or group constraints.

## Validation outputs

Complete cross-validation timings include construction of the documented
out-of-fold predictions and scores. They must therefore be distinguished from
decomposition-only and compact-output profiling controls. Raw rows, logs,
generated summaries, figures, and tables remain outside this repository.

The final two-dataset runner compares automatic and cache-disabled execution
on identical folds and also records a one-fold baseline. It covers PLS-SVD and
SIMPLS on CIFAR-100 and NMR, accepts a comma-separated backend list, and writes
all generated rows, logs, and summaries to `FASTPLS_CV_OUTPUT`, which must be
outside this repository.

## Usage

```sh
Rscript benchmark/gpu_cross_validation/worker.R \
  --library=/path/to/fastPLS/library \
  --task=/path/to/cifar100_task.rds \
  --output=/path/outside/git/cifar_cuda_cv.csv \
  --implementation=fused-prefix \
  --backend=cuda --precision=float32 \
  --method=simpls --classifier=argmax,lda \
  --ncomp=10,20,50,100 --kfold=10 --seed=123
```

To separate compiled fitting, prediction, and metric reduction from the cost
of constructing the documented public prediction object, run:

```sh
Rscript benchmark/gpu_cross_validation/compact_cv_worker.R \
  --library=/path/to/fastPLS/library \
  --task=/path/to/nmr_task.rds \
  --output=/path/outside/git/nmr_compact_cv.csv \
  --backend=cuda --precision=float32 \
  --method=simpls --ncomp=25,50,75,100 --kfold=10 --seed=123
```

This worker sets `store_predictions=FALSE` only on the internal compiled CV
entry point. It is a profiling control, not an alternative public API, and its
rows must not be mixed with complete public-workflow timings.

For an extreme multivariate regression response, use the bounded-memory result
worker instead of serializing the complete CV object for a fingerprint:

```sh
Rscript benchmark/gpu_cross_validation/large_regression_worker.R \
  --library=/path/to/fastPLS/library \
  --task=/path/to/nmr_task.rds \
  --output=/path/outside/git/nmr_cv.csv \
  --backend=cuda --precision=float32 \
  --method=simpls --ncomp=50 --kfold=10 --seed=123
```

The worker retains the complete public CV computation but records only bounded
metadata and a deterministic 4,096-value prediction sample. This avoids a
second full serialization of very large prediction arrays. Generated results
must remain outside this repository.

Summarize paired fresh-process rows with:

```sh
Rscript benchmark/gpu_cross_validation/summarize.R \
  /path/outside/git/raw.csv /path/outside/git/summary.csv
```

## Supplementary selected-component matrix

`run_selected_matrix.R` runs all four fastPLS families at component counts
already selected from training data. It executes complete cross-validation and
one full-training fit plus prediction on the fixed test partition for every
backend and fresh-process replicate. This direct comparison must not be
confused with the older `K * one-fold fit` diagnostic. The runner is resumable:
an existing non-empty result CSV is not overwritten.
For classification, the selected-component matrix uses the LDA prediction
head for both complete cross-validation and the matched full-training fit plus
fixed-test prediction. The prediction call retains the class-score output
needed to keep the two timed workflows comparable. Regression continues to
use continuous predictions.

```sh
Rscript benchmark/gpu_cross_validation/run_selected_matrix.R \
  --library=/path/to/fastPLS/library \
  --tasks=/path/to/task_objects \
  --selection=benchmark/gpu_cross_validation/selected_component_contract.csv \
  --output=/path/outside/git/platform_results \
  --backends=cpu,cuda \
  --repetitions=5 --kfold=10 --seed=123 \
  --precision=float32 --context-mode=cold
```

On the 8-GiB Apple-silicon benchmark host, exclude ImageNet explicitly rather
than attempting an out-of-fold score object that exceeds available memory:

```sh
Rscript benchmark/gpu_cross_validation/run_selected_matrix.R \
  --library=/path/to/fastPLS/library \
  --tasks=/path/to/task_objects \
  --selection=benchmark/gpu_cross_validation/selected_component_contract.csv \
  --output=/path/outside/git/macos_results \
  --backends=cpu,metal --exclude-datasets=imagenet \
  --repetitions=5 --kfold=10 --seed=123 \
  --precision=float32 --context-mode=cold
```

NMR and ImageNet can be supplied without copying their large task objects into
the ordinary task directory by adding `--nmr-task=/path/to/nmr_task.rds` and
`--imagenet-task=/path/to/imagenet_task.rds`.

Run the same command with `--backends=cpu,metal` on Apple silicon. Combine the
platform directories and create the three supplementary figures with:

```sh
Rscript benchmark/gpu_cross_validation/summarize_selected_matrix.R \
  /path/to/linux_results /path/to/mac_results /path/to/summary
Rscript benchmark/gpu_cross_validation/plot_selected_matrix.R \
  /path/to/summary /path/to/figures
Rscript benchmark/gpu_cross_validation/audit_selected_matrix.R \
  /path/to/summary
```

For the CMPB Figure 2C-D Linux CPU/CUDA protocol, run
`audit_figure2_cv_lda.R` on the summary directory. This focused audit requires
LDA for every classification row, continuous RMSD for regression, identical
folds across paired methods and backends, five successful fresh processes per
ordinary cell, and one successful exploratory ImageNet process.

The supplementary figures use cold fresh processes so first-call accelerator
context creation, transfer, and synchronization are included consistently with
the complete-workflow benchmark. The first figure reports the same-host
CPU/accelerator cross-validation runtime ratio. The second reports `complete
ten-fold CV time / one full-training fit plus fixed-test prediction time`.
An additional efficiency figure reports `complete ten-fold CV time /
(10 * one full-training fit plus fixed-test prediction time)` so the compiled
CV workflow is compared directly with ten repeated public workflows.
Ratios above one favour the accelerator in the first figure; in the
second they show the complete multiplicative cost of CV, including documented
out-of-fold predictions and scores. Raw and summarized results remain outside
this Git repository. In the CV-versus-fit figure, white marks the expected
ten-fit reference at 10x, blue denotes ratios below 10x, and red denotes ratios
above 10x.
The audit requires all 2,000 feasible platform cells: all 13 datasets on the
Linux/NVIDIA workstation and 12 datasets on the 8-GiB Mac. ImageNet is retained
as an explicit `NE` cell on the Mac because the public 1,000-component
out-of-fold score output exceeds that workstation's memory budget. The audit
checks the five-repetition contract, paired fold signatures, prediction
stability, and maximum CPU/accelerator metric differences.

For a matched baseline/candidate ablation, use `run_matched_pair.sh`. It
alternates the two installed libraries in fresh processes to reduce timing
drift; all generated CSV files must still point outside the repository.
