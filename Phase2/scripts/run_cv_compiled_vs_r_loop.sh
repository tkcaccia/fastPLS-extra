#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${FASTPLS_BENCH_LIB:?Set FASTPLS_BENCH_LIB to the installed candidate library}"
: "${FASTPLS_DATA_ROOT:?Set FASTPLS_DATA_ROOT to the prepared task directory}"
: "${FASTPLS_SELECTED_COMPONENTS_CSV:?Set FASTPLS_SELECTED_COMPONENTS_CSV}"
: "${FASTPLS_RESULTS_ROOT:?Set FASTPLS_RESULTS_ROOT outside the Git checkouts}"
FASTPLS_LIB="${FASTPLS_BENCH_LIB}"
TASK_ROOT="${FASTPLS_CV_TASK_ROOT:-${FASTPLS_DATA_ROOT}}"
SELECTED_COMPONENTS="${FASTPLS_SELECTED_COMPONENTS_CSV}"
OUT_DIR="${FASTPLS_CV_COMPARATOR_OUT:-${FASTPLS_RESULTS_ROOT}/cv_compiled_vs_r_loop}"
DATASETS="${FASTPLS_CV_DATASETS:-cbmc_citeseq,ccle,cifar100,gtex_v8,metref,prism,retina,tabula,tcga_brca,tcga_hnsc_methylation,tcga_pan_cancer}"
BACKENDS="${FASTPLS_CV_BACKENDS:-cpu}"
REPETITIONS="${FASTPLS_CV_REPETITIONS:-3}"
KFOLD="${FASTPLS_CV_KFOLD:-10}"
TIMEOUT_SEC="${FASTPLS_CV_TIMEOUT_SEC:-10000}"
EXPECTED_VERSION="${FASTPLS_CV_EXPECTED_VERSION:-0.99.39}"
TIMEOUT_BIN="${TIMEOUT_BIN:-timeout}"
if ! command -v "${TIMEOUT_BIN}" >/dev/null 2>&1; then
  if command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_BIN="gtimeout"
  else
    TIMEOUT_BIN=""
  fi
fi

if [ ! -d "${FASTPLS_LIB}" ]; then
  echo "fastPLS library does not exist: ${FASTPLS_LIB}" >&2
  exit 1
fi
if [ ! -d "${TASK_ROOT}" ]; then
  echo "Task directory does not exist: ${TASK_ROOT}" >&2
  exit 1
fi
if [ ! -s "${SELECTED_COMPONENTS}" ]; then
  echo "Selected-component manifest does not exist: ${SELECTED_COMPONENTS}" >&2
  exit 1
fi

actual_version="$(FASTPLS_BENCH_LIB="${FASTPLS_LIB}" Rscript -e '
  .libPaths(unique(c(Sys.getenv("FASTPLS_BENCH_LIB"), .libPaths())))
  cat(as.character(packageVersion("fastPLS")))
')"
if [ "${actual_version}" != "${EXPECTED_VERSION}" ]; then
  echo "Expected fastPLS ${EXPECTED_VERSION}, loaded ${actual_version}." >&2
  exit 1
fi

mkdir -p "${OUT_DIR}/rows" "${OUT_DIR}/logs"

selected_ncomp() {
  Rscript - "${SELECTED_COMPONENTS}" "$1" <<'RS'
args <- commandArgs(TRUE)
d <- read.csv(args[[1L]], stringsAsFactors = FALSE)
dataset <- args[[2L]]
family_col <- if ("family" %in% names(d)) "family" else "method"
ncomp_col <- if ("selected_ncomp" %in% names(d)) "selected_ncomp" else "ncomp"
hit <- d[
  tolower(d$dataset) == tolower(dataset) &
    tolower(d[[family_col]]) == "simpls",
  ncomp_col,
  drop = TRUE
]
if (length(hit) != 1L || !is.finite(hit) || hit < 1L) {
  stop("Missing one valid SIMPLS component count for ", dataset,
       call. = FALSE)
}
cat(as.integer(hit))
RS
}

