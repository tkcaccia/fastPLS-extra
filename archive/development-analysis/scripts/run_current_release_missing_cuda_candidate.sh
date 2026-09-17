#!/usr/bin/env bash

set -euo pipefail

SOURCE_ROOT="${SOURCE_ROOT:-$HOME/fastPLS_bench_0.99.39}"
FASTPLS_LIB="${FASTPLS_LIB:-$HOME/Rlib_fastPLS_0.99.39_candidate}"
RESULTS_ROOT="${RESULTS_ROOT:-$HOME/fastPLS_results_0.99.39/current_release}"
TASK_ROOT="${TASK_ROOT:-$HOME/fastPLS_tasks_0.99.37}"
SELECTED_COMPONENTS="${SELECTED_COMPONENTS:-${RESULTS_ROOT}/component_selection/selected_components.csv}"
NMR_INPUT="${NMR_INPUT:-$HOME/Documents/fastpls/data/nmr.RData}"
IMAGENET_TASK="${IMAGENET_TASK:-$HOME/Documents/fastpls/data/imagenet_float32_seed123_train1000000_task.rds}"
EXPECTED_VERSION="${EXPECTED_VERSION:-0.99.39}"

# Removed development controls must not leak into release-candidate evidence.
unset FASTPLS_FAST_INCREMENTAL FASTPLS_FAST_INC_ITERS FASTPLS_FAST_ADAPTIVE_RSVD

LOG_ROOT="${RESULTS_ROOT}/candidate_queue_logs"
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

verify_candidate
mkdir -p "${RESULTS_ROOT}/cuda_smoke"
cp \
    "${RESULTS_ROOT}/candidate_validation/cuda_backend_family_smoke.csv" \
    "${RESULTS_ROOT}/cuda_smoke/backend_family_smoke_cuda.csv"

run_stage float32_cuda \
    env FASTPLS_BENCH_LIB="${FASTPLS_LIB}" \
    Rscript "${SOURCE_ROOT}/benchmark/benchmark_float32_backend_agreement.R" \
        --backend=cuda \
        --out="${RESULTS_ROOT}/float32_cuda" \
        --seed=123

run_stage nmr_rsvd_exact_candidate \
    env SOURCE_ROOT="${SOURCE_ROOT}" \
        FASTPLS_LIB="${FASTPLS_LIB}" \
        NMR_INPUT="${NMR_INPUT}" \
        OUT_ROOT="${RESULTS_ROOT}/nmr_exact_candidate" \
        REPLICATES=3 \
        R_LIBS_USER="${FASTPLS_LIB}" \
    bash "${SOURCE_ROOT}/scripts/run_current_release_nmr_rsvd_only.sh"

run_stage selected_backend_cuda \
    env FASTPLS_BENCH_LIB="${FASTPLS_LIB}" \
        FASTPLS_MATCHED_ACCELERATOR=cuda \
        FASTPLS_METAL_MATCHED_TASK_ROOT="${TASK_ROOT}" \
        FASTPLS_SELECTED_COMPONENTS_CSV="${SELECTED_COMPONENTS}" \
    Rscript "${SOURCE_ROOT}/benchmark/metal_validation/run_matched_cuda_dataset_metal.R" \
        "${RESULTS_ROOT}/selected_backend_cuda"

run_stage component_path_cuda \
    env SOURCE_ROOT="${SOURCE_ROOT}" \
        FASTPLS_LIB="${FASTPLS_LIB}" \
        RESULTS_ROOT="${RESULTS_ROOT}" \
        TASK_ROOT="${TASK_ROOT}" \
        SELECTED_COMPONENTS="${SELECTED_COMPONENTS}" \
        R_LIBS_USER="${FASTPLS_LIB}" \
    bash "${SOURCE_ROOT}/scripts/run_current_component_path_remote.sh"

run_stage imagenet_cuda \
    env REPO_ROOT="${SOURCE_ROOT}" \
        RUNNER="${SOURCE_ROOT}/benchmark/benchmark_imagenet_current_fused_lda.R" \
        FASTPLS_LIB="${FASTPLS_LIB}" \
        TASK_RDS="${IMAGENET_TASK}" \
        OUTPUT_DIR="${RESULTS_ROOT}/imagenet_exact_candidate" \
        NCOMP_GRID="100 200 300 400 500 600 700 800 900 1000" \
        CLASSIFIERS="argmax lda" \
        OVERSAMPLE=auto \
        POWER=auto \
        SEED=123 \
        PRECISION=float32 \
        TIMEOUT_SEC=10000 \
        R_LIBS_USER="${FASTPLS_LIB}" \
    bash "${SOURCE_ROOT}/scripts/run_imagenet_current_fused_lda_remote.sh"

echo "[DONE] $(date --iso-8601=seconds)"
