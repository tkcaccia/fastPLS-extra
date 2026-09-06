#!/usr/bin/env bash
set -euo pipefail

BENCHMARK_ROOT="${BENCHMARK_ROOT:-$HOME/fastPLS-extra}"
FASTPLS_LIB="${FASTPLS_LIB:-$HOME/Rlib_fastPLS_0.99.39}"
INPUT="${INPUT:-$HOME/Documents/fastpls/data/nmr.RData}"
if [ -z "${OUT_ROOT:-}" ]; then
    echo "Set OUT_ROOT to a directory outside both Git checkouts." >&2
    exit 2
fi
REPLICATES="${REPLICATES:-3}"
OVERSAMPLE="${OVERSAMPLE:-auto}"
POWER="${POWER:-auto}"
SEED="${SEED:-123}"
TIMEOUT_SEC="${TIMEOUT_SEC:-10000}"

runner="${BENCHMARK_ROOT}/benchmark/benchmark_nmr_qualified_solver.R"
mkdir -p "${OUT_ROOT}"

run_one() {
    local family="$1"
    local backend="$2"
    local solver="$3"
    local ncomp="$4"
    local analysis="$5"
    local stem="${analysis}_${family}_${backend}_${solver}_k${ncomp}"
    local csv_path="${OUT_ROOT}/${stem}.csv"
    local control_args=()
    if [ "${OVERSAMPLE}" != "auto" ] || [ "${POWER}" != "auto" ]; then
        control_args+=("--oversample=${OVERSAMPLE}" "--power=${POWER}")
    fi
    if [ -s "${csv_path}" ] && \
        grep -q '"direction_rule"' "${csv_path}" && \
        [ "$(wc -l < "${csv_path}")" -eq "$((REPLICATES + 1))" ]; then
        echo "[SKIP] ${stem} already complete"
        return 0
    fi
    echo "[RUN] ${stem} $(date --iso-8601=seconds)"
    if ! FASTPLS_LIB="${FASTPLS_LIB}" \
        /usr/bin/time -v timeout --signal=TERM --kill-after=30s "${TIMEOUT_SEC}" \
        Rscript "${runner}" \
        --input="${INPUT}" \
        --output="${csv_path}" \
        --prediction_output="${OUT_ROOT}/${stem}_prediction.rds" \
        --family="${family}" \
        --backend="${backend}" \
        --solver="${solver}" \
        --ncomp="${ncomp}" \
        "${control_args[@]}" \
        --seed="${SEED}" \
        --replicates="${REPLICATES}" \
        >"${OUT_ROOT}/${stem}.log" \
        2>"${OUT_ROOT}/${stem}.time"; then
        touch "${OUT_ROOT}/${stem}.failed"
        echo "[FAILED] ${stem}; see ${stem}.log and ${stem}.time"
        return 0
    fi
    rm -f "${OUT_ROOT}/${stem}.failed"
}

for specification in \
    "simpls cuda rsvd 50 fixed50" \
    "simpls cpu rsvd 50 fixed50" \
    "plssvd cuda rsvd 50 fixed50" \
    "plssvd cpu rsvd 50 fixed50" \
    "simpls cpu irlba 50 fixed50" \
    "plssvd cpu irlba 50 fixed50" \
    "simpls cuda rsvd 165 fixed165" \
    "simpls cpu rsvd 165 fixed165" \
    "plssvd cuda rsvd 165 fixed165" \
    "plssvd cpu rsvd 165 fixed165" \
    "simpls cpu irlba 165 fixed165" \
    "plssvd cpu irlba 165 fixed165"
do
    read -r family backend solver ncomp analysis <<<"${specification}"
    run_one "${family}" "${backend}" "${solver}" "${ncomp}" "${analysis}"
done

selection_runner="${BENCHMARK_ROOT}/benchmark/benchmark_nmr_component_selection.R"
selection_grid="${SELECTION_GRID:-1,2,3,5,10,25,50,75,100,125,150,165,175,200,250,300}"
selection_seeds="${SELECTION_SEEDS:-123,456,789,1011,2027}"
for family in plssvd simpls; do
    selection_dir="${OUT_ROOT}/selection_${family}"
    if test -s "${selection_dir}/nmr_component_selection_decision.csv"; then
        echo "[SKIP] selection_${family} already complete"
        continue
    fi
    control_args=()
    if [ "${OVERSAMPLE}" != "auto" ] || [ "${POWER}" != "auto" ]; then
        control_args+=("--oversample=${OVERSAMPLE}" "--power=${POWER}")
    fi
    echo "[SELECT] ${family} $(date --iso-8601=seconds)"
    FASTPLS_LIB="${FASTPLS_LIB}" Rscript "${selection_runner}" \
        --input="${INPUT}" \
        --out="${selection_dir}" \
        --backend=cuda \
        --method="${family}" \
        --grid="${selection_grid}" \
        --seeds="${selection_seeds}" \
        "${control_args[@]}" \
        --fit_seed="${SEED}" \
        >"${selection_dir}.log" 2>&1
done

selected_component() {
    Rscript -e 'x <- read.csv(commandArgs(TRUE)[1]); cat(x$selected_ncomp[[1]])' \
        "$1"
}
plssvd_selected="$(selected_component "${OUT_ROOT}/selection_plssvd/nmr_component_selection_decision.csv")"
simpls_selected="$(selected_component "${OUT_ROOT}/selection_simpls/nmr_component_selection_decision.csv")"

for specification in \
    "plssvd cpu irlba ${plssvd_selected} selected" \
    "plssvd cpu rsvd ${plssvd_selected} selected" \
    "plssvd cuda rsvd ${plssvd_selected} selected" \
    "simpls cpu irlba ${simpls_selected} selected" \
    "simpls cpu rsvd ${simpls_selected} selected" \
    "simpls cuda rsvd ${simpls_selected} selected"
do
    read -r family backend solver ncomp analysis <<<"${specification}"
    run_one "${family}" "${backend}" "${solver}" "${ncomp}" "${analysis}"
done

echo "[DONE] $(date --iso-8601=seconds)"
