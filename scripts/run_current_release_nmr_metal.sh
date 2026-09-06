#!/usr/bin/env bash

# Current-release Apple Metal NMR benchmark with process-level timing.

set -euo pipefail

WAIT_PID="${WAIT_PID:-}"
REPO_ROOT="${FASTPLS_EXTRA_ROOT:-$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)}"
: "${FASTPLS_LIB:?Set FASTPLS_LIB to the installed candidate library}"
: "${NMR_INPUT:=${FASTPLS_NMR_INPUT:-}}"
: "${NMR_INPUT:?Set NMR_INPUT or FASTPLS_NMR_INPUT}"
: "${OUTPUT_DIR:=${FASTPLS_RESULTS_ROOT:+${FASTPLS_RESULTS_ROOT}/nmr_metal}}"
: "${OUTPUT_DIR:?Set OUTPUT_DIR or FASTPLS_RESULTS_ROOT outside Git}"
REPLICATES="${REPLICATES:-3}"
SELECTED_PLSSVD_NCOMP="${SELECTED_PLSSVD_NCOMP:-}"
SELECTED_SIMPLS_NCOMP="${SELECTED_SIMPLS_NCOMP:-}"

if [ -n "${WAIT_PID}" ]; then
    while kill -0 "${WAIT_PID}" 2>/dev/null; do
        sleep 30
    done
fi

mkdir -p "${OUTPUT_DIR}"

FASTPLS_LIB="${FASTPLS_LIB}" Rscript -e '
lib <- Sys.getenv("FASTPLS_LIB")
.libPaths(unique(c(lib, .libPaths())))
stopifnot(as.character(packageVersion("fastPLS")) == "0.99.39")
stopifnot(isTRUE(fastPLS::has_metal()))
'

for specification in \
    "simpls 50" \
    "plssvd 50" \
    "simpls 165" \
    "plssvd 165"
do
    read -r family ncomp <<<"${specification}"
    stem="fixed${ncomp}_${family}_metal_rsvd_k${ncomp}"
    if [ -s "${OUTPUT_DIR}/${stem}.csv" ]; then
        continue
    fi
    FASTPLS_LIB="${FASTPLS_LIB}" /usr/bin/time -l Rscript \
        "${REPO_ROOT}/benchmark/benchmark_nmr_qualified_solver.R" \
        --input="${NMR_INPUT}" \
        --output="${OUTPUT_DIR}/${stem}.csv" \
        --prediction_output="${OUTPUT_DIR}/${stem}_prediction.rds" \
        --family="${family}" \
        --backend=metal \
        --solver=rsvd \
        --ncomp="${ncomp}" \
        --seed=123 \
        --replicates="${REPLICATES}" \
        >"${OUTPUT_DIR}/${stem}.log" 2>"${OUTPUT_DIR}/${stem}.time"
done

for specification in \
    "plssvd ${SELECTED_PLSSVD_NCOMP}" \
    "simpls ${SELECTED_SIMPLS_NCOMP}"
do
    read -r family ncomp <<<"${specification}"
    if [ -z "${ncomp}" ]; then
        continue
    fi
    stem="selected_${family}_metal_rsvd_k${ncomp}"
    if [ -s "${OUTPUT_DIR}/${stem}.csv" ]; then
        continue
    fi
    FASTPLS_LIB="${FASTPLS_LIB}" /usr/bin/time -l Rscript \
        "${REPO_ROOT}/benchmark/benchmark_nmr_qualified_solver.R" \
        --input="${NMR_INPUT}" \
        --output="${OUTPUT_DIR}/${stem}.csv" \
        --prediction_output="${OUTPUT_DIR}/${stem}_prediction.rds" \
        --family="${family}" \
        --backend=metal \
        --solver=rsvd \
        --ncomp="${ncomp}" \
        --seed=123 \
        --replicates="${REPLICATES}" \
        >"${OUTPUT_DIR}/${stem}.log" 2>"${OUTPUT_DIR}/${stem}.time"
done

echo "Metal NMR benchmark complete: ${OUTPUT_DIR}"
