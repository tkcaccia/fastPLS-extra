#!/usr/bin/env bash
set -euo pipefail

SOURCE_ROOT="${SOURCE_ROOT:-$HOME/fastPLS_bench_0.99.39}"
FASTPLS_LIB="${FASTPLS_LIB:-$HOME/Rlib_fastPLS_0.99.39}"
RESULTS_ROOT="${RESULTS_ROOT:-$HOME/fastPLS_results_0.99.39/publication_exact}"
SELECTED_COMPONENTS="${SELECTED_COMPONENTS:-${RESULTS_ROOT}/component_selection/selected_components.csv}"
PARENT_PID="${PARENT_PID:-}"

mkdir -p "${RESULTS_ROOT}/queue_logs"

if [ -n "${PARENT_PID}" ]; then
    while kill -0 "${PARENT_PID}" 2>/dev/null; do
        echo "[WAIT] $(date --iso-8601=seconds) pid=${PARENT_PID}"
        sleep 60
    done
fi

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
