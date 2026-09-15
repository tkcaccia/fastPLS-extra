#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${FASTPLS_PRECISION_LIB:?Set FASTPLS_PRECISION_LIB to the private fastPLS library}"
: "${FASTPLS_PRECISION_TASKS:?Set FASTPLS_PRECISION_TASKS to the prepared task directory}"
: "${FASTPLS_PRECISION_OUT:?Set FASTPLS_PRECISION_OUT outside the Git checkout}"
: "${FASTPLS_PRECISION_BACKENDS:?Set FASTPLS_PRECISION_BACKENDS to cpu or 'cpu cuda'}"

EXPECTED_VERSION="${FASTPLS_PRECISION_VERSION:-0.99.65}"
SOURCE_ID="${FASTPLS_PRECISION_SOURCE_ID:-current-release}"
CONTRACT="${ROOT}/benchmark/multicore_selected/figure2_component_contract.csv"
RUNNER="${ROOT}/benchmark/current_release_evidence/run_selected_backends.py"
DATASETS=(
    ccle cifar100 gtex_v8 metref retina tabula tcga_brca
    tcga_hnsc_methylation tcga_pan_cancer cbmc_citeseq prism nmr imagenet
)
read -r -a BACKENDS <<< "${FASTPLS_PRECISION_BACKENDS}"

mkdir -p "${FASTPLS_PRECISION_OUT}"
export FASTPLS_BENCHMARK_NCORES=1
export OMP_NUM_THREADS=1
export OPENBLAS_NUM_THREADS=1
export GOTO_NUM_THREADS=1
export MKL_NUM_THREADS=1
export BLIS_NUM_THREADS=1
export VECLIB_MAXIMUM_THREADS=1

python3 "${RUNNER}" \
    --library "${FASTPLS_PRECISION_LIB}" \
    --task-dir "${FASTPLS_PRECISION_TASKS}" \
    --selected "${CONTRACT}" \
    --output "${FASTPLS_PRECISION_OUT}/float64_raw.csv" \
    --backends "${BACKENDS[@]}" \
    --precision float64 \
    --classifiers argmax \
    --repetitions 3 \
    --timeout-sec 14400 \
    --source-id "${SOURCE_ID}" \
    --expected-version "${EXPECTED_VERSION}" \
    --datasets "${DATASETS[@]}" \
    --families plssvd simpls opls kernelpls \
    --resume

Rscript -e 'library(fastPLS, lib.loc=Sys.getenv("FASTPLS_PRECISION_LIB")); cat(paste0("package_version=", packageVersion("fastPLS"), "\nblas=", fastPLS_blas(), "\n"))' \
    > "${FASTPLS_PRECISION_OUT}/numerical_library.txt"

