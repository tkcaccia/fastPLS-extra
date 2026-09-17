#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${FASTPLS_RESULTS_ROOT:?Set FASTPLS_RESULTS_ROOT outside the Git checkouts}"
RESULTS_DIR="${FASTPLS_EXTERNAL_TIMING_RESULTS_DIR:-${FASTPLS_RESULTS_ROOT}/external_simpls_timing}"
DATASETS="${FASTPLS_EXTERNAL_TIMING_DATASETS:-metref,ccle,tcga_brca,tcga_hnsc_methylation,gtex_v8,tcga_pan_cancer,retina,tabula,cifar100}"
PROFILES="${FASTPLS_EXTERNAL_TIMING_PROFILES:-estimator_kernel,complete_workflow}"
IMPLEMENTATIONS="${FASTPLS_EXTERNAL_TIMING_IMPLEMENTATIONS:-fastpls,pls}"
REPS="${FASTPLS_EXTERNAL_TIMING_REPS:-adaptive}"
TIMING_MODES="${FASTPLS_EXTERNAL_TIMING_MODES:-cold_process,steady_process_batch}"
CPU_PROFILES="${FASTPLS_EXTERNAL_TIMING_CPU_PROFILES:-reference_1}"
TIMEOUT_SEC="${FASTPLS_EXTERNAL_TIMING_TIMEOUT_SEC:-10000}"
: "${FASTPLS_SELECTED_COMPONENTS_CSV:?Set FASTPLS_SELECTED_COMPONENTS_CSV}"
SELECTED_COMPONENTS_CSV="${FASTPLS_SELECTED_COMPONENTS_CSV}"
TIMEOUT_BIN="${TIMEOUT_BIN:-timeout}"
TIME_BIN="${TIME_BIN:-/usr/bin/time}"
TIME_STYLE="linux"
if ! "${TIME_BIN}" -v true >/dev/null 2>&1; then TIME_STYLE="mac"; fi

export OMP_NUM_THREADS=1
export OPENBLAS_NUM_THREADS=1
export MKL_NUM_THREADS=1
export BLIS_NUM_THREADS=1
export VECLIB_MAXIMUM_THREADS=1

mkdir -p "${RESULTS_DIR}/rows" "${RESULTS_DIR}/logs"
cat >"${RESULTS_DIR}/benchmark_parameters.txt" <<EOF
datasets=${DATASETS}
profiles=${PROFILES}
implementations=${IMPLEMENTATIONS}
repetitions=${REPS}
timing_modes=${TIMING_MODES}
cpu_profiles=${CPU_PROFILES}
openblas_library=${FASTPLS_OPENBLAS_LIBRARY:-not_supplied}
adaptive_cold_repetitions=50_if_pilot_le_0.5s;30_if_le_2s;15_if_le_10s;5_otherwise
steady_process_batch_iterations=50_if_pilot_le_0.5s;30_if_le_2s;20_if_le_10s;10_otherwise
timeout_sec=${TIMEOUT_SEC}
runtime_initialization=cold_process:none;steady_process_batch:one_untimed_complete_fit_and_prediction
package_and_data_loading_timed=false
rss_baseline=immediately_before_fit_after_gc
rss_peak=maximum_process_rss_over_worker_lifetime
rss_increment=maximum_process_rss_minus_prefit_process_rss
rss_increment_scope=baseline_corrected_process_increment_not_algorithmic_workspace
precision=float64
blas_threads=1
split_seed=123
fastpls_version=0.99.39
selected_components_csv=${SELECTED_COMPONENTS_CSV}
EOF

