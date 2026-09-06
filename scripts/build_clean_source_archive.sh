#!/usr/bin/env bash

set -euo pipefail

ROOT="${ROOT:-$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)}"
STAGE_ROOT="$(mktemp -d "${TMPDIR:-/private/tmp}/fastPLS-release.XXXXXX")"
trap 'rm -rf "${STAGE_ROOT}"' EXIT

mkdir -p "${STAGE_ROOT}/fastPLS"
rsync -a \
    --exclude='.git' \
    --exclude='.fastpls-*' \
    --exclude='artifacts' \
    --exclude='benchmark' \
    --exclude='benchmark_results' \
    --exclude='benchmark_results_*' \
    --exclude='build' \
    --exclude='output' \
    --exclude='publication_release_*' \
    --exclude='publication_results' \
    --exclude='scripts' \
    --exclude='*.Rcheck' \
    --exclude='fastPLS_*.tar.gz' \
    --exclude='src/*.o' \
    --exclude='src/*.so' \
    --exclude='src/Makevars' \
    --exclude='src/Makevars.win' \
    --exclude='src/svd_metal_backend.mm' \
    "${ROOT}/" "${STAGE_ROOT}/fastPLS/"

(
    cd "${STAGE_ROOT}"
    R CMD build fastPLS
)

archive="$(find "${STAGE_ROOT}" -maxdepth 1 -name 'fastPLS_*.tar.gz' -print -quit)"
test -n "${archive}"
cp "${archive}" "${ROOT}/"
echo "Built ${ROOT}/$(basename "${archive}")"
