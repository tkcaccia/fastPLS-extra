#!/usr/bin/env bash
set -euo pipefail

# Final fixed-workload CV matrix for CIFAR-100 and NMR. This script only
# orchestrates the existing package API; cache-off is an internal validation
# ablation and does not add a user-facing modelling parameter.

: "${FASTPLS_BENCH_LIB:?Set FASTPLS_BENCH_LIB to the installed package library}"
: "${FASTPLS_CIFAR_TASK:?Set FASTPLS_CIFAR_TASK to cifar100_task.rds}"
: "${FASTPLS_NMR_TASK:?Set FASTPLS_NMR_TASK to nmr_masked_task.rds}"
: "${FASTPLS_CV_OUTPUT:?Set FASTPLS_CV_OUTPUT outside the Git repository}"

script_dir="$(cd "$(dirname "$0")" && pwd)"
backends="${FASTPLS_CV_BACKENDS:-cpu}"
repetitions="${FASTPLS_CV_REPETITIONS:-5}"
validation_repetitions="${FASTPLS_CV_VALIDATION_REPETITIONS:-1}"
seed="${FASTPLS_CV_SEED:-123}"

mkdir -p "${FASTPLS_CV_OUTPUT}/rows" "${FASTPLS_CV_OUTPUT}/logs"

run_cell() {
    local dataset="$1" task="$2" method="$3" ncomp="$4"
    local backend="$5" workload="$6" cache="$7" replicate="$8"
    local id="${dataset}__${method}__${backend}__${workload}__cache-${cache}__r${replicate}"
    local output="${FASTPLS_CV_OUTPUT}/rows/${id}.csv"
    local log="${FASTPLS_CV_OUTPUT}/logs/${id}.log"
    if [[ -s "${output}" ]]; then
        echo "[SKIP] ${id}"
        return
    fi
    echo "[RUN] ${id}"
    Rscript "${script_dir}/worker.R" \
        --library="${FASTPLS_BENCH_LIB}" \
        --task="${task}" \
        --output="${output}" \
        --backend="${backend}" \
        --precision=float32 \
        --method="${method}" \
        --classifier=argmax \
        --ncomp="${ncomp}" \
        --kfold=10 \
        --seed="${seed}" \
        --context-mode=cold \
        --workload="${workload}" \
        --fold-cache="${cache}" \
        --replicate="${replicate}" >"${log}" 2>&1
}

for backend in ${backends//,/ }; do
    for specification in \
        "cifar100|${FASTPLS_CIFAR_TASK}|plssvd|99" \
        "cifar100|${FASTPLS_CIFAR_TASK}|simpls|298" \
        "nmr|${FASTPLS_NMR_TASK}|plssvd|5" \
        "nmr_matched50|${FASTPLS_NMR_TASK}|plssvd|50" \
        "nmr|${FASTPLS_NMR_TASK}|simpls|50"; do
        IFS='|' read -r dataset task method ncomp <<<"${specification}"
        for replicate in $(seq 1 "${repetitions}"); do
            run_cell "${dataset}" "${task}" "${method}" "${ncomp}" \
                "${backend}" cv on "${replicate}"
            run_cell "${dataset}" "${task}" "${method}" "${ncomp}" \
                "${backend}" one_fold on "${replicate}"
        done
        for replicate in $(seq 1 "${validation_repetitions}"); do
            run_cell "${dataset}" "${task}" "${method}" "${ncomp}" \
                "${backend}" cv off "${replicate}"
        done
    done
done

Rscript - "${FASTPLS_CV_OUTPUT}/rows" "${FASTPLS_CV_OUTPUT}/raw.csv" <<'RS'
args <- commandArgs(TRUE)
paths <- list.files(args[[1L]], pattern = "[.]csv$", full.names = TRUE)
if (!length(paths)) stop("No benchmark rows were produced.", call. = FALSE)
rows <- lapply(paths, read.csv, stringsAsFactors = FALSE, check.names = FALSE)
write.csv(do.call(rbind, rows), args[[2L]], row.names = FALSE)
RS
Rscript "${script_dir}/summarize.R" \
    "${FASTPLS_CV_OUTPUT}/raw.csv" \
    "${FASTPLS_CV_OUTPUT}/summary.csv"

echo "[DONE] ${FASTPLS_CV_OUTPUT}"
