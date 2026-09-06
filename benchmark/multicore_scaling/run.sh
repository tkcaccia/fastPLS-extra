#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${FASTPLS_RESULTS_ROOT:?Set FASTPLS_RESULTS_ROOT outside the Git checkouts}"
: "${FASTPLS_MULTICORE_LIB:?Set FASTPLS_MULTICORE_LIB to the installed candidate library}"
OUT="${FASTPLS_MULTICORE_OUT:-${FASTPLS_RESULTS_ROOT}/multicore_scaling}"
LIB="${FASTPLS_MULTICORE_LIB}"
PROBE_DIR="${OUT}/probe"
PROBE="${PROBE_DIR}/openblas_probe.so"
RAW="${OUT}/multicore_scaling_raw.csv"
OPENBLAS_ROOT="${OPENBLAS_ROOT:-/opt/homebrew/opt/openblas}"
if [[ "$(uname -s)" == "Linux" ]]; then
    # R may already expose reference-BLAS symbols. Isolate the optimized
    # provider in these workers only, without changing the system R setup.
    export LD_LIBRARY_PATH="${OPENBLAS_ROOT}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
    export LD_PRELOAD="${OPENBLAS_ROOT}/lib/libopenblas.so${LD_PRELOAD:+:${LD_PRELOAD}}"
fi
BASE_R_LIBS="$(Rscript -e 'cat(paste(.libPaths(), collapse=.Platform$path.sep))')"
export R_LIBS="${LIB}${BASE_R_LIBS:+:${BASE_R_LIBS}}"
export R_LIBS_USER="${R_LIBS}"

mkdir -p "${PROBE_DIR}"
rm -f "${RAW}"

# Compile the probe outside the source snapshot so benchmarks never mutate it.
cp "${ROOT}/benchmark/multicore_scaling/openblas_probe.c" "${PROBE_DIR}/openblas_probe.c"
PKG_CPPFLAGS="-I${OPENBLAS_ROOT}/include" \
PKG_LIBS="-L${OPENBLAS_ROOT}/lib -lopenblas" \
R CMD SHLIB "${PROBE_DIR}/openblas_probe.c" \
    -o "${PROBE}"

if [[ "$(uname -s)" == "Linux" ]]; then
    OPENBLAS_NUM_THREADS=1 LD_DEBUG=bindings Rscript --vanilla -e '
        suppressPackageStartupMessages(library(fastPLS))
        set.seed(1)
        x <- matrix(rnorm(2000), 100)
        invisible(pls(x, rnorm(100), ncomp=3, backend="cpu"))
    ' 2> "${OUT}/blas_bindings.log"
    python3 "${ROOT}/benchmark/multicore_scaling/verify_blas_bindings.py" \
        "${OUT}/blas_bindings.log"
fi

workloads=(
    "sample-rich classification"
    "predictor-wide regression"
    "response-wide regression"
)

for workload in "${workloads[@]}"; do
    for cores in 1 2 4; do
        for replicate in 1 2 3 4 5; do
            OPENBLAS_NUM_THREADS="${cores}" \
            OMP_NUM_THREADS="${cores}" \
            FASTPLS_MULTICORE_LIB="${LIB}" \
            FASTPLS_OPENBLAS_PROBE="${PROBE}" \
            Rscript "${ROOT}/benchmark/multicore_scaling/worker.R" \
                "${workload}" "${cores}" "${replicate}" "${RAW}"
        done
    done
done

Rscript "${ROOT}/benchmark/multicore_scaling/summarize.R" "${RAW}" "${OUT}"
rm -rf "${PROBE_DIR}"
