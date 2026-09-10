#!/usr/bin/env sh
set -eu

if [ "$#" -ne 1 ]; then
    echo "Usage: run_cuda_after_cpu.sh PROJECT_ROOT" >&2
    exit 2
fi

project_root=$(cd "$1" && pwd)
wait_pid=${FASTPLS_WAIT_PID:-}
if [ -n "$wait_pid" ]; then
    while kill -0 "$wait_pid" 2>/dev/null; do
        sleep 60
    done
fi

cd "$project_root"
library_path="$project_root/Rlib"
task_root="$project_root/tasks"
selection="$project_root/results/component_selection/selected_components.csv"
result_root="$project_root/results/r_panel_cuda"

R_LIBS_USER="$library_path" Rscript -e '
    .libPaths(unique(c(normalizePath("Rlib"), .libPaths())))
    source("benchmark/helpers_dataset_memory_compare.R")
    task <- validate_publication_task(readRDS("tasks/tabula_task.rds"), "tabula")
    labels <- c(as.character(task$Ytrain), as.character(task$Ytest))
    stopifnot(length(labels) == 100102L, !anyNA(labels),
              !any(!nzchar(trimws(labels))), sum(table(labels)) == 100102L)
    stopifnot(as.character(packageVersion("fastPLS")) == "0.99.56")
'

python3 benchmark/tabula_corrected/run_r_panel.py \
    --repo "$project_root" \
    --library "$library_path" \
    --tasks "$task_root" \
    --selected "$selection" \
    --results "$result_root" \
    --precision float32 \
    --repetitions 10 \
    --timeout 10000 \
    --method-regex='_cuda_'

date > "$project_root/results/tabula_cuda_complete.txt"
