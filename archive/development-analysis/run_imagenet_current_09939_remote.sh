#!/usr/bin/env bash
set -euo pipefail

: "${SOURCE_ROOT:?Set SOURCE_ROOT to the transferred fastPLS source}"
: "${PACKAGE_LIB:?Set PACKAGE_LIB to the installed candidate library}"
: "${DEPENDENCY_LIB:?Set DEPENDENCY_LIB to the dependency library}"
: "${TASK_RDS:?Set TASK_RDS to the prepared ImageNet task}"
: "${OUTPUT_DIR:=${FASTPLS_RESULTS_ROOT:+${FASTPLS_RESULTS_ROOT}/imagenet}}"
: "${OUTPUT_DIR:?Set OUTPUT_DIR or FASTPLS_RESULTS_ROOT outside Git}"
NCOMP_GRID="${NCOMP_GRID:-100,200,300,400,500,600,700,800,900,1000}"

mkdir -p "${OUTPUT_DIR}"

run_classifier() {
    local classifier="$1"
    local output_csv="${OUTPUT_DIR}/imagenet_current_0.99.39_${classifier}.csv"
    local log_file="${OUTPUT_DIR}/imagenet_current_0.99.39_${classifier}.log"

    TASK_RDS="${TASK_RDS}" \
    OUTPUT_CSV="${output_csv}" \
    CLASSIFIER="${classifier}" \
    NCOMP_GRID="${NCOMP_GRID}" \
    SEED=123 \
    Rscript --vanilla -e \
        ".libPaths(c('${PACKAGE_LIB}','${DEPENDENCY_LIB}',.libPaths())); source('${SOURCE_ROOT}/benchmark/benchmark_imagenet_current_fused_lda.R', chdir=TRUE)" \
        >"${log_file}" 2>&1
}

Rscript --vanilla -e \
    ".libPaths(c('${PACKAGE_LIB}','${DEPENDENCY_LIB}',.libPaths())); library(fastPLS); stopifnot(as.character(packageVersion('fastPLS')) == '0.99.39', has_cuda()); cat(find.package('fastPLS'), '\n')" \
    >"${OUTPUT_DIR}/loaded_package.log" 2>&1

run_classifier argmax
run_classifier lda

date -Iseconds >"${OUTPUT_DIR}/completed_at.txt"
