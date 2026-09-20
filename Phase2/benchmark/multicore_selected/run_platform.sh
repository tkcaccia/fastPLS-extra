#!/usr/bin/env bash
set -euo pipefail

PHASE2_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPOSITORY_ROOT="$(cd "${PHASE2_ROOT}/.." && pwd)"
: "${FASTPLS_MULTICORE_LIB:?Set FASTPLS_MULTICORE_LIB to the private fastPLS library}"
: "${FASTPLS_MULTICORE_TASKS:?Set FASTPLS_MULTICORE_TASKS to the prepared task directory}"
: "${FASTPLS_MULTICORE_OUT:?Set FASTPLS_MULTICORE_OUT outside the Git checkout}"

EXPECTED_VERSION="${FASTPLS_MULTICORE_VERSION:-0.99.65}"
SOURCE_ID="${FASTPLS_MULTICORE_SOURCE_ID:-current-release}"
CONTRACT="${PHASE2_ROOT}/benchmark/multicore_selected/figure2_component_contract.csv"
RUNNER="${REPOSITORY_ROOT}/Phase1/benchmark/current_release_evidence/run_selected_backends.py"
DATASETS=(
    ccle cifar100 gtex_v8 metref retina tabula tcga_brca
    tcga_hnsc_methylation tcga_pan_cancer cbmc_citeseq prism nmr imagenet
)

mkdir -p "${FASTPLS_MULTICORE_OUT}"
for cores in 1 4; do
    export FASTPLS_BENCHMARK_NCORES="${cores}"
    export OMP_NUM_THREADS="${cores}"
    export OPENBLAS_NUM_THREADS="${cores}"
    export GOTO_NUM_THREADS="${cores}"
    export MKL_NUM_THREADS="${cores}"
    export BLIS_NUM_THREADS="${cores}"
    export VECLIB_MAXIMUM_THREADS="${cores}"
    python3 "${RUNNER}" \
        --library "${FASTPLS_MULTICORE_LIB}" \
        --task-dir "${FASTPLS_MULTICORE_TASKS}" \
        --selected "${CONTRACT}" \
        --output "${FASTPLS_MULTICORE_OUT}/cores_${cores}_raw.csv" \
        --backends cpu \
        --precision float32 \
        --classifiers argmax \
        --repetitions 3 \
        --timeout-sec 14400 \
        --source-id "${SOURCE_ID}" \
        --expected-version "${EXPECTED_VERSION}" \
        --datasets "${DATASETS[@]}" \
        --families plssvd simpls opls kernelpls \
        --resume
done

Rscript -e 'library(fastPLS, lib.loc=Sys.getenv("FASTPLS_MULTICORE_LIB")); cat(paste0("package_version=", packageVersion("fastPLS"), "\nblas=", fastPLS_blas(details = FALSE), "\n"))' \
    > "${FASTPLS_MULTICORE_OUT}/numerical_library.txt"
