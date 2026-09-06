#!/usr/bin/env bash
set -euo pipefail

: "${WAIT_PID:?Set WAIT_PID to the process that must finish first}"
: "${SOURCE_ROOT:?Set SOURCE_ROOT to the transferred fastPLS source}"
: "${PACKAGE_LIB:?Set PACKAGE_LIB to the installed candidate library}"
: "${DEPENDENCY_LIB:?Set DEPENDENCY_LIB to the dependency library}"
: "${OUTPUT_DIR:=${FASTPLS_RESULTS_ROOT:+${FASTPLS_RESULTS_ROOT}/imagenet}}"
: "${OUTPUT_DIR:?Set OUTPUT_DIR or FASTPLS_RESULTS_ROOT outside Git}"
: "${NMR_INPUT:=${FASTPLS_NMR_INPUT:-}}"
: "${NMR_INPUT:?Set NMR_INPUT or FASTPLS_NMR_INPUT}"
: "${NMR_OUTPUT_DIR:=${FASTPLS_RESULTS_ROOT:+${FASTPLS_RESULTS_ROOT}/nmr_cuda}}"
: "${NMR_OUTPUT_DIR:?Set NMR_OUTPUT_DIR or FASTPLS_RESULTS_ROOT outside Git}"

while kill -0 "${WAIT_PID}" 2>/dev/null; do
    sleep 60
done

# Require two idle observations so a just-finished controller cannot race a
# final child process or delayed CUDA-context teardown.
idle_checks=0
while (( idle_checks < 2 )); do
    if [[ -z "$(nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null)" ]]; then
        idle_checks=$((idle_checks + 1))
    else
        idle_checks=0
    fi
    sleep 30
done

mkdir -p "${NMR_OUTPUT_DIR}"
for family in plssvd simpls; do
    for ncomp in 50 165; do
        output_csv="${NMR_OUTPUT_DIR}/${family}_cuda_float32_${ncomp}.csv"
        log_file="${NMR_OUTPUT_DIR}/${family}_cuda_float32_${ncomp}.log"
        Rscript --vanilla -e \
            ".libPaths(c('${PACKAGE_LIB}','${DEPENDENCY_LIB}',.libPaths())); source('${SOURCE_ROOT}/benchmark/benchmark_nmr_qualified_solver.R', chdir=TRUE)" \
            --args \
            "--input=${NMR_INPUT}" \
            "--output=${output_csv}" \
            "--family=${family}" \
            --backend=cuda \
            --solver=rsvd \
            "--ncomp=${ncomp}" \
            --precision=float32 \
            --seed=123 \
            --replicates=3 \
            >"${log_file}" 2>&1
    done
done
date -Iseconds >"${NMR_OUTPUT_DIR}/completed_at.txt"

stamp="$(date +%Y%m%dT%H%M%S)"
if [[ -d "${OUTPUT_DIR}" ]]; then
    mv "${OUTPUT_DIR}" "${OUTPUT_DIR}_preliminary_${stamp}"
fi

exec "${SOURCE_ROOT}/benchmark/run_imagenet_current_09939_remote.sh"
