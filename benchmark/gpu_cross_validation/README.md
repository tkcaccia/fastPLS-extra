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

Fold orchestration remains on the host. CUDA executes each fold model and its
prediction on device. Metal uses the same fixed operation-level CPU/Metal split
as ordinary fitting. Each fold currently:

1. constructs training and test row subsets on the host;
2. initializes the backend handles and reusable workspaces;
3. transfers or exposes the fold training data to the selected operations;
4. prepares the test fold for prediction; and
5. returns predictions or score paths for host-side aggregation.

Component-path prediction has an ablation mode because repeated projection of
the same test fold is avoidable. The candidate path uploads and projects the
test fold once and evaluates all requested component prefixes from the shared
scores. This optimization does not alter folds, model controls, predictions,
or public arguments.

## Cross-validation optimization target

A fully GPU-native CUDA CV engine and a fixed operation-split Metal CV engine
require reusable CV workspaces rather than a dispatch change. The target
implementation will upload or expose `X`, the response or compact labels, and
the fixed fold vector once. It will then:

- derive fold-specific sums, means, scales, cross-covariances, and, where
  useful, predictor cross-products on device;
- obtain training sufficient statistics by subtracting held-out-fold moments
  from full-data moments;
- reuse CUDA handles or Metal/CPU operation-split workspaces, random-state
  objects, and buffers across folds;
- evaluate all requested component prefixes incrementally;
- fit argmax or LDA and reduce accuracy, balanced accuracy, Q2, and RMSD on
  the backend-specific execution route; and
- return only the documented prediction/score paths and aggregate metrics.

Host-side fold construction is retained because it is negligible, deterministic,
and preserves the existing `constrain` semantics. No unsupported family may
silently fall back to CPU. Initial native support should cover PLS-SVD and
SIMPLS. OPLS requires additional fold-specific orthogonal-filter statistics,
whereas nonlinear kernel PLS requires fold-specific Gram matrices and should
remain a separately qualified route.

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

## Current audit results

The September 2026 selected-component audit used float32 inputs, ten fixed
folds, five fresh-process repetitions, and all four PLS families on 11
datasets. The Mac panel contained 880/880 successful CPU and Metal workers.
The fixed Metal operation split was not faster than the paired Mac CPU route
in these cold-process cross-validation measurements: CPU/Metal ratios ranged
from 0.214 to 0.992. This is retained as a negative result rather than hidden.
The maximum CPU/Metal accuracy difference was 2.0e-5, and the maximum relative
RMSD difference was 3.1e-6.

The operation-split cross-validation implementation still reduced work
relative to ten independently timed fits in 22 of 44 Metal cells. The analogous
counts were 11 of 44 for Mac CPU, 15 of 44 for Linux CPU, and 32 of 44 for
CUDA. These comparisons quantify complete public workflows, including
out-of-fold prediction and score assembly; they are not decomposition-only
benchmarks. Raw results and generated summaries remain outside Git.

## Usage

```sh
Rscript benchmark/gpu_cross_validation/worker.R \
  --library=/path/to/fastPLS/library \
  --task=/path/to/cifar100_task.rds \
  --output=/path/outside/git/cifar_cuda_cv.csv \
  --implementation=fused-prefix \
  --backend=cuda --precision=float32 \
  --method=simpls --classifier=argmax \
  --ncomp=10,20,50,100 --kfold=10 --seed=123
```

Summarize paired fresh-process rows with:

```sh
Rscript benchmark/gpu_cross_validation/summarize.R \
  /path/outside/git/raw.csv /path/outside/git/summary.csv
```

## Supplementary selected-component matrix

`run_selected_matrix.R` runs all four fastPLS families at component counts
already selected from training data. It executes complete cross-validation and
one matched fold fit plus prediction for every backend and fresh-process
replicate. The runner is resumable: an existing non-empty result CSV is not
overwritten.

```sh
Rscript benchmark/gpu_cross_validation/run_selected_matrix.R \
  --library=/path/to/fastPLS/library \
  --tasks=/path/to/task_objects \
  --selection=/path/to/component_selection_summary.csv \
  --output=/path/outside/git/platform_results \
  --backends=cpu,cuda \
  --repetitions=5 --kfold=10 --seed=123 \
  --precision=float32 --context-mode=cold
```

Run the same command with `--backends=cpu,metal` on Apple silicon. Combine the
platform directories and create the two supplementary figures with:

```sh
Rscript benchmark/gpu_cross_validation/summarize_selected_matrix.R \
  /path/to/linux_results /path/to/mac_results /path/to/summary
Rscript benchmark/gpu_cross_validation/plot_selected_matrix.R \
  /path/to/summary /path/to/figures
Rscript benchmark/gpu_cross_validation/audit_selected_matrix.R \
  /path/to/summary
```

The supplementary figures use cold fresh processes so first-call accelerator
context creation, transfer, and synchronization are included consistently with
the complete-workflow benchmark. The first figure reports the same-host
CPU/accelerator cross-validation runtime ratio. The second reports `(K *
one-fold fit-and-prediction time) / complete CV time`. Ratios above one favour
the accelerator in the first figure and the complete CV implementation in the
second. Held-out metrics for the standalone fold are calculated after the timed
fit-and-prediction call. Raw and summarized results remain outside this Git
repository.
The audit requires all 1,760 platform cells, checks the five-repetition
contract, confirms paired fold signatures and prediction stability, and writes
the maximum observed CPU/accelerator metric differences.

For a matched baseline/candidate ablation, use `run_matched_pair.sh`. It
alternates the two installed libraries in fresh processes to reduce timing
drift; all generated CSV files must still point outside the repository.
