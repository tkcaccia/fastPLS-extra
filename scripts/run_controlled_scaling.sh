#!/usr/bin/env bash

set -u

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)"
: "${FASTPLS_RESULTS_ROOT:?Set FASTPLS_RESULTS_ROOT outside the Git checkouts}"
OUT_DIR="${1:-${FASTPLS_RESULTS_ROOT}/controlled_scaling_$(date +%Y%m%d_%H%M%S)}"
PROFILE="${2:-smoke}"
BACKENDS="${3:-cpu}"
REPS="${4:-3}"
RUN_TIMEOUT_SEC="${FASTPLS_SCALING_TIMEOUT_SEC:-600}"
LIB_LOC="${FASTPLS_SCALING_LIB:-${OUT_DIR}/Rlib}"
: "${FASTPLS_SCALING_ARCHIVE:?Set FASTPLS_SCALING_ARCHIVE to the candidate source archive}"
ARCHIVE="${FASTPLS_SCALING_ARCHIVE}"
CPU_PROFILE="${FASTPLS_SCALING_CPU_PROFILE:-reference_1}"
CPU_THREADS="${FASTPLS_SCALING_THREADS:-1}"
RESUME="${FASTPLS_SCALING_RESUME:-false}"

export FASTPLS_SCALING_CPU_PROFILE="${CPU_PROFILE}"
export FASTPLS_SCALING_THREADS="${CPU_THREADS}"
export OMP_NUM_THREADS="${CPU_THREADS}"
export OPENBLAS_NUM_THREADS="${CPU_THREADS}"
export MKL_NUM_THREADS="${CPU_THREADS}"
export BLIS_NUM_THREADS="${CPU_THREADS}"
export VECLIB_MAXIMUM_THREADS="${CPU_THREADS}"

mkdir -p "${OUT_DIR}" "${LIB_LOC}"

if [ "${FASTPLS_SCALING_SKIP_INSTALL:-false}" != "true" ]; then
  R CMD INSTALL --preclean --library="${LIB_LOC}" "${ARCHIVE}" >"${OUT_DIR}/install.log" 2>&1 || {
    cat "Package installation failed; see ${OUT_DIR}/install.log" >&2
    exit 1
  }
fi

BASE_R_LIBS="$(Rscript -e 'cat(paste(.libPaths(), collapse=.Platform$path.sep))')"
export R_LIBS_USER="${LIB_LOC}${BASE_R_LIBS:+:${BASE_R_LIBS}}"
export R_LIBS="${LIB_LOC}${BASE_R_LIBS:+:${BASE_R_LIBS}}"

EXPECTED_VERSION="${FASTPLS_SCALING_EXPECTED_VERSION:-0.99.39}"
ACTUAL_VERSION="$(FASTPLS_SCALING_LIB="${LIB_LOC}" Rscript -e \
  '.libPaths(unique(c(Sys.getenv("FASTPLS_SCALING_LIB"), .libPaths()))); cat(as.character(utils::packageVersion("fastPLS")))')"
if [ "${ACTUAL_VERSION}" != "${EXPECTED_VERSION}" ]; then
  printf 'Expected fastPLS %s in %s, but R loaded %s\n' \
    "${EXPECTED_VERSION}" "${LIB_LOC}" "${ACTUAL_VERSION}" >&2
  exit 1
fi

Rscript "${REPO_ROOT}/benchmark/controlled_scaling/generate_grid.R" \
  "${OUT_DIR}" "${PROFILE}" "${BACKENDS}" "${REPS}"

TIME_BIN="/usr/bin/time"
TIME_STYLE="linux"
if ! "${TIME_BIN}" -v true >/dev/null 2>&1; then TIME_STYLE="mac"; fi

sample_process() {
  local pid="$1" sample_file="$2" done_file="$3" launcher="$4"
  printf 'timestamp,kind,value_mb\n' >"${sample_file}"
  while kill -0 "${launcher}" 2>/dev/null && [ ! -e "${done_file}" ]; do
    local now rss gpu_pid gpu_total
    now="$(date +%s.%N 2>/dev/null || date +%s)"
    rss="$(awk '/^VmRSS:/ {print $2/1024; exit}' "/proc/${pid}/status" 2>/dev/null || true)"
    if [ -z "${rss}" ]; then
      rss="$(ps -o rss= -p "${pid}" 2>/dev/null | awk 'NR==1 {print $1/1024}')"
    fi
    [ -n "${rss}" ] && printf '%s,rss,%s\n' "${now}" "${rss}" >>"${sample_file}"
    gpu_pid="$(nvidia-smi --query-compute-apps=pid,used_gpu_memory --format=csv,noheader,nounits 2>/dev/null | awk -F',' -v p="${pid}" '$1+0==p {gsub(/ /,"",$2); print $2; exit}')"
    [ -n "${gpu_pid}" ] && printf '%s,gpu_pid,%s\n' "${now}" "${gpu_pid}" >>"${sample_file}"
    gpu_total="$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | awk 'NR==1 {gsub(/ /,"",$1); print $1}')"
    [ -n "${gpu_total}" ] && printf '%s,gpu_total,%s\n' "${now}" "${gpu_total}" >>"${sample_file}"
    sleep 0.02
  done
}

