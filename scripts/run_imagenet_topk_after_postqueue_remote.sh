#!/usr/bin/env bash
set -euo pipefail

PARENT_PID="${PARENT_PID:-3318688}"
SOURCE_ROOT="${SOURCE_ROOT:-$HOME/fastPLS_bench_0.99.39}"
ARCHIVE="${ARCHIVE:-$HOME/fastPLS_0.99.39_topk.tar.gz}"
FASTPLS_LIB="${FASTPLS_LIB:-$HOME/Rlib_fastPLS_0.99.39_topk}"
RESULTS_ROOT="${RESULTS_ROOT:-$HOME/fastPLS_results_0.99.39/current_release}"
TASK_RDS="${TASK_RDS:-$HOME/Documents/fastpls/data/imagenet_float32_seed123_train1000000_task.rds}"
IKPLS_RESULTS="${IKPLS_RESULTS:-${RESULTS_ROOT}/ikpls_large_float32}"
LOG_ROOT="${RESULTS_ROOT}/imagenet_topk_logs"

mkdir -p "${FASTPLS_LIB}" "${LOG_ROOT}"
while kill -0 "${PARENT_PID}" 2>/dev/null; do
    sleep 30
done

# A manually released or resumed launcher may have completed while this copy
# waited for the publication queue. Do not repeat the million-row benchmark.
if [[ -f "${LOG_ROOT}/complete.done" ]]; then
    exit 0
fi

FASTPLS_USE_CUDA=1 FASTPLS_REQUIRE_CUDA=1 CUDA_ROOT=/usr/local/cuda \
    R CMD INSTALL --preclean --library="${FASTPLS_LIB}" "${ARCHIVE}" \
    >"${LOG_ROOT}/install.log" 2>&1

FASTPLS_BENCH_LIB="${FASTPLS_LIB}" Rscript \
    "${SOURCE_ROOT}/benchmark/backend_family_smoke.R" cuda \
    "${LOG_ROOT}/cuda_backend_family_smoke.csv" \
    >"${LOG_ROOT}/cuda_backend_family_smoke.log" 2>&1

REPO_ROOT="${SOURCE_ROOT}" \
RUNNER="${SOURCE_ROOT}/benchmark/benchmark_imagenet_current_fused_lda.R" \
FASTPLS_LIB="${FASTPLS_LIB}" \
TASK_RDS="${TASK_RDS}" \
OUTPUT_DIR="${RESULTS_ROOT}/imagenet" \
NCOMP_GRID="100 200 300 400 500 600 700 800 900 1000" \
CLASSIFIERS="argmax lda" \
OVERSAMPLE=auto POWER=auto SEED=123 PRECISION=float32 TIMEOUT_SEC=10000 \
    "${SOURCE_ROOT}/scripts/run_imagenet_current_fused_lda_remote.sh" \
    >"${LOG_ROOT}/imagenet.log" 2>&1

python3 "${SOURCE_ROOT}/benchmark/ikpls_cross_language/summarize_large_float32.py" \
    "${IKPLS_RESULTS}" \
    --fastpls-imagenet "${RESULTS_ROOT}/imagenet/imagenet_current_summary.csv" \
    >"${LOG_ROOT}/ikpls_summary.log" 2>&1

date --iso-8601=seconds >"${LOG_ROOT}/complete.done"
