#!/usr/bin/env bash
set -euo pipefail

PARENT_PID="${PARENT_PID:-3022364}"
ARCHIVE="${ARCHIVE:-$HOME/fastPLS_0.99.39_corrected.tar.gz}"
LIBRARY="${LIBRARY:-$HOME/Rlib_fastPLS_0.99.39_candidate}"
SMOKE_SCRIPT="${SMOKE_SCRIPT:-$HOME/backend_family_smoke_0.99.39.R}"
RESULTS_ROOT="${RESULTS_ROOT:-$HOME/fastPLS_results_0.99.39/current_release/candidate_validation}"
CUDA_ROOT="${CUDA_ROOT:-/usr/local/cuda}"

mkdir -p "${LIBRARY}" "${RESULTS_ROOT}"
echo "[WAIT] $(date --iso-8601=seconds) protected_pid=${PARENT_PID}"
while kill -0 "${PARENT_PID}" 2>/dev/null; do
    sleep 60
done

echo "[INSTALL] $(date --iso-8601=seconds)"
FASTPLS_USE_CUDA=1 FASTPLS_REQUIRE_CUDA=1 CUDA_ROOT="${CUDA_ROOT}" \
    R CMD INSTALL -l "${LIBRARY}" "${ARCHIVE}" \
    >"${RESULTS_ROOT}/install.log" 2>&1

echo "[VERIFY] $(date --iso-8601=seconds)"
FASTPLS_BENCH_LIB="${LIBRARY}" Rscript -e '
    .libPaths(unique(c(Sys.getenv("FASTPLS_BENCH_LIB"), .libPaths())))
    library(fastPLS)
    stopifnot(as.character(packageVersion("fastPLS")) == "0.99.39")
    stopifnot(isTRUE(has_cuda()))
    cat("version=", as.character(packageVersion("fastPLS")),
        " cuda=", has_cuda(), " metal=", has_metal(), "\n", sep = "")
' >"${RESULTS_ROOT}/availability.log" 2>&1

echo "[SMOKE] $(date --iso-8601=seconds)"
FASTPLS_BENCH_LIB="${LIBRARY}" Rscript "${SMOKE_SCRIPT}" cuda \
    "${RESULTS_ROOT}/cuda_backend_family_smoke.csv" \
    >"${RESULTS_ROOT}/cuda_backend_family_smoke.log" 2>&1

date --iso-8601=seconds >"${RESULTS_ROOT}/candidate_ready.done"
echo "[DONE] $(date --iso-8601=seconds)"