mapfile_cmd="mapfile"
if ! command -v mapfile >/dev/null 2>&1; then mapfile_cmd=""; fi
if [ -n "${mapfile_cmd}" ]; then
  mapfile -t CONFIGS <"${OUT_DIR}/config_paths.txt"
else
  CONFIGS=()
  while IFS= read -r line; do CONFIGS+=("${line}"); done <"${OUT_DIR}/config_paths.txt"
fi

total="${#CONFIGS[@]}"
index=0
for config in "${CONFIGS[@]}"; do
  index=$((index + 1))
  run_id="$(basename "${config}" .rds)"
  result="${OUT_DIR}/rows/${run_id}.rds"
  result_csv="${OUT_DIR}/rows/${run_id}.csv"
  pid_file="${OUT_DIR}/logs/${run_id}.pid"
  done_file="${OUT_DIR}/logs/${run_id}.measurement_done"
  sample_file="${OUT_DIR}/logs/${run_id}.samples.csv"
  stdout_file="${OUT_DIR}/logs/${run_id}.out"
  time_file="${OUT_DIR}/logs/${run_id}.time"
  if [ "${RESUME}" = "true" ] && [ -s "${result_csv}" ]; then
    printf '[%s] %d/%d %s [existing]\n' \
      "$(date '+%F %T')" "${index}" "${total}" "${run_id}"
    continue
  fi
  rm -f "${pid_file}" "${done_file}" "${result}"
  printf '[%s] %d/%d %s\n' "$(date '+%F %T')" "${index}" "${total}" "${run_id}"

  if [ "${TIME_STYLE}" = "linux" ]; then
    ("${TIME_BIN}" -v Rscript "${REPO_ROOT}/benchmark/controlled_scaling/worker.R" "${config}" "${result}" "${pid_file}" "${done_file}" >"${stdout_file}" 2>"${time_file}") &
  else
    ("${TIME_BIN}" -l Rscript "${REPO_ROOT}/benchmark/controlled_scaling/worker.R" "${config}" "${result}" "${pid_file}" "${done_file}" >"${stdout_file}" 2>"${time_file}") &
  fi
  launcher=$!

  waited=0
  while [ ! -s "${pid_file}" ] && kill -0 "${launcher}" 2>/dev/null && [ "${waited}" -lt 200 ]; do
    sleep 0.05
    waited=$((waited + 1))
  done
  if [ -s "${pid_file}" ]; then
    worker_pid="$(cat "${pid_file}")"
    sample_process "${worker_pid}" "${sample_file}" "${done_file}" "${launcher}" &
    sampler=$!
  else
    sampler=""
  fi

  elapsed=0
  while kill -0 "${launcher}" 2>/dev/null; do
    if [ "${RUN_TIMEOUT_SEC}" -gt 0 ] && [ "${elapsed}" -ge "${RUN_TIMEOUT_SEC}" ]; then
      kill "${launcher}" 2>/dev/null || true
      if [ -s "${pid_file}" ]; then kill "$(cat "${pid_file}")" 2>/dev/null || true; fi
      break
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  wait "${launcher}" 2>/dev/null || true
  [ -n "${sampler}" ] && wait "${sampler}" 2>/dev/null || true

  if [ -f "${result}" ]; then
    Rscript "${REPO_ROOT}/benchmark/controlled_scaling/finalize_run.R" "${result}" "${sample_file}" "${time_file}"
  else
    Rscript "${REPO_ROOT}/benchmark/controlled_scaling/failure_row.R" \
      "${config}" "${OUT_DIR}/rows/${run_id}.csv" "No result file; process failed or exceeded ${RUN_TIMEOUT_SEC} seconds"
  fi
done

Rscript "${REPO_ROOT}/benchmark/controlled_scaling/summarize.R" "${OUT_DIR}"

{
  echo "finished=$(date -Iseconds 2>/dev/null || date)"
  echo "profile=${PROFILE}"
  echo "backends=${BACKENDS}"
  echo "replicates=${REPS}"
  echo "cpu_profile=${CPU_PROFILE}"
  echo "requested_blas_threads=${CPU_THREADS}"
  echo "resume=${RESUME}"
  echo "archive=${ARCHIVE}"
  echo "expected_package_version=${EXPECTED_VERSION}"
  echo "loaded_package_version=${ACTUAL_VERSION}"
  uname -a
  Rscript -e 'cat(R.version.string, "\n"); print(extSoftVersion())'
  nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader 2>/dev/null || true
} >"${OUT_DIR}/system_info.txt" 2>&1

echo "Controlled scaling benchmark complete: ${OUT_DIR}"
