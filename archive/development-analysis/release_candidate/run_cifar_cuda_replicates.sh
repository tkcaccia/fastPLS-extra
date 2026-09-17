#!/usr/bin/env bash
set -euo pipefail

TASK=${1:?CIFAR-100 task RDS required}
LIBRARY=${2:?installed fastPLS library required}
WORKER=${3:?fastPLS benchmark worker required}
OUTPUT=${4:?output directory required}
REPLICATES=${5:-11}

mkdir -p "$OUTPUT"
export FASTPLS_BENCH_NCOMP=50
export FASTPLS_BENCH_OVERSAMPLE=32
export FASTPLS_BENCH_POWER=5
export FASTPLS_BENCH_SEED=123
export FASTPLS_BENCH_PRECISION=float32

for replicate in $(seq 1 "$REPLICATES"); do
    Rscript "$WORKER" \
        "$TASK" "$LIBRARY" cuda "$replicate" \
        "$OUTPUT/cuda_r${replicate}.csv"
done

Rscript - "$OUTPUT" <<'RSCRIPT'
args <- commandArgs(trailingOnly = TRUE)
files <- list.files(
  args[[1L]],
  pattern = "^cuda_r[0-9]+[.]csv$",
  full.names = TRUE
)
results <- do.call(rbind, lapply(files, read.csv))
summary <- data.frame(
  backend = "cuda",
  repetitions = nrow(results),
  median_fit_sec = median(results$fit_sec),
  iqr_fit_sec = IQR(results$fit_sec),
  median_prediction_sec = median(results$prediction_sec),
  iqr_prediction_sec = IQR(results$prediction_sec),
  median_total_sec = median(results$total_sec),
  iqr_total_sec = IQR(results$total_sec),
  accuracy = unique(results$accuracy)
)
write.csv(results, file.path(args[[1L]], "raw.csv"), row.names = FALSE)
write.csv(summary, file.path(args[[1L]], "summary.csv"), row.names = FALSE)
print(summary, row.names = FALSE)
RSCRIPT
