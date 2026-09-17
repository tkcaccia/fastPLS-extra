#!/usr/bin/env bash
set -euo pipefail

SOURCE_ROOT="${SOURCE_ROOT:-$HOME/fastPLS_bench_0.99.39}"
FASTPLS_LIB="${FASTPLS_LIB:-$HOME/Rlib_fastPLS_0.99.39}"
RESULTS_ROOT="${RESULTS_ROOT:-$HOME/fastPLS_results_0.99.39/current_release}"
SELECTED_COMPONENTS="${SELECTED_COMPONENTS:-${RESULTS_ROOT}/component_selection/selected_components.csv}"
TASK_ROOT="${TASK_ROOT:-$HOME/fastPLS_tasks_0.99.37}"
PARENT_PID="${PARENT_PID:-}"

mkdir -p "${RESULTS_ROOT}/queue_logs"

if [ -n "${PARENT_PID}" ]; then
    echo "[WAIT] $(date --iso-8601=seconds) pid=${PARENT_PID}"
    while kill -0 "${PARENT_PID}" 2>/dev/null; do
        sleep 60
    done
fi

if [ ! -s "${SELECTED_COMPONENTS}" ]; then
    echo "[COMPONENT_SELECTION] $(date --iso-8601=seconds)"
    FASTPLS_BENCH_LIB="${FASTPLS_LIB}" \
    FASTPLS_COMPONENT_TASK_ROOT="${TASK_ROOT}" \
    Rscript "${SOURCE_ROOT}/benchmark/run_current_component_selection.R" \
        "${RESULTS_ROOT}/component_selection" \
        >"${RESULTS_ROOT}/queue_logs/component_selection.log" 2>&1
else
    echo "[COMPONENT_SELECTION] existing manifest: ${SELECTED_COMPONENTS}"
fi

if [ ! -s "${SELECTED_COMPONENTS}" ]; then
    echo "Component selection did not produce ${SELECTED_COMPONENTS}" >&2
    exit 1
fi

echo "[NMR_IMAGENET] $(date --iso-8601=seconds)"
SOURCE_ROOT="${SOURCE_ROOT}" \
FASTPLS_LIB="${FASTPLS_LIB}" \
NMR_OUT="${RESULTS_ROOT}/nmr" \
OUTPUT_DIR="${RESULTS_ROOT}/imagenet" \
bash "${SOURCE_ROOT}/scripts/run_current_release_followup_remote.sh" \
    >"${RESULTS_ROOT}/queue_logs/nmr_imagenet.log" 2>&1

echo "[EXTERNAL_SIMPLS] $(date --iso-8601=seconds)"
FASTPLS_BENCH_LIB="${FASTPLS_LIB}" \
FASTPLS_SELECTED_COMPONENTS_CSV="${SELECTED_COMPONENTS}" \
FASTPLS_EXTERNAL_TIMING_RESULTS_DIR="${RESULTS_ROOT}/external_simpls" \
bash "${SOURCE_ROOT}/scripts/run_external_simpls_timing.sh" \
    >"${RESULTS_ROOT}/queue_logs/external_simpls.log" 2>&1

echo "[R_PACKAGE_PANEL] $(date --iso-8601=seconds)"
FASTPLS_BENCH_LIB="${FASTPLS_LIB}" \
FASTPLS_SELECTED_COMPONENTS_CSV="${SELECTED_COMPONENTS}" \
FASTPLS_PKG_COMPARE_RESULTS_DIR="${RESULTS_ROOT}/r_package_panel" \
bash "${SOURCE_ROOT}/scripts/remote_run_pls_package_comparison.sh" \
    >"${RESULTS_ROOT}/queue_logs/r_package_panel.log" 2>&1

echo "[DONE] $(date --iso-8601=seconds)"
