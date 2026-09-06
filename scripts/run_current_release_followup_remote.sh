#!/usr/bin/env bash
set -euo pipefail

SOURCE_ROOT="${SOURCE_ROOT:-$HOME/fastPLS_bench_0.99.39}"
FASTPLS_LIB="${FASTPLS_LIB:-$HOME/Rlib_fastPLS_0.99.39}"
NMR_INPUT="${NMR_INPUT:-$HOME/Documents/fastpls/data/nmr.RData}"
NMR_OUT="${NMR_OUT:-$HOME/fastPLS_results_0.99.39/current_release/nmr}"
IMAGENET_OUT="${OUTPUT_DIR:-$HOME/fastPLS_results_0.99.39/current_release/imagenet}"
REFERENCE_SOURCE="${REFERENCE_SOURCE:-$HOME/fastPLS_nmr_reference_compare_20260725/benchmark/deposited_FastPLS.R}"
PARENT_PID="${PARENT_PID:-}"

if [ -n "${PARENT_PID}" ]; then
    while kill -0 "${PARENT_PID}" 2>/dev/null; do sleep 60; done
fi

mkdir -p "${NMR_OUT}"

selection_grid="1,2,3,5,10,25,50,75,100,125,150,165,175,200,250,300"
selection_runner="${SOURCE_ROOT}/benchmark/benchmark_nmr_component_selection.R"
for family in plssvd simpls; do
    selection_dir="${NMR_OUT}/selection_${family}"
    if test -s "${selection_dir}/nmr_component_selection_decision.csv"; then
        continue
    fi
    mkdir -p "${selection_dir}"
    FASTPLS_LIB="${FASTPLS_LIB}" R_LIBS_USER="${FASTPLS_LIB}" \
        Rscript "${selection_runner}" \
        --input="${NMR_INPUT}" --out="${selection_dir}" --backend=cuda \
        --method="${family}" --grid="${selection_grid}" \
        --seeds=123,456,789,1011,2027 \
        --fit_seed=123 >"${selection_dir}.log" 2>&1
done

selected_component() {
    Rscript -e 'x <- read.csv(commandArgs(TRUE)[1]); cat(x$selected_ncomp[[1]])' "$1"
}
plssvd_k="$(selected_component "${NMR_OUT}/selection_plssvd/nmr_component_selection_decision.csv")"
simpls_k="$(selected_component "${NMR_OUT}/selection_simpls/nmr_component_selection_decision.csv")"

run_selected() {
    local family="$1" backend="$2" solver="$3" ncomp="$4"
    local stem="selected_${family}_${backend}_${solver}_k${ncomp}"
    if test -s "${NMR_OUT}/${stem}.csv"; then return 0; fi
    FASTPLS_LIB="${FASTPLS_LIB}" R_LIBS_USER="${FASTPLS_LIB}" \
        /usr/bin/time -v timeout --signal=TERM --kill-after=30s 10000 \
        Rscript "${SOURCE_ROOT}/benchmark/benchmark_nmr_qualified_solver.R" \
        --input="${NMR_INPUT}" --output="${NMR_OUT}/${stem}.csv" \
        --prediction_output="${NMR_OUT}/${stem}_prediction.rds" \
        --family="${family}" --backend="${backend}" --solver="${solver}" \
        --ncomp="${ncomp}" --seed=123 \
        --replicates=3 >"${NMR_OUT}/${stem}.log" 2>"${NMR_OUT}/${stem}.time"
}

for specification in \
    "plssvd cpu irlba ${plssvd_k}" \
    "plssvd cpu rsvd ${plssvd_k}" \
    "plssvd cuda rsvd ${plssvd_k}" \
    "simpls cpu irlba ${simpls_k}" \
    "simpls cpu rsvd ${simpls_k}" \
    "simpls cuda rsvd ${simpls_k}"
do
    read -r family backend solver ncomp <<<"${specification}"
    run_selected "${family}" "${backend}" "${solver}" "${ncomp}"
done

R_LIBS_USER="${FASTPLS_LIB}" \
    "${SOURCE_ROOT}/scripts/run_nmr_deposited_reference.sh" \
    "${NMR_INPUT}" "${REFERENCE_SOURCE}" "${NMR_OUT}/deposited" \
    "${FASTPLS_LIB}"

REPO_ROOT="${SOURCE_ROOT}" \
RUNNER="${SOURCE_ROOT}/benchmark/benchmark_imagenet_current_fused_lda.R" \
FASTPLS_LIB="${FASTPLS_LIB}" \
TASK_RDS="$HOME/Documents/fastpls/data/imagenet_float32_seed123_train1000000_task.rds" \
OUTPUT_DIR="${IMAGENET_OUT}" \
NCOMP_GRID="100 200 300 400 500 600 700 800 900 1000" \
OVERSAMPLE=auto POWER=auto SEED=123 PRECISION=float32 TIMEOUT_SEC=10000 \
"${SOURCE_ROOT}/scripts/run_imagenet_current_fused_lda_remote.sh"
