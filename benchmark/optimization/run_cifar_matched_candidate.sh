#!/usr/bin/env bash
set -euo pipefail

SOURCE=${1:?source directory required}
LIBRARY=${2:?library directory required}
TASK=${3:?CIFAR-100 task RDS required}
OUTPUT=${4:?output directory required}
WAIT_PID=${5:-}
BASELINE=${6:-}
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WORKER="$SCRIPT_DIR/../ikpls_cross_language/worker_fastpls_public.R"

if [[ -n "$WAIT_PID" ]]; then
    while kill -0 "$WAIT_PID" 2>/dev/null; do sleep 30; done
fi

mkdir -p "$LIBRARY" "$OUTPUT"
FASTPLS_USE_CUDA=1 R CMD INSTALL --preclean -l "$LIBRARY" "$SOURCE" \
    >"$OUTPUT/install.log" 2>&1

export FASTPLS_BENCH_NCOMP=50
export FASTPLS_BENCH_OVERSAMPLE=32
export FASTPLS_BENCH_POWER=5
export FASTPLS_BENCH_SEED=123
for backend in cpu cuda; do
    for replicate in $(seq 1 11); do
        while nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null |
                grep -q '[0-9]'; do sleep 10; done
        Rscript "$WORKER" \
            "$TASK" "$LIBRARY" "$backend" "$replicate" \
            "$OUTPUT/${backend}_r${replicate}.csv"
    done
done

Rscript - "$OUTPUT" <<'RSCRIPT'
args <- commandArgs(trailingOnly = TRUE)
files <- list.files(args[[1L]], pattern = "^(cpu|cuda)_r[0-9]+[.]csv$",
                    full.names = TRUE)
x <- do.call(rbind, lapply(files, read.csv))
summary <- aggregate(cbind(fit_sec, prediction_sec, total_sec, accuracy) ~ backend,
                     x, median)
write.csv(x, file.path(args[[1L]], "raw.csv"), row.names = FALSE)
write.csv(summary, file.path(args[[1L]], "summary.csv"), row.names = FALSE)
print(summary, row.names = FALSE)
RSCRIPT

if [[ -n "$BASELINE" ]]; then
    python3 "$SCRIPT_DIR/check_cifar_performance_gate.py" \
        --candidate "$OUTPUT" \
        --baseline "$BASELINE"
fi
