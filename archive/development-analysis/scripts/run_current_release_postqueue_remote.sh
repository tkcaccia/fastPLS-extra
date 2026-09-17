#!/usr/bin/env bash

set -euo pipefail

SOURCE_ROOT="${SOURCE_ROOT:-$HOME/fastPLS_bench_0.99.39}"
FASTPLS_LIB="${FASTPLS_LIB:-$HOME/Rlib_fastPLS_0.99.39_candidate}"
RESULTS_ROOT="${RESULTS_ROOT:-$HOME/fastPLS_results_0.99.39/current_release}"
SELECTED_COMPONENTS="${SELECTED_COMPONENTS:-${RESULTS_ROOT}/component_selection/selected_components.csv}"
NMR_INPUT="${NMR_INPUT:-$HOME/Documents/fastpls/data/nmr.RData}"
IMAGENET_TASK="${IMAGENET_TASK:-$HOME/Documents/fastpls/data/imagenet_float32_seed123_train1000000_task.rds}"
IKPLS_SITE="${IKPLS_SITE:-$HOME/ikpls_py_6.1.2}"
IKPLS_DATA="${IKPLS_DATA:-$HOME/fastPLS_ikpls_float32_current_0.99.39/data}"
IKPLS_RESULTS="${RESULTS_ROOT}/ikpls_large_float32"
EXPECTED_VERSION="${EXPECTED_VERSION:-0.99.39}"
QUEUE_PID_FILE="${RESULTS_ROOT}/candidate_queue.pid"
LOG_ROOT="${RESULTS_ROOT}/postqueue_logs"

unset FASTPLS_FAST_INCREMENTAL FASTPLS_FAST_INC_ITERS FASTPLS_FAST_ADAPTIVE_RSVD
mkdir -p "${LOG_ROOT}"

verify_candidate() {
    FASTPLS_BENCH_LIB="${FASTPLS_LIB}" Rscript -e '
        .libPaths(unique(c(Sys.getenv("FASTPLS_BENCH_LIB"), .libPaths())))
        stopifnot(as.character(packageVersion("fastPLS")) == commandArgs(TRUE)[1L])
        stopifnot(isTRUE(fastPLS::has_cuda()))
    ' "${EXPECTED_VERSION}"
}

run_stage() {
    local name="$1"
    shift
    local done_file="${LOG_ROOT}/${name}.done"
    local failed_file="${LOG_ROOT}/${name}.failed"
    local log_file="${LOG_ROOT}/${name}.log"
    if [ -s "${done_file}" ]; then
        echo "[SKIP] ${name}"
        return 0
    fi
    verify_candidate
    echo "[RUN] ${name} $(date --iso-8601=seconds)"
    if "$@" >"${log_file}" 2>&1; then
        date --iso-8601=seconds >"${done_file}"
        rm -f "${failed_file}"
    else
        date --iso-8601=seconds >"${failed_file}"
        echo "[FAILED] ${name}; see ${log_file}" >&2
        return 1
    fi
}

if [ -s "${QUEUE_PID_FILE}" ]; then
    queue_pid="$(cat "${QUEUE_PID_FILE}")"
    while kill -0 "${queue_pid}" 2>/dev/null; do
        sleep 30
    done
fi

for stage in component_path_cuda imagenet_cuda; do
    if [ ! -s "${RESULTS_ROOT}/candidate_queue_logs/${stage}.done" ]; then
        echo "The prerequisite stage ${stage} did not complete successfully." >&2
        exit 1
    fi
done

# Rebuild component-path summaries and sidecars from completed worker results.
run_stage component_path_cuda_resummarize \
    env FASTPLS_BENCH_LIB="${FASTPLS_LIB}" \
        FASTPLS_COMPONENT_ACCELERATOR=cuda \
        FASTPLS_COMPONENT_TASK_ROOT="$HOME/fastPLS_tasks_0.99.37" \
        FASTPLS_SELECTED_COMPONENTS_CSV="${SELECTED_COMPONENTS}" \
    Rscript "${SOURCE_ROOT}/benchmark/run_current_component_path.R" \
        "${RESULTS_ROOT}/component_path_cuda"

run_stage ikpls_export_nmr \
    Rscript "${SOURCE_ROOT}/benchmark/ikpls_cross_language/export_large_float32.R" \
        nmr "${NMR_INPUT}" "${IKPLS_DATA}/nmr"

run_stage ikpls_export_imagenet \
    Rscript "${SOURCE_ROOT}/benchmark/ikpls_cross_language/export_large_float32.R" \
        imagenet "${IMAGENET_TASK}" "${IKPLS_DATA}/imagenet"

run_stage ikpls_prepare_imagenet \
    env PYTHONPATH="${IKPLS_SITE}" \
    python3 "${SOURCE_ROOT}/benchmark/ikpls_cross_language/prepare_imagenet_float32.py" \
        "${IKPLS_DATA}/imagenet"

run_stage ikpls_large_float32 \
    env PYTHONPATH="${IKPLS_SITE}" \
        OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 MKL_NUM_THREADS=1 \
        NUMEXPR_NUM_THREADS=1 \
    python3 "${SOURCE_ROOT}/benchmark/ikpls_cross_language/run_large_float32.py" \
        --data-root "${IKPLS_DATA}" \
        --results "${IKPLS_RESULTS}"

cp "${IKPLS_DATA}/imagenet/preprocessing.tsv" "${IKPLS_RESULTS}/preprocessing.tsv"
run_stage ikpls_large_float32_summary \
    env PYTHONPATH="${IKPLS_SITE}" \
    python3 "${SOURCE_ROOT}/benchmark/ikpls_cross_language/summarize_large_float32.py" \
        "${IKPLS_RESULTS}" \
        --fastpls-imagenet "${RESULTS_ROOT}/imagenet_exact_candidate/imagenet_current_summary.csv"

run_stage r_package_panel \
    env FASTPLS_BENCH_LIB="${FASTPLS_LIB}" \
        FASTPLS_PKG_COMPARE_RESULTS_DIR="${RESULTS_ROOT}/r_package_panel" \
        FASTPLS_SELECTED_COMPONENTS_CSV="${SELECTED_COMPONENTS}" \
        FASTPLS_PKG_COMPARE_REPS=3 \
        FASTPLS_PKG_COMPARE_SHORT_REPS=10 \
        FASTPLS_PKG_COMPARE_SHORT_THRESHOLD_MS=1000 \
        FASTPLS_PKG_COMPARE_TIMEOUT_SEC=10000 \
        R_LIBS_USER="${FASTPLS_LIB}" \
    bash "${SOURCE_ROOT}/scripts/remote_run_pls_package_comparison.sh"

echo "[DONE] $(date --iso-8601=seconds)"
