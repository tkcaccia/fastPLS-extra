#!/usr/bin/env bash
set -euo pipefail

TASK=${1:?task RDS required}
BASELINE_LIBRARY=${2:?baseline R library required}
CANDIDATE_LIBRARY=${3:?candidate R library required}
WORKER=${4:?benchmark worker required}
OUTPUT=${5:?output directory required}
REPETITIONS=${FASTPLS_BENCH_REPETITIONS:-11}
BACKEND=${FASTPLS_BENCH_BACKEND:-cpu}

mkdir -p "$OUTPUT/baseline" "$OUTPUT/candidate"
for replicate in $(seq 1 "$REPETITIONS"); do
  Rscript "$WORKER" "$TASK" "$BASELINE_LIBRARY" "$BACKEND" \
    "$replicate" "$OUTPUT/baseline/r${replicate}.csv"
  Rscript "$WORKER" "$TASK" "$CANDIDATE_LIBRARY" "$BACKEND" \
    "$replicate" "$OUTPUT/candidate/r${replicate}.csv"
done

Rscript - "$OUTPUT" <<'RSCRIPT'
args <- commandArgs(trailingOnly = TRUE)
read_group <- function(group) {
  files <- list.files(
    file.path(args[[1L]], group), pattern = "^r[0-9]+[.]csv$",
    full.names = TRUE
  )
  data <- do.call(rbind, lapply(files, utils::read.csv))
  data$implementation <- group
  data
}
raw <- rbind(read_group("baseline"), read_group("candidate"))
summary <- do.call(rbind, lapply(split(raw, raw$implementation), function(x) {
  data.frame(
    implementation = x$implementation[[1L]],
    repetitions = nrow(x),
    fit_median_sec = median(x$fit_sec),
    fit_iqr_sec = IQR(x$fit_sec),
    prediction_median_sec = median(x$prediction_sec),
    total_median_sec = median(x$total_sec),
    total_iqr_sec = IQR(x$total_sec),
    accuracy = median(x$accuracy),
    checksum_min = min(x$prediction_checksum),
    checksum_max = max(x$prediction_checksum)
  )
}))
utils::write.csv(raw, file.path(args[[1L]], "raw.csv"), row.names = FALSE)
utils::write.csv(
  summary, file.path(args[[1L]], "summary.csv"), row.names = FALSE
)
print(summary, row.names = FALSE)
RSCRIPT
