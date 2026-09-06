#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
RUNNER="${RUNNER:-${REPO_ROOT}/benchmark/benchmark_imagenet_current_fused_lda.R}"
FASTPLS_LIB="${FASTPLS_LIB:-$HOME/Rlib_fastPLS_0.99.39}"
TASK_RDS="${TASK_RDS:-$HOME/Documents/fastpls/data/imagenet_float32_seed123_train1000000_task.rds}"
OUTPUT_DIR="${OUTPUT_DIR:-$HOME/fastPLS_results_0.99.39/current_release/imagenet}"
NCOMP_GRID="${NCOMP_GRID:-100 200 300 400 500 600 700 800 900 1000}"
CLASSIFIERS="${CLASSIFIERS:-argmax lda}"
OVERSAMPLE="${OVERSAMPLE:-auto}"
POWER="${POWER:-auto}"
SEED="${SEED:-123}"
PRECISION="${PRECISION:-float32}"
TIMEOUT_SEC="${TIMEOUT_SEC:-10000}"

mkdir -p "${OUTPUT_DIR}/points"
STATUS="${OUTPUT_DIR}/run_status.csv"
printf '%s\n' \
  "classifier,exit_status,status,output_csv,time_log,gpu_log" >"${STATUS}"

for classifier in ${CLASSIFIERS}; do
  stem="imagenet_current_${classifier}_path"
  output_csv="${OUTPUT_DIR}/points/${stem}.csv"
  time_log="${OUTPUT_DIR}/points/${stem}.time"
  gpu_log="${OUTPUT_DIR}/points/${stem}_gpu_trace.csv"
  rm -f "${output_csv}" "${output_csv}.fit.rds"
  echo "[RUN] CUDA SIMPLS-${classifier} shared component path at $(date --iso-8601=seconds)"

  (
    printf '%s\n' "timestamp,memory_used_mb,utilization_gpu_pct"
    while :; do
      now="$(date --iso-8601=seconds)"
      sample="$(nvidia-smi \
        --query-gpu=memory.used,utilization.gpu \
        --format=csv,noheader,nounits 2>/dev/null | head -1)"
      [ -n "${sample}" ] && printf '%s,%s\n' "${now}" "${sample}"
      sleep 2
    done
  ) >"${gpu_log}" &
  monitor_pid=$!

  set +e
  FASTPLS_LIB="${FASTPLS_LIB}" \
  TASK_RDS="${TASK_RDS}" \
  OUTPUT_CSV="${output_csv}" \
  NCOMP_GRID="$(printf '%s' "${NCOMP_GRID}" | tr ' ' ',')" \
  CLASSIFIER="${classifier}" \
  OVERSAMPLE="${OVERSAMPLE}" \
  POWER="${POWER}" \
  SEED="${SEED}" \
  PRECISION="${PRECISION}" \
  REPLICATE=1 \
    /usr/bin/time -v timeout --signal=TERM --kill-after=30s "${TIMEOUT_SEC}" \
      Rscript "${RUNNER}" \
      >"${time_log}" 2>&1
  exit_status=$?
  set -e

  kill "${monitor_pid}" 2>/dev/null || true
  wait "${monitor_pid}" 2>/dev/null || true

  if [ -s "${output_csv}" ]; then
    python3 - "${output_csv}" "${gpu_log}" "${time_log}" <<'PY'
import csv
import pathlib
import re
import sys

output_csv, gpu_log, time_log = map(pathlib.Path, sys.argv[1:])
with output_csv.open(newline="") as handle:
    reader = csv.DictReader(handle)
    rows = list(reader)
    fields = list(reader.fieldnames or [])
if rows:
    for name in (
        "gpu_peak_mb",
        "gpu_incremental_peak_mb",
        "process_peak_rss_mb",
        "incremental_peak_rss_mb",
    ):
        if name not in fields:
            fields.append(name)
    gpu_values = []
    if gpu_log.exists():
        with gpu_log.open(newline="") as handle:
            for row in csv.DictReader(handle):
                try:
                    gpu_values.append(float(row["memory_used_mb"]))
                except (KeyError, TypeError, ValueError):
                    pass
    peak_gpu = max(gpu_values) if gpu_values else None
    time_text = time_log.read_text(errors="replace") if time_log.exists() else ""
    match = re.search(r"Maximum resident set size \(kbytes\):\s*([0-9]+)", time_text)
    peak_rss = float(match.group(1)) / 1024.0 if match else None
    for row in rows:
        try:
            baseline_gpu = float(row.get("gpu_before_fit_mb", ""))
        except ValueError:
            baseline_gpu = None
        try:
            baseline_rss = float(row.get("rss_before_data_mb", ""))
        except ValueError:
            baseline_rss = None
        row["gpu_peak_mb"] = "" if peak_gpu is None else f"{peak_gpu:.6f}"
        row["gpu_incremental_peak_mb"] = (
            "" if peak_gpu is None or baseline_gpu is None
            else f"{peak_gpu - baseline_gpu:.6f}"
        )
        row["process_peak_rss_mb"] = "" if peak_rss is None else f"{peak_rss:.6f}"
        row["incremental_peak_rss_mb"] = (
            "" if peak_rss is None or baseline_rss is None
            else f"{peak_rss - baseline_rss:.6f}"
        )
    with output_csv.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)
PY
  fi

  if [ "${exit_status}" -eq 0 ] && [ -s "${output_csv}" ]; then
    status="success"
  elif [ "${exit_status}" -eq 124 ] || [ "${exit_status}" -eq 137 ]; then
    status="killed_timeout_or_memory"
  else
    status="failed"
  fi
  printf '%s,%s,%s,%s,%s,%s\n' \
    "${classifier}" "${exit_status}" "${status}" \
    "${output_csv}" "${time_log}" "${gpu_log}" >>"${STATUS}"
done

python3 - "${OUTPUT_DIR}" <<'PY'
import csv
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
files = sorted((root / "points").glob("imagenet_current_*_path.csv"))
rows = []
fieldnames = None
for path in files:
    with path.open(newline="") as handle:
        reader = csv.DictReader(handle)
        if fieldnames is None:
            fieldnames = reader.fieldnames
        rows.extend(reader)
if fieldnames:
    for filename in (
        "imagenet_current_fused_lda_all.csv",
        "imagenet_current_summary.csv",
    ):
        with (root / filename).open("w", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=fieldnames)
            writer.writeheader()
            writer.writerows(rows)
PY

python3 - "${STATUS}" "${NCOMP_GRID}" "${CLASSIFIERS}" <<'PY'
import csv
import pathlib
import sys

status_path = pathlib.Path(sys.argv[1])
expected_rows = len(sys.argv[2].split())
expected_classifiers = set(sys.argv[3].split())
with status_path.open(newline="") as handle:
    statuses = list(csv.DictReader(handle))

observed = {row["classifier"] for row in statuses}
failures = [row for row in statuses if row.get("status") != "success"]
if observed != expected_classifiers or failures:
    raise SystemExit(
        "ImageNet worker incomplete: "
        f"expected classifiers={sorted(expected_classifiers)}, "
        f"observed={sorted(observed)}, failures={failures}"
    )

for row in statuses:
    output = pathlib.Path(row["output_csv"])
    with output.open(newline="") as handle:
        results = list(csv.DictReader(handle))
    successful = [result for result in results if result.get("status") == "success"]
    if len(results) != expected_rows or len(successful) != expected_rows:
        raise SystemExit(
            f"{row['classifier']} produced {len(successful)}/{expected_rows} "
            "successful component rows"
        )
PY
