#!/usr/bin/env bash
set -euo pipefail

WAIT_PID="${WAIT_PID:-2371197}"
REPO_ROOT="${REPO_ROOT:-$HOME/fastPLS_bench_0.99.39}"
FASTPLS_LIB="${FASTPLS_LIB:-$HOME/Rlib_fastPLS_0.99.39}"
TASK_RDS="${TASK_RDS:-$HOME/Documents/fastpls/data/imagenet_float32_seed123_train1000000_task.rds}"
OUTPUT_DIR="${OUTPUT_DIR:-$HOME/fastPLS_results_0.99.39/publication_exact/imagenet}"
LOG_DIR="${LOG_DIR:-$HOME/fastPLS_results_0.99.39/publication_exact/queue_logs}"

mkdir -p "${LOG_DIR}" "${OUTPUT_DIR}"
while kill -0 "${WAIT_PID}" 2>/dev/null; do
  printf '[WAIT] %s pid=%s\n' "$(date --iso-8601=seconds)" "${WAIT_PID}"
  sleep 60
done

printf '[START] %s ImageNet current-release CUDA benchmark\n' \
  "$(date --iso-8601=seconds)"
FASTPLS_LIB="${FASTPLS_LIB}" \
TASK_RDS="${TASK_RDS}" \
OUTPUT_DIR="${OUTPUT_DIR}" \
REPO_ROOT="${REPO_ROOT}" \
  bash "${REPO_ROOT}/scripts/run_imagenet_current_fused_lda_remote.sh"
printf '[DONE] %s ImageNet current-release CUDA benchmark\n' \
  "$(date --iso-8601=seconds)"
