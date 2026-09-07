#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 7 ]]; then
    echo "Usage: run_matched_pair.sh BASE_LIB CANDIDATE_LIB TASK BASE_CSV CANDIDATE_CSV REPS [worker options...]" >&2
    exit 2
fi

baseline_library=$1
candidate_library=$2
task=$3
baseline_output=$4
candidate_output=$5
repetitions=$6
shift 6

script_dir=$(cd "$(dirname "$0")" && pwd)
worker="$script_dir/worker.R"

for ((replicate = 1; replicate <= repetitions; ++replicate)); do
    Rscript "$worker" \
        "--library=$baseline_library" \
        "--task=$task" \
        "--output=$baseline_output" \
        --implementation=separate-paths \
        "--replicate=$replicate" "$@"
    Rscript "$worker" \
        "--library=$candidate_library" \
        "--task=$task" \
        "--output=$candidate_output" \
        --implementation=combined-path \
        "--replicate=$replicate" "$@"
done
