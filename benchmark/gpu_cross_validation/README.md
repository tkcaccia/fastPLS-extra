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

The current CUDA and Metal routes execute each fold model and its prediction on
the requested accelerator, but fold orchestration remains on the host. Each
fold currently:

1. constructs training and test row subsets on the host;
2. creates a new resident accelerator model and its handles/workspaces;
3. transfers the fold training data;
4. transfers the test fold for prediction; and
5. returns predictions or score paths for host-side aggregation.

Component-path prediction has an ablation mode because repeated projection of
the same test fold is avoidable. The candidate path uploads and projects the
test fold once and evaluates all requested component prefixes from the shared
scores. This optimization does not alter folds, model controls, predictions,
or public arguments.

## Fully native target

A fully GPU-native CV engine is feasible, but requires a reusable CV workspace
rather than a dispatch change. The target implementation will upload `X`, the
response or compact labels, and the fixed fold vector once. It will then:

- derive fold-specific sums, means, scales, cross-covariances, and, where
  useful, predictor cross-products on device;
- obtain training sufficient statistics by subtracting held-out-fold moments
  from full-data moments;
- reuse CUDA or Metal handles, random-state objects, and workspaces across
  folds;
- evaluate all requested component prefixes incrementally;
- fit argmax or LDA and reduce accuracy, balanced accuracy, Q2, and RMSD on
  device; and
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

The September 2026 audit used float32 SIMPLS-rSVD, ten folds, fixed fold
assignments, and the public score-returning contract. Results remain outside
Git and are summarized here only to document the benchmark interpretation.

| Dataset | Backend | Complete CV (s) | One fold (s) | CV / one fold | Same-host CPU / accelerator |
|---|---:|---:|---:|---:|---:|
| MetRef | CUDA | 0.557 | 0.260 | 2.14 | 0.60 |
| Retina | CUDA | 1.784 | 0.276 | 6.46 | 1.07 |
| CIFAR-100 | CUDA | 8.115 | 0.358 | 22.67 | 5.59 |
| NMR | CUDA | 44.553 | 2.539 | 17.55 | 1.94 |
| MetRef | Metal | 0.681 | 0.112 | 6.08 | not measured |
| Retina | Metal | 2.376 | 0.173 | 13.73 | 0.72 |
| CIFAR-100 | Metal | 12.519 | 0.604 | 20.73 | 0.78 |
| NMR | Metal | 61.513 | 3.368 | 18.26 | not measured |

NMR is a single guarded feasibility probe; the other rows use three to seven
fresh processes. NMR response metrics must not be compared between computers
unless the same task object and preprocessing fingerprint are confirmed.

Reusing one test-fold projection for every requested component prefix reduced
Metal CV time by 23-24% in the grouped synthetic audit. CUDA gained 0-3%, which
shows that repeated fold setup, allocation, and transfers dominate the
remaining CUDA overhead. CUDA float32 predictions agreed with the original
path to tolerance: score correlation was 1.0, relative score error was
4.83e-5, LDA label agreement was 1.0, and argmax label agreement was 0.99972.
The Metal audit produced identical fingerprints and metrics.

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

For a matched baseline/candidate ablation, use `run_matched_pair.sh`. It
alternates the two installed libraries in fresh processes to reduce timing
drift; all generated CSV files must still point outside the repository.