task_type() {
  Rscript - "$1" <<'RS'
task <- readRDS(commandArgs(TRUE)[[1L]])
cat(if (is.factor(task$Ytrain) || is.character(task$Ytrain)) {
  "classification"
} else {
  "regression"
})
RS
}

write_failed_row() {
  local row="$1"
  local dataset="$2"
  local backend="$3"
  local classifier="$4"
  local ncomp="$5"
  local replicate="$6"
  local status="$7"
  local message="$8"
  Rscript - "${row}" "${EXPECTED_VERSION}" "${dataset}" "${backend}" \
    "${classifier}" "${ncomp}" "${KFOLD}" "${replicate}" "${status}" \
    "${message}" <<'RS'
args <- commandArgs(TRUE)
dir.create(dirname(args[[1L]]), recursive = TRUE, showWarnings = FALSE)
write.csv(data.frame(
  package_version = args[[2L]], dataset = args[[3L]], task_type = NA_character_,
  n = NA_integer_, p = NA_integer_, q = NA_integer_, method = "simpls",
  backend = args[[4L]], svd_method = "rsvd", classifier = args[[5L]],
  ncomp = as.integer(args[[6L]]), kfold = as.integer(args[[7L]]),
  replicate = as.integer(args[[8L]]), control_profile = NA_character_,
  oversample = NA_integer_, power = NA_integer_, seed = 123L,
  compiled_sec = NA_real_, r_loop_sec = NA_real_,
  r_loop_over_compiled = NA_real_, metric_name = NA_character_,
  compiled_metric = NA_real_, r_loop_metric = NA_real_,
  metric_abs_diff = NA_real_, prediction_agreement = NA_real_,
  prediction_correlation = NA_real_, prediction_relative_error = NA_real_,
  identical_fold_partition = NA, status = args[[9L]], error = args[[10L]],
  stringsAsFactors = FALSE
), args[[1L]], row.names = FALSE)
RS
}

for dataset in $(printf '%s' "${DATASETS}" | tr ',' ' '); do
  task="${TASK_ROOT}/${dataset}_task.rds"
  if [ ! -s "${task}" ]; then
    echo "Missing task: ${task}" >&2
    exit 1
  fi
  ncomp="$(selected_ncomp "${dataset}")"
  type="$(task_type "${task}")"
  classifiers="argmax"
  if [ "${type}" = "classification" ]; then classifiers="argmax lda"; fi
  for backend in $(printf '%s' "${BACKENDS}" | tr ',' ' '); do
    for classifier in ${classifiers}; do
      for replicate in $(seq 1 "${REPETITIONS}"); do
        id="${dataset}__simpls__${backend}__${classifier}__rep${replicate}"
        row="${OUT_DIR}/rows/${id}.csv"
        log="${OUT_DIR}/logs/${id}.log"
        if [ -s "${row}" ]; then
          echo "[SKIP] ${id}"
          continue
        fi
        echo "[RUN] ${id} ncomp=${ncomp}"
        worker_command=(
          Rscript "${REPO_ROOT}/benchmark/benchmark_cv_compiled_vs_r_loop.R"
          --task="${task}" --output="${row}" --dataset="${dataset}"
          --method=simpls --backend="${backend}" --svd_method=rsvd
          --classifier="${classifier}" --ncomp="${ncomp}"
          --kfold="${KFOLD}" --replicate="${replicate}" --seed=123
        )
        set +e
        if [ -n "${TIMEOUT_BIN}" ]; then
          FASTPLS_BENCH_LIB="${FASTPLS_LIB}" "${TIMEOUT_BIN}" \
            --signal=TERM --kill-after=30s "${TIMEOUT_SEC}" \
            "${worker_command[@]}" >"${log}" 2>&1
        else
          FASTPLS_BENCH_LIB="${FASTPLS_LIB}" \
            "${worker_command[@]}" >"${log}" 2>&1
        fi
        code=$?
        set -e
        if [ "${code}" -ne 0 ] && [ ! -s "${row}" ]; then
          status="failed_process_${code}"
          if [ "${code}" -eq 124 ]; then status="timeout"; fi
          message="$(tail -n 10 "${log}" | tr '\n' ' ' | cut -c1-1500)"
          write_failed_row "${row}" "${dataset}" "${backend}" \
            "${classifier}" "${ncomp}" "${replicate}" "${status}" \
            "${message}"
        fi
      done
    done
  done
