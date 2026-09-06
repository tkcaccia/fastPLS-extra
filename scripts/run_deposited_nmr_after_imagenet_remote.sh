#!/usr/bin/env bash
set -euo pipefail

WAIT_PID="${WAIT_PID:-2379184}"
REPO_ROOT="${REPO_ROOT:-$HOME/fastPLS_bench_0.99.39}"
FASTPLS_LIB="${FASTPLS_LIB:-$HOME/Rlib_fastPLS_0.99.39}"
NMR_INPUT="${NMR_INPUT:-$HOME/Documents/fastpls/data/nmr.RData}"
REFERENCE_SOURCE="${REFERENCE_SOURCE:-$REPO_ROOT/benchmark/reference/FastPLS_NatureCommunications.R}"
OUTPUT_DIR="${OUTPUT_DIR:-$HOME/fastPLS_results_0.99.39/publication_exact/nmr/deposited_reference}"
LOG_DIR="${LOG_DIR:-$HOME/fastPLS_results_0.99.39/publication_exact/queue_logs}"

mkdir -p "${LOG_DIR}" "${OUTPUT_DIR}"
while kill -0 "${WAIT_PID}" 2>/dev/null; do
  printf '[WAIT] %s pid=%s\n' "$(date --iso-8601=seconds)" "${WAIT_PID}"
  sleep 60
done

printf '[START] %s deposited NMR PLS-SVD comparison\n' \
  "$(date --iso-8601=seconds)"
bash "${REPO_ROOT}/scripts/run_nmr_deposited_reference.sh" \
  "${NMR_INPUT}" "${REFERENCE_SOURCE}" "${OUTPUT_DIR}" "${FASTPLS_LIB}"
printf '[DONE] %s deposited NMR PLS-SVD comparison\n' \
  "$(date --iso-8601=seconds)"
