#!/usr/bin/env bash
set -euo pipefail

: "${BENCHMARK_ROOT:?Set BENCHMARK_ROOT to the fastPLS-extra checkout}"
: "${FASTPLS_LIB:?Set FASTPLS_LIB to the isolated installed package library}"
: "${INPUT:?Set INPUT to the canonical NMR RData file}"
: "${OUT_ROOT:?Set OUT_ROOT outside all Git checkouts}"

REPLICATES="${REPLICATES:-3}"
SEED="${SEED:-123}"
TIMEOUT_SEC="${TIMEOUT_SEC:-10000}"
RUNNER="${BENCHMARK_ROOT}/benchmark/benchmark_nmr_qualified_solver.R"

mkdir -p "${OUT_ROOT}"

run_one() {
    local family="$1"
    local precision="$2"
    local ncomp="$3"
    local stem="nmr_${family}_cuda_rsvd_${precision}_k${ncomp}"
    local output="${OUT_ROOT}/${stem}.csv"

    if [ -s "${output}" ] &&
        [ "$(wc -l < "${output}")" -eq "$((REPLICATES + 1))" ]; then
        echo "[SKIP] ${stem}"
        return
    fi

    echo "[RUN] ${stem} $(date --iso-8601=seconds)"
    FASTPLS_LIB="${FASTPLS_LIB}" timeout --signal=TERM --kill-after=30s \
        "${TIMEOUT_SEC}" Rscript "${RUNNER}" \
        --input="${INPUT}" \
        --output="${output}" \
        --prediction_output="${OUT_ROOT}/${stem}_prediction.rds" \
        --family="${family}" \
        --backend=cuda \
        --solver=rsvd \
        --precision="${precision}" \
        --ncomp="${ncomp}" \
        --seed="${SEED}" \
        --replicates="${REPLICATES}" \
        >"${OUT_ROOT}/${stem}.log" 2>&1
}

for precision in float32 float64; do
    for ncomp in 50 165; do
        run_one plssvd "${precision}" "${ncomp}"
        run_one simpls "${precision}" "${ncomp}"
    done
done
