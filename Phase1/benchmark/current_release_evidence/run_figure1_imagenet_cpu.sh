#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 4 ]; then
    echo "Usage: $0 PACKAGE_LIBRARY TASK_RDS OUTPUT_DIR WORKER_R" >&2
    exit 2
fi

package_library=$1
task_rds=$2
output_dir=$3
worker_r=$4

mkdir -p "$output_dir"

export FASTPLS_BENCH_LIBRARY="$package_library"
export OPENBLAS_NUM_THREADS=1
export OMP_NUM_THREADS=1
export MKL_NUM_THREADS=1
export VECLIB_MAXIMUM_THREADS=1

for method in simpls; do
    for classifier in lda; do
        stem="${method}_${classifier}"
        /usr/bin/time -v Rscript "$worker_r" \
            "$task_rds" "$method" "$classifier" \
            "$output_dir/${stem}.csv" \
            >"$output_dir/${stem}.stdout.log" \
            2>"$output_dir/${stem}.time.log"
    done
done