done

Rscript - "${OUT_DIR}" <<'RS'
out_dir <- commandArgs(TRUE)[[1L]]
paths <- list.files(file.path(out_dir, "rows"), pattern = "[.]csv$", full.names = TRUE)
if (!length(paths)) stop("No CV comparison rows were produced.", call. = FALSE)
raw <- do.call(rbind, lapply(paths, read.csv, stringsAsFactors = FALSE))
write.csv(raw, file.path(out_dir, "cv_compiled_vs_r_loop_raw.csv"), row.names = FALSE)

keys <- c("package_version", "dataset", "task_type", "method", "backend",
          "svd_method", "classifier", "ncomp", "kfold", "control_profile",
          "oversample", "power")
groups <- split(seq_len(nrow(raw)), interaction(raw[keys], drop = TRUE, lex.order = TRUE))
summary_rows <- lapply(groups, function(index) {
  d <- raw[index, , drop = FALSE]
  ok <- d$status == "success"
  finite <- function(x) x[is.finite(x) & ok]
  summarize <- function(x, fun) {
    x <- finite(x)
    if (length(x)) unname(fun(x)) else NA_real_
  }
  result <- d[1L, keys, drop = FALSE]
  result$successful_repetitions <- sum(ok)
  result$total_repetitions <- nrow(d)
  result$compiled_median_sec <- summarize(d$compiled_sec, median)
  result$compiled_iqr_sec <- summarize(d$compiled_sec, IQR)
  result$r_loop_median_sec <- summarize(d$r_loop_sec, median)
  result$r_loop_iqr_sec <- summarize(d$r_loop_sec, IQR)
  result$r_loop_over_compiled_median <- summarize(d$r_loop_over_compiled, median)
  result$metric_name <- if (any(ok)) d$metric_name[which(ok)[1L]] else NA_character_
  result$compiled_metric <- summarize(d$compiled_metric, median)
  result$r_loop_metric <- summarize(d$r_loop_metric, median)
  result$max_metric_abs_diff <- summarize(d$metric_abs_diff, max)
  result$min_prediction_agreement <- summarize(d$prediction_agreement, min)
  result$min_prediction_correlation <- summarize(d$prediction_correlation, min)
  result$max_prediction_relative_error <- summarize(d$prediction_relative_error, max)
  result$identical_fold_partitions <- all(d$identical_fold_partition[ok] %in% TRUE)
  result$status <- if (all(ok)) "success" else "incomplete"
  result
})
summary <- do.call(rbind, summary_rows)
rownames(summary) <- NULL
summary <- summary[order(summary$dataset, summary$backend, summary$classifier), ]
write.csv(summary, file.path(out_dir, "cv_compiled_vs_r_loop_summary.csv"), row.names = FALSE)
print(summary)
RS

cat >"${OUT_DIR}/benchmark_parameters.txt" <<EOF
fastPLS_version=${EXPECTED_VERSION}
datasets=${DATASETS}
backends=${BACKENDS}
family=simpls
svd_method=rsvd
rsvd_controls=automatic_current_release_controls
kfold=${KFOLD}
repetitions=${REPETITIONS}
seed=123
folds=identical_fixed_partitions_for_compiled_and_R_level_routes
timeout_sec=${TIMEOUT_SEC}
unavailable_backend_policy=error_without_CPU_fallback
EOF

echo "[DONE] ${OUT_DIR}"
