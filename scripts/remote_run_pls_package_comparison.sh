#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

: "${FASTPLS_RESULTS_ROOT:?Set FASTPLS_RESULTS_ROOT outside the Git checkouts}"
RESULTS_DIR="${FASTPLS_PKG_COMPARE_RESULTS_DIR:-${FASTPLS_RESULTS_ROOT}/r_package_panel}"
LIB_LOC="${FASTPLS_BENCH_LIB:-}"

# Real-dataset package comparison.  ImageNet is opt-in because several
# independent R PLS packages materialize dense workspaces and are not practical
# on that dataset; set FASTPLS_PKG_COMPARE_INCLUDE_IMAGENET=true to include it.
DATASETS="${FASTPLS_PKG_COMPARE_DATASETS:-metref,ccle,tcga_brca,tcga_hnsc_methylation,gtex_v8,tcga_pan_cancer,retina,tabula,cifar100}"
if [ "${FASTPLS_PKG_COMPARE_INCLUDE_IMAGENET:-false}" = "true" ]; then
  DATASETS="${DATASETS},imagenet"
fi

REPS="${FASTPLS_PKG_COMPARE_REPS:-3}"
SHORT_REPS="${FASTPLS_PKG_COMPARE_SHORT_REPS:-10}"
SHORT_THRESHOLD_MS="${FASTPLS_PKG_COMPARE_SHORT_THRESHOLD_MS:-1000}"
TIMEOUT_SEC="${FASTPLS_PKG_COMPARE_TIMEOUT_SEC:-10000}"
TIME_BIN="${TIME_BIN:-/usr/bin/time}"
TIMEOUT_BIN="${TIMEOUT_BIN:-timeout}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
METHOD_FILTER="${FASTPLS_PKG_COMPARE_METHODS:-fastPLS_simpls_cpu_irlba,fastPLS_simpls_cpu_irlba_lda,pls_simpls_fit,plsgenomics_pls_lda,mdatools_plsda_or_pls,plsdepot_simpls,pcv_simpls,chemometrics_pls_eigen,mixOmics_plsda,spls_splsda}"
PRECISION="${FASTPLS_BENCH_PRECISION:-float64}"
SELECTED_COMPONENTS_CSV="${FASTPLS_SELECTED_COMPONENTS_CSV:-}"

case "${REPS}:${SHORT_REPS}" in
  *[!0-9:]*|:*|*:)
    echo "FASTPLS_PKG_COMPARE_REPS and FASTPLS_PKG_COMPARE_SHORT_REPS must be positive integers." >&2
    exit 1
    ;;
esac
if [ "${REPS}" -lt 1 ] || [ "${SHORT_REPS}" -lt 1 ]; then
  echo "Benchmark repetition counts must be at least one." >&2
  exit 1
fi
if [ "${SHORT_REPS}" -lt "${REPS}" ]; then
  SHORT_REPS="${REPS}"
fi

if [ -n "${SELECTED_COMPONENTS_CSV}" ]; then
  if [ ! -s "${SELECTED_COMPONENTS_CSV}" ]; then
    echo "FASTPLS_SELECTED_COMPONENTS_CSV does not exist or is empty: ${SELECTED_COMPONENTS_CSV}" >&2
    exit 1
  fi
else
  echo "Set FASTPLS_SELECTED_COMPONENTS_CSV to the current training-selected component table." >&2
  echo "Inherited component counts are not supported by this publication workflow." >&2
  exit 1
fi

mkdir -p "${RESULTS_DIR}/run_rows" "${RESULTS_DIR}/logs"

if [ -n "${LIB_LOC}" ]; then
  export R_LIBS_USER="${LIB_LOC}${R_LIBS_USER:+:${R_LIBS_USER}}"
fi

append_rows() {
  local raw_csv="$1"
  shift
  "${PYTHON_BIN}" - "$raw_csv" "$@" <<'PY'
import csv, os, sys
raw = sys.argv[1]
files = sys.argv[2:]
rows = []
for path in files:
    if not os.path.exists(path) or os.path.getsize(path) == 0:
        continue
    with open(path, newline="") as fh:
        rows.extend(list(csv.DictReader(fh)))
if not rows:
    raise SystemExit(0)
fieldnames = list(rows[0].keys())
with open(raw, "w", newline="") as fh:
    w = csv.DictWriter(fh, fieldnames=fieldnames)
    w.writeheader()
    for row in rows:
        w.writerow(row)
PY
}

