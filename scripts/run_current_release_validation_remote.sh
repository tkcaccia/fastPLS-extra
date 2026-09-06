#!/usr/bin/env bash
set -euo pipefail

SOURCE_ROOT="${SOURCE_ROOT:-$HOME/fastPLS_bench_0.99.39}"
FASTPLS_LIB="${FASTPLS_LIB:-$HOME/Rlib_fastPLS_0.99.39}"
RESULTS_ROOT="${RESULTS_ROOT:-$HOME/fastPLS_results_0.99.39/current_release}"
TASK_ROOT="${TASK_ROOT:-$HOME/fastPLS_tasks_0.99.37}"
SELECTED_COMPONENTS="${SELECTED_COMPONENTS:-${RESULTS_ROOT}/component_selection/selected_components.csv}"
NMR_INPUT="${NMR_INPUT:-$HOME/Documents/fastpls/data/nmr.RData}"
PARENT_PID="${PARENT_PID:-}"

mkdir -p "${RESULTS_ROOT}/validation/logs"

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
if [ ! -s "${SELECTED_COMPONENTS}" ]; then
    echo "Missing current-release component manifest: ${SELECTED_COMPONENTS}" >&2
    exit 1
fi

run_stage() {
    local name="$1"
    shift
    local marker="${RESULTS_ROOT}/validation/logs/${name}.done"
    local failure="${RESULTS_ROOT}/validation/logs/${name}.failed"
    local log="${RESULTS_ROOT}/validation/logs/${name}.log"
    if [ -s "${marker}" ]; then
        echo "[SKIP] ${name}"
        return 0
    fi
    echo "[RUN] ${name} $(date --iso-8601=seconds)"
    if "$@" >"${log}" 2>&1; then
        date --iso-8601=seconds >"${marker}"
        rm -f "${failure}"
    else
        date --iso-8601=seconds >"${failure}"
        echo "[FAILED] ${name}; see ${log}" >&2
    fi
}

run_stage simpls_exact \
    env FASTPLS_BENCH_LIB="${FASTPLS_LIB}" \
    Rscript "${SOURCE_ROOT}/benchmark/benchmark_simpls_exact_reference.R" \
        --root="${SOURCE_ROOT}" \
        --out="${RESULTS_ROOT}/validation/simpls_exact"

run_stage simpls_estimator_preservation \
    env FASTPLS_BENCH_LIB="${FASTPLS_LIB}" \
    Rscript "${SOURCE_ROOT}/benchmark/benchmark_simpls_estimator_preservation.R" \
        --root="${SOURCE_ROOT}" \
        --out="${RESULTS_ROOT}/validation/simpls_estimator_preservation" \
        --nmr="${NMR_INPUT}" \
        --rsvd-seeds=1,7,19,43,123

run_stage opls_kernel_estimator \
    env FASTPLS_BENCH_LIB="${FASTPLS_LIB}" \
    Rscript "${SOURCE_ROOT}/benchmark/benchmark_opls_kernel_estimator_validation.R" \
        --root="${SOURCE_ROOT}" \
        --out="${RESULTS_ROOT}/validation/opls_kernel_estimator"

run_stage opls_kernel_settings \
    env FASTPLS_BENCH_LIB="${FASTPLS_LIB}" \
    Rscript "${SOURCE_ROOT}/benchmark/benchmark_opls_kernel_setting_reliability.R" \
        --root="${SOURCE_ROOT}" \
        --out="${RESULTS_ROOT}/validation/opls_kernel_settings"

run_stage float32_cuda \
    env FASTPLS_BENCH_LIB="${FASTPLS_LIB}" \
    Rscript "${SOURCE_ROOT}/benchmark/benchmark_float32_backend_agreement.R" \
        --backend=cuda \
        --out="${RESULTS_ROOT}/validation/float32_cuda" \
        --seed=123

run_stage selected_backend_cuda \
    env FASTPLS_BENCH_LIB="${FASTPLS_LIB}" \
    FASTPLS_MATCHED_ACCELERATOR=cuda \
    FASTPLS_METAL_MATCHED_TASK_ROOT="${TASK_ROOT}" \
    FASTPLS_SELECTED_COMPONENTS_CSV="${SELECTED_COMPONENTS}" \
    Rscript "${SOURCE_ROOT}/benchmark/metal_validation/run_matched_cuda_dataset_metal.R" \
        "${RESULTS_ROOT}/selected_backend_cuda"

run_stage cv_compiled_vs_r_loop_cuda \
    env FASTPLS_BENCH_LIB="${FASTPLS_LIB}" \
    FASTPLS_CV_TASK_ROOT="${TASK_ROOT}" \
    FASTPLS_SELECTED_COMPONENTS_CSV="${SELECTED_COMPONENTS}" \
    FASTPLS_CV_COMPARATOR_OUT="${RESULTS_ROOT}/validation/cv_compiled_vs_r_loop" \
    FASTPLS_CV_BACKENDS="cpu,cuda" \
    FASTPLS_CV_REPETITIONS=3 \
    bash "${SOURCE_ROOT}/scripts/run_cv_compiled_vs_r_loop.sh"

echo "[DONE] $(date --iso-8601=seconds)"
