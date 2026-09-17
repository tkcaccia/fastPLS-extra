#!/usr/bin/env bash

set -euo pipefail

SOURCE_ROOT="${SOURCE_ROOT:-$HOME/fastPLS_bench_0.99.39}"
FASTPLS_LIB="${FASTPLS_LIB:-$HOME/Rlib_fastPLS_0.99.39_candidate}"
NMR_INPUT="${NMR_INPUT:-$HOME/Documents/fastpls/data/nmr.RData}"
OUT_ROOT="${OUT_ROOT:-$HOME/fastPLS_results_0.99.39/current_release/nmr_exact_candidate}"
REPLICATES="${REPLICATES:-3}"
SEED="${SEED:-123}"
TIMEOUT_SEC="${TIMEOUT_SEC:-10000}"

runner="${SOURCE_ROOT}/benchmark/benchmark_nmr_qualified_solver.R"
mkdir -p "${OUT_ROOT}"

run_one() {
    local family="$1"
    local backend="$2"
    local ncomp="$3"
    local stem="fixed${ncomp}_${family}_${backend}_rsvd_k${ncomp}"
    local csv_path="${OUT_ROOT}/${stem}.csv"
    echo "[RUN] ${stem} $(date --iso-8601=seconds)"
    FASTPLS_LIB="${FASTPLS_LIB}" \
        /usr/bin/time -v timeout --signal=TERM --kill-after=30s "${TIMEOUT_SEC}" \
        Rscript "${runner}" \
        --input="${NMR_INPUT}" \
        --output="${csv_path}" \
        --prediction_output="${OUT_ROOT}/${stem}_prediction.rds" \
        --family="${family}" \
        --backend="${backend}" \
        --solver=rsvd \
        --ncomp="${ncomp}" \
        --seed="${SEED}" \
        --replicates="${REPLICATES}" \
        >"${OUT_ROOT}/${stem}.log" \
        2>"${OUT_ROOT}/${stem}.time"
}

for specification in \
    "simpls cpu 50" \
    "simpls cuda 50" \
    "plssvd cpu 50" \
    "plssvd cuda 50" \
    "simpls cpu 165" \
    "simpls cuda 165" \
    "plssvd cpu 165" \
    "plssvd cuda 165"
do
    read -r family backend ncomp <<<"${specification}"
    run_one "${family}" "${backend}" "${ncomp}"
done