annotate_resources() {
  local row="$1"
  local resources="$2"
  [ -s "${row}" ] || return 0
  Rscript - "${row}" "${resources}" <<'RS'
args <- commandArgs(TRUE)
d <- read.csv(args[[1L]], check.names = FALSE)
text <- if (file.exists(args[[2L]])) readLines(args[[2L]], warn = FALSE) else character()
value <- function(label) {
  hit <- grep(paste0("^[[:space:]]*", label, ":[[:space:]]*"), text, value = TRUE)
  if (!length(hit)) return(NA_real_)
  suppressWarnings(as.numeric(sub(".*:[[:space:]]*", "", hit[[length(hit)]])))
}
linux_peak <- value("Maximum resident set size \\(kbytes\\)")
mac_hit <- grep("maximum resident set size$", text, value = TRUE)
mac_peak <- if (length(mac_hit)) suppressWarnings(as.numeric(sub("^[[:space:]]*([0-9]+).*", "\\1", mac_hit[[length(mac_hit)]]))) else NA_real_
d$process_peak_rss_mb <- if (is.finite(linux_peak)) linux_peak / 1024 else mac_peak / 1024^2
d$user_cpu_sec <- value("User time \\(seconds\\)")
d$system_cpu_sec <- value("System time \\(seconds\\)")
write.csv(d, args[[1L]], row.names = FALSE, quote = TRUE, na = "")
RS
}

ncomp_for_dataset() {
  Rscript - "${SELECTED_COMPONENTS_CSV}" "$1" <<'RS'
args <- commandArgs(TRUE)
path <- normalizePath(args[[1L]], mustWork = TRUE)
dataset <- args[[2L]]
selected <- read.csv(path, stringsAsFactors = FALSE)
family_column <- if ("family" %in% names(selected)) "family" else "method"
component_column <- if ("selected_ncomp" %in% names(selected)) {
  "selected_ncomp"
} else {
  "ncomp"
}
hit <- selected[
  tolower(selected$dataset) == dataset &
    tolower(selected[[family_column]]) == "simpls",
  component_column,
  drop = TRUE
]
if (length(hit) != 1L || !is.finite(hit) || hit < 1L) {
  stop("Missing one valid SIMPLS component selection for ", dataset,
       call. = FALSE)
}
cat(as.integer(hit))
RS
}

run_worker() {
  local dataset="$1"
  local profile="$2"
  local implementation="$3"
  local ncomp="$4"
  local cpu_profile="$5"
  local timing_mode="$6"
  local replicate="$7"
  local iterations="$8"
  local measurement_scope="${9:-primary}"
  local phase_timing=false
  if [ "${measurement_scope}" = "phase_decomposition" ]; then phase_timing=true; fi
  local threads=1
  if [ "${cpu_profile}" = "optimized_4" ]; then threads=4; fi
  local id="${dataset}__${profile}__${implementation}__${cpu_profile}__${measurement_scope}__${timing_mode}__rep${replicate}"
  local row="${RESULTS_DIR}/rows/${id}.csv"
  local log="${RESULTS_DIR}/logs/${id}.log"
  local resources="${RESULTS_DIR}/logs/${id}.resources.txt"
  echo "[RUN] ${id} iterations=${iterations}"
  set +e
  local -a blas_env=(env "OMP_NUM_THREADS=${threads}" "OPENBLAS_NUM_THREADS=${threads}" "MKL_NUM_THREADS=${threads}" "BLIS_NUM_THREADS=${threads}" "VECLIB_MAXIMUM_THREADS=${threads}")
  if [ "${cpu_profile}" != "reference_1" ]; then
    blas_env+=("LD_PRELOAD=${FASTPLS_OPENBLAS_LIBRARY}")
  fi
  local -a time_args
  if [ "${TIME_STYLE}" = "linux" ]; then time_args=(-v); else time_args=(-l); fi
  "${TIME_BIN}" "${time_args[@]}" "${TIMEOUT_BIN}" --signal=TERM --kill-after=30s "${TIMEOUT_SEC}" \
    "${blas_env[@]}" Rscript "${REPO_ROOT}/benchmark/external_simpls_timing/worker.R" \
      --dataset="${dataset}" --profile="${profile}" \
      --implementation="${implementation}" --ncomp="${ncomp}" \
      --cpu-profile="${cpu_profile}" --threads="${threads}" \
      --measurement-scope="${measurement_scope}" --phase-timing="${phase_timing}" \
      --timing-mode="${timing_mode}" --iterations="${iterations}" \
      --replicate="${replicate}" --seed=123 --timeout-sec="${TIMEOUT_SEC}" \
      --row-out="${row}" >"${log}" 2>"${resources}"
  local code=$?
  set -e
  if [ "${code}" -ne 0 ] && [ ! -s "${row}" ]; then
    local status="failed_process_${code}"
    if [ "${code}" -eq 124 ]; then status="timeout"; fi
    Rscript - "${row}" "${dataset}" "${profile}" "${implementation}" "${cpu_profile}" "${timing_mode}" "${measurement_scope}" "${replicate}" "${status}" <<'RS'
args <- commandArgs(TRUE)
dir.create(dirname(args[[1L]]), recursive = TRUE, showWarnings = FALSE)
write.csv(data.frame(
  dataset=args[[2L]], comparison_profile=args[[3L]], implementation=args[[4L]],
  cpu_profile=args[[5L]], timing_mode=args[[6L]], measurement_scope=args[[7L]],
  replicate=as.integer(args[[8L]]), iteration=1L,
  status=args[[9L]], error_message=args[[9L]]
), args[[1L]], row.names=FALSE)
RS
  fi
  annotate_resources "${row}" "${resources}"
}

