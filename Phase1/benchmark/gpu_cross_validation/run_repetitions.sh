#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 4 ]]; then
    echo "Usage: run_repetitions.sh LIBRARY TASK OUTPUT REPS [worker options...]" >&2
    exit 2
fi

library=$1
task=$2
output=$3
repetitions=$4
shift 4

script_dir=$(cd "$(dirname "$0")" && pwd)
worker="$script_dir/worker.R"

for ((replicate = 1; replicate <= repetitions; ++replicate)); do
    Rscript "$worker" \
        "--library=$library" \
        "--task=$task" \
        "--output=$output" \
        "--replicate=$replicate" "$@"
done
