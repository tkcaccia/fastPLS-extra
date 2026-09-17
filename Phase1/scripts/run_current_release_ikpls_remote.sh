#!/usr/bin/env bash

set -euo pipefail

SOURCE_ROOT="${SOURCE_ROOT:-$HOME/fastPLS_bench_0.99.39}"
FASTPLS_LIB="${FASTPLS_LIB:-$HOME/Rlib_fastPLS_0.99.39}"
RESULTS_ROOT="${RESULTS_ROOT:-$HOME/fastPLS_results_0.99.39/current_release}"
TASK_ROOT="${TASK_ROOT:-$HOME/fastPLS_tasks_0.99.37}"
NMR_INPUT="${NMR_INPUT:-$HOME/Documents/fastpls/data/nmr.RData}"
IMAGENET_TASK="${IMAGENET_TASK:-$HOME/Documents/fastpls/data/imagenet_float32_seed123_train1000000_task.rds}"
CIFAR_INPUT="${CIFAR_INPUT:-$HOME/Documents/fastpls/data/CIFAR100.RData}"
IKPLS_PYTHONPATH="${IKPLS_PYTHONPATH:-$HOME/ikpls_bench_py}"
PARENT_PID="${PARENT_PID:-}"

if [ -n "${PARENT_PID}" ]; then
    echo "[WAIT] $(date --iso-8601=seconds) pid=${PARENT_PID}"
    while kill -0 "${PARENT_PID}" 2>/dev/null; do
        sleep 60
    done
fi

mkdir -p "${RESULTS_ROOT}/queue_logs"

echo "[IKPLS_FLOAT64] $(date --iso-8601=seconds)"
FASTPLS_BENCH_LIB="${FASTPLS_LIB}" \
FASTPLS_METREF_TASK="${TASK_ROOT}/metref_task.rds" \
FASTPLS_CIFAR_RDATA="${CIFAR_INPUT}" \
PYTHONPATH="${IKPLS_PYTHONPATH}${PYTHONPATH:+:${PYTHONPATH}}" \
python3 "${SOURCE_ROOT}/benchmark/ikpls_cross_language/run_benchmark.py" \
    "${RESULTS_ROOT}/ikpls_cross_language_cpu" \
    >"${RESULTS_ROOT}/queue_logs/ikpls_float64.log" 2>&1

prepared="${RESULTS_ROOT}/ikpls_large_float32/prepared"
results="${RESULTS_ROOT}/ikpls_large_float32"
mkdir -p "${prepared}" "${results}"

echo "[IKPLS_NMR_PREPARE] $(date --iso-8601=seconds)"
Rscript "${SOURCE_ROOT}/benchmark/ikpls_cross_language/export_large_float32.R" \
    nmr "${NMR_INPUT}" "${prepared}/nmr" \
    >"${RESULTS_ROOT}/queue_logs/ikpls_nmr_prepare.log" 2>&1

echo "[IKPLS_IMAGENET_PREPARE] $(date --iso-8601=seconds)"
R_LIBS_USER="${FASTPLS_LIB}" \
Rscript "${SOURCE_ROOT}/benchmark/ikpls_cross_language/export_large_float32.R" \
    imagenet "${IMAGENET_TASK}" "${prepared}/imagenet" \
    >"${RESULTS_ROOT}/queue_logs/ikpls_imagenet_export.log" 2>&1
python3 "${SOURCE_ROOT}/benchmark/ikpls_cross_language/prepare_imagenet_float32.py" \
    "${prepared}/imagenet" \
    >"${RESULTS_ROOT}/queue_logs/ikpls_imagenet_prepare.log" 2>&1

echo "[IKPLS_LARGE_FLOAT32] $(date --iso-8601=seconds)"
PYTHONPATH="${IKPLS_PYTHONPATH}${PYTHONPATH:+:${PYTHONPATH}}" \
python3 "${SOURCE_ROOT}/benchmark/ikpls_cross_language/run_large_float32.py" \
    --data-root "${prepared}" \
    --results "${results}" \
    --datasets nmr,imagenet \
    --nmr-components 1,5 \
    --imagenet-components 100,200,500,1000 \
    --timeout 10000 \
    --nmr-memory-limit-gib 10 \
    >"${RESULTS_ROOT}/queue_logs/ikpls_large_float32.log" 2>&1

python3 "${SOURCE_ROOT}/benchmark/ikpls_cross_language/summarize_large_float32.py" \
    "${results}" \
    --fastpls-imagenet "${RESULTS_ROOT}/imagenet/imagenet_current_summary.csv" \
    >"${RESULTS_ROOT}/queue_logs/ikpls_large_float32_summary.log" 2>&1

echo "[DONE] $(date --iso-8601=seconds)"