pilot_seconds() {
  Rscript - "$1" <<'RS'
d <- read.csv(commandArgs(TRUE)[[1L]])
v <- d$total_sec[is.finite(d$total_sec) & d$status == "success"]
cat(if (length(v)) v[[1L]] else Inf)
RS
}

adaptive_count() {
  Rscript - "$1" "$2" <<'RS'
x <- as.numeric(commandArgs(TRUE)[[1L]])
mode <- commandArgs(TRUE)[[2L]]
if (!is.finite(x)) cat(1L) else if (mode == "cold") {
  cat(if (x <= 0.5) 50L else if (x <= 2) 30L else if (x <= 10) 15L else 5L)
} else {
  cat(if (x <= 0.5) 50L else if (x <= 2) 30L else if (x <= 10) 20L else 10L)
}
RS
}

for dataset in $(printf '%s' "${DATASETS}" | tr ',' ' '); do
  ncomp="$(ncomp_for_dataset "${dataset}")"
  for profile in $(printf '%s' "${PROFILES}" | tr ',' ' '); do
    for implementation in $(printf '%s' "${IMPLEMENTATIONS}" | tr ',' ' '); do
      for cpu_profile in $(printf '%s' "${CPU_PROFILES}" | tr ',' ' '); do
      if [ "${cpu_profile}" != "reference_1" ] && [ ! -f "${FASTPLS_OPENBLAS_LIBRARY:-}" ]; then
        echo "[SKIP] ${cpu_profile}: FASTPLS_OPENBLAS_LIBRARY is not a readable file" >&2
        continue
      fi
      run_worker "${dataset}" "${profile}" "${implementation}" "${ncomp}" "${cpu_profile}" cold_process 1 1
      pilot_row="${RESULTS_DIR}/rows/${dataset}__${profile}__${implementation}__${cpu_profile}__primary__cold_process__rep1.csv"
      pilot_sec="$(pilot_seconds "${pilot_row}")"
      cold_reps="${REPS}"
      if [ "${REPS}" = "adaptive" ]; then cold_reps="$(adaptive_count "${pilot_sec}" cold)"; fi
      if [ "${cold_reps}" -gt 1 ]; then
        for replicate in $(seq 2 "${cold_reps}"); do
          run_worker "${dataset}" "${profile}" "${implementation}" "${ncomp}" "${cpu_profile}" cold_process "${replicate}" 1
        done
      fi
      if printf '%s' "${TIMING_MODES}" | tr ',' '\n' | grep -qx steady_process_batch; then
        steady_iterations="$(adaptive_count "${pilot_sec}" steady)"
        run_worker "${dataset}" "${profile}" "${implementation}" "${ncomp}" "${cpu_profile}" steady_process_batch 1 "${steady_iterations}"
      fi
      if [ "${implementation}" = "fastpls" ]; then
        phase_iterations="$(adaptive_count "${pilot_sec}" steady)"
        run_worker "${dataset}" "${profile}" "${implementation}" "${ncomp}" "${cpu_profile}" steady_process_batch 1 "${phase_iterations}" phase_decomposition
      fi
      done
    done
  done
done

Rscript "${REPO_ROOT}/benchmark/external_simpls_timing/summarize.R" "${RESULTS_DIR}"
echo "[DONE] ${RESULTS_DIR}"
