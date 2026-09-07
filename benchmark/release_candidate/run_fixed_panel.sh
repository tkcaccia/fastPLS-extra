#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 4 ]]; then
    echo "usage: $0 LIBRARY TASK_DIR SELECTED_CSV OUTPUT_DIR [BACKENDS] [PRECISIONS] [REPETITIONS] [FAMILIES] [SOURCE_ID]" >&2
    exit 2
fi

library_path=$1
task_dir=$2
selected_csv=$3
output_dir=$4
backends=${5:-cpu,cuda}
precisions=${6:-float32,float64}
repetitions=${7:-3}
families=${8:-plssvd,simpls,opls,kernelpls}
source_id=${9:-unrecorded}
script_dir=$(cd "$(dirname "$0")" && pwd)

mkdir -p "$output_dir"
datasets=(
    cbmc_citeseq
    ccle
    cifar100
    gtex_v8
    metref
    prism
    retina
    tabula
    tcga_brca
    tcga_hnsc_methylation
    tcga_pan_cancer
)

for dataset in "${datasets[@]}"; do
    task="$task_dir/${dataset}_task.rds"
    if [[ ! -f "$task" ]]; then
        echo "missing fixed task: $task" >&2
        exit 1
    fi
    Rscript "$script_dir/run_backend_matrix.R" \
        "--library=$library_path" \
        "--source-id=$source_id" \
        "--dataset=$task" \
        "--name=$dataset" \
        "--selected=$selected_csv" \
        "--output=$output_dir/${dataset}.csv" \
        "--backends=$backends" \
        "--precisions=$precisions" \
        "--repetitions=$repetitions" \
        "--families=$families" \
        "--quiet=true" \
        "--classifiers=argmax,lda"
done

Rscript -e '
    args <- commandArgs(TRUE)
    files <- list.files(args[[1L]], pattern = "[.]csv$", full.names = TRUE)
    tables <- lapply(files, utils::read.csv, stringsAsFactors = FALSE)
    utils::write.csv(do.call(rbind, tables), args[[2L]], row.names = FALSE)
' "$output_dir" "$output_dir/all_results.csv"
