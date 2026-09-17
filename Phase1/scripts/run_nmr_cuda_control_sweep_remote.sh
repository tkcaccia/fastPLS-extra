#!/usr/bin/env bash

set -euo pipefail

SOURCE_ROOT="${SOURCE_ROOT:-$HOME/fastPLS_nmr_bench_frozen_0.99.39}"
FASTPLS_LIB="${FASTPLS_LIB:-$HOME/Rlib_fastPLS_0.99.39_frozen}"
INPUT="${INPUT:-$HOME/Documents/fastpls/data/nmr.RData}"
REFERENCE="${REFERENCE:-$HOME/fastPLS_results_0.99.39_frozen/nmr/fixed50_simpls_cpu_irlba_k50_prediction.rds}"
OUTPUT_DIR="${OUTPUT_DIR:-$HOME/fastPLS_results_0.99.39_frozen/candidate_control_sweep}"
NCOMP="${NCOMP:-50}"
CONTROLS="${CONTROLS:-10:1,12:2,16:2}"
SEEDS="${SEEDS:-11,29,47}"
OUTPUT_FILE="${OUTPUT_FILE:-nmr_cuda_control_sweep.csv}"

mkdir -p "${OUTPUT_DIR}"
FASTPLS_LIB="${FASTPLS_LIB}" Rscript \
    "${SOURCE_ROOT}/benchmark/benchmark_nmr_rsvd_control_sweep.R" \
    --input="${INPUT}" \
    --reference="${REFERENCE}" \
    --output="${OUTPUT_DIR}/${OUTPUT_FILE}" \
    --backend=cuda \
    --family=simpls \
    --ncomp="${NCOMP}" \
    --controls="${CONTROLS}" \
    --seeds="${SEEDS}" \
    >"${OUTPUT_DIR}/${OUTPUT_FILE%.csv}.log" 2>&1

cat "${OUTPUT_DIR}/${OUTPUT_FILE%.csv}.log"
