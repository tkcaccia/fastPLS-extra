#!/usr/bin/env bash
set -euo pipefail

PANEL_PID="${PANEL_PID:-3345750}"
IMAGENET_PID="${IMAGENET_PID:-3459294}"
SOURCE_ROOT="${SOURCE_ROOT:-$HOME/fastPLS_bench_0.99.39}"
FASTPLS_LIB="${FASTPLS_LIB:-$HOME/Rlib_fastPLS_0.99.39_topk}"
RESULTS_ROOT="${RESULTS_ROOT:-$HOME/fastPLS_results_0.99.39/current_release}"
PANEL_DIR="${PANEL_DIR:-${RESULTS_ROOT}/r_package_panel}"
SELECTED_COMPONENTS="${SELECTED_COMPONENTS:-${RESULTS_ROOT}/component_selection/selected_components.csv}"
LOG_ROOT="${LOG_ROOT:-${RESULTS_ROOT}/final_package_panel_logs}"

mkdir -p "${LOG_ROOT}"

for pid in "${PANEL_PID}" "${IMAGENET_PID}"; do
    while kill -0 "${pid}" 2>/dev/null; do
        sleep 30
    done
done

if [[ -f "${LOG_ROOT}/complete.done" ]]; then
    exit 0
fi

FASTPLS_BENCH_LIB="${FASTPLS_LIB}" Rscript -e '
    .libPaths(unique(c(Sys.getenv("FASTPLS_BENCH_LIB"), .libPaths())))
    stopifnot(as.character(packageVersion("fastPLS")) == "0.99.39")
    stopifnot(grepl(
        normalizePath(Sys.getenv("FASTPLS_BENCH_LIB"), mustWork = TRUE),
        normalizePath(system.file(package = "fastPLS"), mustWork = TRUE),
        fixed = TRUE
    ))
' >"${LOG_ROOT}/verify_final_library.log" 2>&1

FASTPLS_BENCH_LIB="${FASTPLS_LIB}" \
FASTPLS_PKG_COMPARE_RESULTS_DIR="${PANEL_DIR}" \
FASTPLS_PKG_COMPARE_DATASETS="metref,ccle,tcga_brca,tcga_hnsc_methylation,gtex_v8,tcga_pan_cancer,retina,tabula,cifar100" \
FASTPLS_PKG_COMPARE_METHODS="fastPLS_simpls_cpu_irlba,fastPLS_simpls_cpu_irlba_lda" \
FASTPLS_PKG_COMPARE_REPS=3 \
FASTPLS_PKG_COMPARE_SHORT_REPS=10 \
FASTPLS_PKG_COMPARE_TIMEOUT_SEC=10000 \
FASTPLS_BENCH_PRECISION=float64 \
FASTPLS_SELECTED_COMPONENTS_CSV="${SELECTED_COMPONENTS}" \
    "${SOURCE_ROOT}/scripts/remote_run_pls_package_comparison.sh" \
    >"${LOG_ROOT}/rerun_fastpls_rows.log" 2>&1

Rscript "${SOURCE_ROOT}/benchmark/plot_pls_package_comparison_current.R" \
    "${PANEL_DIR}/pls_package_comparison_summary.csv" \
    "${PANEL_DIR}/pls_package_comparison_status.csv" \
    "${PANEL_DIR}/pls_package_comparison_current" \
    >"${LOG_ROOT}/plot.log" 2>&1

date --iso-8601=seconds >"${LOG_ROOT}/complete.done"
