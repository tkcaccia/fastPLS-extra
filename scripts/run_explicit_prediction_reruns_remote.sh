#!/usr/bin/env bash
set -euo pipefail

SOURCE_ROOT="${SOURCE_ROOT:-$HOME/fastPLS_bench_0.99.39}"
FASTPLS_LIB="${FASTPLS_LIB:-$HOME/Rlib_fastPLS_0.99.39}"
RESULTS_ROOT="${RESULTS_ROOT:-$HOME/fastPLS_results_0.99.39/publication_exact}"
TASK_ROOT="${TASK_ROOT:-$HOME/fastPLS_tasks_0.99.39}"
NMR_INPUT="${NMR_INPUT:-$HOME/Documents/fastpls/data/nmr.RData}"
PARENT_PID="${PARENT_PID:-}"

mkdir -p "${RESULTS_ROOT}/queue_logs"

if [ -n "${PARENT_PID}" ]; then
    echo "[WAIT] $(date --iso-8601=seconds) pid=${PARENT_PID}"
    while kill -0 "${PARENT_PID}" 2>/dev/null; do
        sleep 60
    done
fi

echo "[CONTROLLED_SCALING] $(date --iso-8601=seconds)"
FASTPLS_SCALING_SKIP_INSTALL=true \
FASTPLS_SCALING_LIB="${FASTPLS_LIB}" \
FASTPLS_SCALING_EXPECTED_VERSION=0.99.39 \
FASTPLS_SCALING_TIMEOUT_SEC=600 \
bash "${SOURCE_ROOT}/scripts/run_controlled_scaling.sh" \
    "${RESULTS_ROOT}/controlled_scaling_cuda_explicit_prediction" \
    publication cpu,cuda 3 \
    >"${RESULTS_ROOT}/queue_logs/controlled_scaling_explicit_prediction.log" 2>&1

echo "[SELECTED_BACKEND] $(date --iso-8601=seconds)"
FASTPLS_BENCH_LIB="${FASTPLS_LIB}" \
FASTPLS_MATCHED_ACCELERATOR=cuda \
FASTPLS_SELECTED_COMPONENTS_CSV="${RESULTS_ROOT}/component_selection/selected_components.csv" \
FASTPLS_METAL_MATCHED_TASK_ROOT="${TASK_ROOT}" \
Rscript "${SOURCE_ROOT}/benchmark/metal_validation/run_matched_cuda_dataset_metal.R" \
    "${RESULTS_ROOT}/backend_selected/cuda_explicit_prediction" \
    >"${RESULTS_ROOT}/queue_logs/backend_selected_cuda_explicit_prediction.log" 2>&1

echo "[NMR_SELECTED_CUDA] $(date --iso-8601=seconds)"
nmr_out="${RESULTS_ROOT}/nmr/explicit_backend_prediction_cuda"
mkdir -p "${nmr_out}"
for specification in \
    "plssvd 5 selected" \
    "simpls 50 selected"
do
    read -r family ncomp analysis <<<"${specification}"
    stem="${analysis}_${family}_cuda_rsvd_k${ncomp}"
    FASTPLS_LIB="${FASTPLS_LIB}" Rscript \
        "${SOURCE_ROOT}/benchmark/benchmark_nmr_qualified_solver.R" \
        --input="${NMR_INPUT}" \
        --output="${nmr_out}/${stem}.csv" \
        --prediction_output="${nmr_out}/${stem}_prediction.rds" \
        --family="${family}" \
        --backend=cuda \
        --solver=rsvd \
        --ncomp="${ncomp}" \
        --seed=123 \
        --replicates=3 \
        >"${nmr_out}/${stem}.log" 2>&1
done

echo "[DONE] $(date --iso-8601=seconds)"
