#!/usr/bin/env bash
set -euo pipefail

active_pid="${ACTIVE_PID:-2354682}"
archive="${ARCHIVE:-$HOME/fastPLS_0.99.39.tar.gz}"
library="${FASTPLS_LIB:-$HOME/Rlib_fastPLS_0.99.39}"
waiters="${WAITERS:-2371197 2379184 2383730 2387605}"

echo "[WAIT] active NMR launcher ${active_pid}"
while kill -0 "${active_pid}" 2>/dev/null; do
    sleep 30
done

echo "[INSTALL] ${archive}"
FASTPLS_USE_CUDA=1 R CMD INSTALL --preclean --library="${library}" "${archive}"

FASTPLS_LIB="${library}" Rscript - <<'RSCRIPT'
library_path <- Sys.getenv("FASTPLS_LIB")
.libPaths(unique(c(library_path, .libPaths())))
library(fastPLS)
stopifnot(packageVersion("fastPLS") == "0.99.39")
stopifnot(isTRUE(has_cuda()))
stopifnot(!isTRUE(has_metal()))
error <- tryCatch(fastPLS_backend("metal"), error = identity)
stopifnot(inherits(error, "error"))
stopifnot(grepl("No CPU fallback is performed", conditionMessage(error)))
cat("[PASS] strict backend guard and CUDA runtime verified\n")
RSCRIPT

for waiter in ${waiters}; do
    if kill -0 "${waiter}" 2>/dev/null; then
        kill -CONT "${waiter}"
        echo "[RESUME] ${waiter}"
    fi
done

echo "[DONE] strict package installed and queued launchers resumed"
