#!/usr/bin/env bash
set -euo pipefail

: "${SOURCE_ROOT:?Set SOURCE_ROOT to the transferred fastPLS-extra source}"
: "${PACKAGE_LIB:?Set PACKAGE_LIB to the current fastPLS library}"
: "${DEPENDENCY_LIB:?Set DEPENDENCY_LIB to the dependency library}"
: "${TASK_RDS:?Set TASK_RDS to the prepared ImageNet task}"
: "${OUTPUT_DIR:?Set OUTPUT_DIR outside the package repositories}"

NCOMP_GRID="${NCOMP_GRID:-50,100,200,300,400,500,600,700,800,900,1000}"
METHODS="${METHODS:-plssvd simpls opls kernelpls}"
mkdir -p "${OUTPUT_DIR}"

for method in ${METHODS}; do
    for classifier in argmax lda; do
        output_csv="${OUTPUT_DIR}/imagenet_${method}_${classifier}.csv"
        log_file="${OUTPUT_DIR}/imagenet_${method}_${classifier}.log"
        TASK_RDS="${TASK_RDS}" \
        OUTPUT_CSV="${output_csv}" \
        METHOD="${method}" \
        CLASSIFIER="${classifier}" \
        NCOMP_GRID="${NCOMP_GRID}" \
        PRECISION=float32 \
        OVERSAMPLE=32 \
        POWER=5 \
        SEED=123 \
        FASTPLS_LIB="${PACKAGE_LIB}" \
        FASTPLS_SOURCE_ID="${FASTPLS_SOURCE_ID:-unrecorded}" \
        R_LIBS_USER="${PACKAGE_LIB}:${DEPENDENCY_LIB}" \
        Rscript --vanilla \
            "${SOURCE_ROOT}/benchmark/benchmark_imagenet_current_fused_lda.R" \
            >"${log_file}" 2>&1
    done
done

Rscript --vanilla -e '
files <- list.files(commandArgs(TRUE)[1], pattern = "^imagenet_.*\\.csv$", full.names = TRUE)
rows <- lapply(files, read.csv, check.names = FALSE)
write.csv(do.call(rbind, rows), commandArgs(TRUE)[2], row.names = FALSE, na = "")
' "${OUTPUT_DIR}" "${OUTPUT_DIR}/imagenet_four_family_component_paths.csv"
