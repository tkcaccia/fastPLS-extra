#!/usr/bin/env bash
set -euo pipefail

SOURCE_ROOT="${SOURCE_ROOT:-$HOME/fastPLS_bench_0.99.39}"
FASTPLS_LIB="${FASTPLS_LIB:-$HOME/Rlib_fastPLS_0.99.39}"
RESULTS_ROOT="${RESULTS_ROOT:-$HOME/fastPLS_results_0.99.39/current_release}"
TASK_ROOT="${TASK_ROOT:-$HOME/fastPLS_tasks_0.99.37}"
SELECTED_COMPONENTS="${SELECTED_COMPONENTS:-${RESULTS_ROOT}/component_selection/selected_components.csv}"
PARENT_PID="${PARENT_PID:-}"

mkdir -p "${RESULTS_ROOT}/queue_logs"

if [ -n "${PARENT_PID}" ]; then
    echo "[WAIT] $(date --iso-8601=seconds) pid=${PARENT_PID}"
    while kill -0 "${PARENT_PID}" 2>/dev/null; do
        sleep 60
    done
fi

actual_version="$({ FASTPLS_BENCH_LIB="${FASTPLS_LIB}" Rscript -e '
    .libPaths(unique(c(Sys.getenv("FASTPLS_BENCH_LIB"), .libPaths())))
    cat(as.character(packageVersion("fastPLS")))
'; })"
if [ "${actual_version}" != "0.99.39" ]; then
    echo "Expected fastPLS 0.99.39, loaded ${actual_version}." >&2
    exit 1
fi

FASTPLS_BENCH_LIB="${FASTPLS_LIB}" \
FASTPLS_COMPONENT_ACCELERATOR=cuda \
FASTPLS_COMPONENT_TASK_ROOT="${TASK_ROOT}" \
FASTPLS_SELECTED_COMPONENTS_CSV="${SELECTED_COMPONENTS}" \
FASTPLS_COMPONENT_REPLICATES=5 \
Rscript "${SOURCE_ROOT}/benchmark/run_current_component_path.R" \
    "${RESULTS_ROOT}/component_path_cuda" \
    >"${RESULTS_ROOT}/queue_logs/component_path_cuda.log" 2>&1

echo "[DONE] $(date --iso-8601=seconds)"
