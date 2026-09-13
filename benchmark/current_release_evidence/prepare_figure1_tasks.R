#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 2L) {
    stop("Usage: prepare_figure1_tasks.R CONTRACT_CSV OUTPUT_DIRECTORY",
         call. = FALSE)
}

contract_path <- normalizePath(args[[1L]], mustWork = TRUE)
output_directory <- args[[2L]]
script <- sub("^--file=", "", grep("^--file=", commandArgs(FALSE),
                                    value = TRUE)[[1L]])
source(file.path(dirname(dirname(normalizePath(script))),
                 "helpers_dataset_memory_compare.R"))

contract <- read.csv(contract_path, stringsAsFactors = FALSE)
required <- c("dataset", "task_type")
if (!all(required %in% names(contract))) {
    stop("The Figure 1 component contract has an incompatible schema.",
         call. = FALSE)
}
contract <- contract[contract$dataset != "imagenet", , drop = FALSE]
dir.create(output_directory, recursive = TRUE, showWarnings = FALSE)

for (index in seq_len(nrow(contract))) {
    dataset <- contract$dataset[[index]]
    task <- as_task(find_dataset_rdata(dataset), dataset, split_seed = 123L)
    task <- validate_publication_task(task, dataset)
    task <- coerce_task_precision(task, "float32")
    if (!identical(task$task_type, contract$task_type[[index]])) {
        stop("Task type differs from the Figure 1 contract for ", dataset,
             call. = FALSE)
    }
    saveRDS(task, file.path(output_directory, paste0(dataset, "_task.rds")))
    message("Prepared ", dataset)
}
