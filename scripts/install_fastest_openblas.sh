#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

OPENBLAS_ROOT="${OPENBLAS_ROOT:-/opt/homebrew/opt/openblas}"
OPENBLAS_THREADS="${OPENBLAS_NUM_THREADS:-1}"
R_LIB="${R_LIB:-${REPO_ROOT}/.fastpls-openblas-lib}"

if [[ ! -d "${OPENBLAS_ROOT}" ]]; then
  echo "OpenBLAS not found at ${OPENBLAS_ROOT}" >&2
  echo "Set OPENBLAS_ROOT to the correct prefix and rerun." >&2
  exit 1
fi

mkdir -p "${R_LIB}"

echo "Installing fastPLS with OpenBLAS"
echo "  repo: ${REPO_ROOT}"
echo "  openblas: ${OPENBLAS_ROOT}"
echo "  R lib: ${R_LIB}"
echo "  OPENBLAS_NUM_THREADS: ${OPENBLAS_THREADS}"

cd "${REPO_ROOT}"
FASTPLS_USE_OPENBLAS=1 \
OPENBLAS_ROOT="${OPENBLAS_ROOT}" \
R CMD INSTALL --preclean . -l "${R_LIB}"

cat <<EOF

Install complete.

To use this build in a shell:
  export OPENBLAS_NUM_THREADS=${OPENBLAS_THREADS}
  export R_LIBS_USER="${R_LIB}"

Quick verification:
  otool -L "${R_LIB}/fastPLS/libs/fastPLS.so" | grep openblas

Example benchmark run:
  OPENBLAS_NUM_THREADS=${OPENBLAS_THREADS} Rscript benchmark/benchmark_large_rsvd.R --use-openblas=1 --openblas-threads=${OPENBLAS_THREADS}
EOF