annotate_resource_row() {
  local row_csv="$1"
  local time_log="$2"
  local process_status="$3"
  "${PYTHON_BIN}" - "$row_csv" "$time_log" "$process_status" <<'PY'
import csv, os, re, sys

row_path, time_path, process_status = sys.argv[1:]
if not os.path.exists(row_path) or os.path.getsize(row_path) == 0:
    raise SystemExit(0)
text = open(time_path, errors="replace").read() if os.path.exists(time_path) else ""

def number(label):
    match = re.search(r"^\s*" + re.escape(label) + r":\s*([0-9.]+)\s*$", text, re.M)
    return float(match.group(1)) if match else None

rss_kb = number("Maximum resident set size (kbytes)")
user_sec = number("User time (seconds)")
system_sec = number("System time (seconds)")
rows = list(csv.DictReader(open(row_path, newline="")))
if not rows:
    raise SystemExit(0)
for row in rows:
    row["peak_host_rss_mb"] = "" if rss_kb is None else f"{rss_kb / 1024.0:.6f}"
    row["user_cpu_sec"] = "" if user_sec is None else f"{user_sec:.6f}"
    row["system_cpu_sec"] = "" if system_sec is None else f"{system_sec:.6f}"
    row["process_status"] = process_status
fields = list(rows[0].keys())
with open(row_path, "w", newline="") as fh:
    writer = csv.DictWriter(fh, fieldnames=fields)
    writer.writeheader()
    writer.writerows(rows)
PY
}

row_status() {
  local row_csv="$1"
  "${PYTHON_BIN}" - "${row_csv}" <<'PY'
import csv, os, sys

path = sys.argv[1]
if not os.path.exists(path) or os.path.getsize(path) == 0:
    print("missing_row")
    raise SystemExit(0)
rows = list(csv.DictReader(open(path, newline="")))
print(rows[0].get("status", "missing_row") if rows else "missing_row")
PY
}

