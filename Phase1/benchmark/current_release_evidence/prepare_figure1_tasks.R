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
manifest <- vector("list", nrow(contract))

task_dimensions <- function(task, dataset) {
    response <- task$Ytrain
    if (length(task$n_classes) == 1L) {
        response_count <- as.integer(task$n_classes)
    } else if (identical(task$task_type, "classification")) {
        response_count <- length(unique(as.character(response)))
    } else if (inherits(response, "float32")) {
        response_count <- ncol(methods::slot(response, "Data"))
    } else {
        response_count <- ncol(response)
        if (is.null(response_count)) {
            response_count <- 1L
        }
    }
    data.frame(
        dataset = dataset,
        task_type = task$task_type,
        n_train = if (length(task$n_train) == 1L) task$n_train else nrow(task$Xtrain),
        n_test = if (length(task$n_test) == 1L) task$n_test else nrow(task$Xtest),
        p = if (length(task$p) == 1L) task$p else ncol(task$Xtrain),
        q = response_count,
        stringsAsFactors = FALSE
    )
}

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
    manifest[[index]] <- task_dimensions(task, dataset)
    message("Prepared ", dataset)
}

manifest <- Filter(Negate(is.null), manifest)
write.csv(
    do.call(rbind, manifest),
    file.path(output_directory, "prepared_task_manifest.csv"),
    row.names = FALSE
)