record_skipped_replicates() {
  local source_row="$1"
  local dataset="$2"
  local method_id="$3"
  local ncomp="$4"
  local first_rep="$5"
  local last_rep="$6"
  "${PYTHON_BIN}" - "${source_row}" "${RESULTS_DIR}/run_rows" \
    "${dataset}" "${method_id}" "${ncomp}" "${first_rep}" "${last_rep}" <<'PY'
import csv, os, sys

source, out_dir, dataset, method_id, ncomp, first_rep, last_rep = sys.argv[1:]
rows = list(csv.DictReader(open(source, newline="")))
if not rows:
    raise SystemExit(0)
source_row = rows[0]
previous_status = source_row.get("status", "failed")
fields = list(source_row.keys())
for rep in range(int(first_rep), int(last_rep) + 1):
    row = dict(source_row)
    row["replicate"] = str(rep)
    row["status"] = "skipped_after_previous_failure"
    row["error_message"] = (
        f"Replicate skipped because replicate {int(first_rep) - 1} "
        f"ended with status '{previous_status}'."
    )
    for name in (
        "total_runtime_ms", "peak_host_rss_mb", "user_cpu_sec",
        "system_cpu_sec", "metric_value", "accuracy", "balanced_accuracy",
        "macro_f1", "rmse", "q2", "mae"
    ):
        if name in row:
            row[name] = ""
    row["process_status"] = "not_started"
    path = os.path.join(
        out_dir,
        f"{dataset}__{method_id}__n{ncomp}__rep{rep}.csv"
    )
    with open(path, "w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerow(row)
PY
}

ncomp_for_dataset() {
  Rscript -e '
    x <- read.csv(commandArgs(TRUE)[1], stringsAsFactors = FALSE)
    dataset <- commandArgs(TRUE)[2]
    family_column <- if ("family" %in% names(x)) "family" else "method"
    component_column <- if ("selected_ncomp" %in% names(x)) "selected_ncomp" else "ncomp"
    hit <- x[x$dataset == dataset & x[[family_column]] == "simpls", , drop = FALSE]
    if (nrow(hit) != 1L || !is.finite(hit[[component_column]][[1L]]) ||
        hit[[component_column]][[1L]] < 1L) {
      stop("Expected one valid SIMPLS component count for ", dataset)
    }
    cat(as.integer(hit[[component_column]][[1L]]))
  ' "${SELECTED_COMPONENTS_CSV}" "$1"
}

method_selected() {
  method_id="$1"
  if [ -z "${METHOD_FILTER}" ]; then
    return 0
  fi
  printf '%s' "${METHOD_FILTER}" | tr ',' '\n' | grep -qx "${method_id}"
}

row_runtime_ms() {
  local row_csv="$1"
  "${PYTHON_BIN}" - "${row_csv}" <<'PY'
import csv, math, os, sys

path = sys.argv[1]
if not os.path.exists(path) or os.path.getsize(path) == 0:
    print("nan")
    raise SystemExit(0)
rows = list(csv.DictReader(open(path, newline="")))
try:
    value = float(rows[0].get("total_runtime_ms", "nan"))
except (IndexError, TypeError, ValueError):
    value = float("nan")
print(value if math.isfinite(value) else "nan")
PY
}

for dataset in $(printf '%s' "${DATASETS}" | tr ',' ' '); do
  ncomp="$(ncomp_for_dataset "${dataset}")"

  methods_file="${RESULTS_DIR}/logs/${dataset}_methods.txt"
  Rscript "${REPO_ROOT}/benchmark/benchmark_pls_package_comparison.R" \
    --mode=list_methods --dataset="${dataset}" --ncomp="${ncomp}" >"${methods_file}"

  while IFS= read -r method_id; do
    [ -n "${method_id}" ] || continue
    if ! method_selected "${method_id}"; then
      continue
    fi
    rep_id=1
    target_reps="${REPS}"
    while [ "${rep_id}" -le "${target_reps}" ]; do
      run_id="${dataset}__${method_id}__n${ncomp}__rep${rep_id}"
      row_csv="${RESULTS_DIR}/run_rows/${run_id}.csv"
      stdout_log="${RESULTS_DIR}/logs/${run_id}.stdout.log"
      time_log="${RESULTS_DIR}/logs/${run_id}.time.log"
      rm -f "${row_csv}" "${stdout_log}" "${time_log}"
      echo "[RUN] ${run_id}"
      set +e
      "${TIME_BIN}" -v "${TIMEOUT_BIN}" --signal=TERM --kill-after=30s "${TIMEOUT_SEC}" \
        Rscript "${REPO_ROOT}/benchmark/benchmark_pls_package_comparison.R" \
          --mode=run_one \
          --dataset="${dataset}" \
          --ncomp="${ncomp}" \
          --method-id="${method_id}" \
          --replicate="${rep_id}" \
          --row-out="${row_csv}" >"${stdout_log}" 2>"${time_log}"
      status=$?
      set -e
      if [ ! -s "${row_csv}" ]; then
        msg="Rscript did not produce a row"
        row_status="missing_row"
        if [ "${status}" -eq 124 ]; then
          row_status="killed_timeout"
          msg="Package comparison run exceeded timeout"
        elif grep -q 'Command terminated by signal 9' "${time_log}" 2>/dev/null; then
          row_status="killed_sig9"
          msg="Package comparison run terminated by signal 9"
        fi
        Rscript "${REPO_ROOT}/benchmark/benchmark_pls_package_comparison.R" \
          --mode=missing_row \
          --dataset="${dataset}" \
          --ncomp="${ncomp}" \
          --method-id="${method_id}" \
          --replicate="${rep_id}" \
          --status="${row_status}" \
          --message="${msg}" \
          --row-out="${row_csv}" >>"${stdout_log}" 2>>"${time_log}" || true
      fi
      process_status="ok"
      if [ "${status}" -eq 124 ]; then
        process_status="killed_timeout"
      elif [ "${status}" -ne 0 ]; then
        process_status="error_${status}"
      fi
      annotate_resource_row "${row_csv}" "${time_log}" "${process_status}"
      recorded_status="$(row_status "${row_csv}")"
      case "${recorded_status}" in
        ok)
          if [ "${rep_id}" -eq 1 ]; then
            runtime_ms="$(row_runtime_ms "${row_csv}")"
            if "${PYTHON_BIN}" - "${runtime_ms}" "${SHORT_THRESHOLD_MS}" <<'PY'
import math, sys

try:
    runtime = float(sys.argv[1])
    threshold = float(sys.argv[2])
except ValueError:
    raise SystemExit(1)
raise SystemExit(0 if math.isfinite(runtime) and runtime < threshold else 1)
PY
            then
              target_reps="${SHORT_REPS}"
            fi
          fi
          ;;
        *)
          next_rep=$((rep_id + 1))
          if [ "${next_rep}" -le "${target_reps}" ]; then
            record_skipped_replicates \
              "${row_csv}" "${dataset}" "${method_id}" "${ncomp}" \
              "${next_rep}" "${target_reps}"
          fi
          break
          ;;
      esac
      rep_id=$((rep_id + 1))
    done
  done <"${methods_file}"
done

append_rows "${RESULTS_DIR}/pls_package_comparison_raw.csv" "${RESULTS_DIR}"/run_rows/*.csv
Rscript "${REPO_ROOT}/benchmark/benchmark_pls_package_comparison.R" \
  --mode=summarize \
  --results-dir="${RESULTS_DIR}"

echo "[INFO] Results written to ${RESULTS_DIR}"
