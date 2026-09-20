#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 1L) {
    stop("Usage: write_prepared_task_manifest.R TASK_DIRECTORY",
         call. = FALSE)
}

task_directory <- normalizePath(args[[1L]], mustWork = TRUE)
task_files <- sort(list.files(
    task_directory,
    pattern = "_task[.]rds$",
    full.names = TRUE
))
if (!length(task_files)) {
    stop("No prepared task files were found.", call. = FALSE)
}

describe_task <- function(path) {
    task <- readRDS(path)
    dataset <- sub("_task[.]rds$", "", basename(path))
    if (all(c("Xtrain_rds", "Xtest_rds", "Ytrain", "n_train", "n_test",
              "p", "n_classes") %in% names(task))) {
        return(data.frame(
            dataset = dataset,
            task_type = "classification",
            n_train = as.integer(task$n_train),
            n_test = as.integer(task$n_test),
            p = as.integer(task$p),
            q = as.integer(task$n_classes),
            stringsAsFactors = FALSE
        ))
    }
    required <- c("Xtrain", "Xtest", "Ytrain", "task_type")
    if (!all(required %in% names(task))) {
        stop("Prepared task has an incompatible schema: ", path, call. = FALSE)
    }
    response_count <- if (length(task$n_classes) == 1L) {
        as.integer(task$n_classes)
    } else if (identical(task$task_type, "classification")) {
        length(unique(as.character(task$Ytrain)))
    } else if (inherits(task$Ytrain, "float32")) {
        ncol(methods::slot(task$Ytrain, "Data"))
    } else {
        value <- ncol(task$Ytrain)
        if (is.null(value)) 1L else value
    }
    if (length(response_count) != 1L) {
        stop("Could not determine one response count for: ", path,
             call. = FALSE)
    }
    n_train <- if (length(task$n_train) == 1L) {
        as.integer(task$n_train)
    } else {
        nrow(task$Xtrain)
    }
    n_test <- if (length(task$n_test) == 1L) {
        as.integer(task$n_test)
    } else {
        nrow(task$Xtest)
    }
    predictor_count <- if (length(task$p) == 1L) {
        as.integer(task$p)
    } else {
        ncol(task$Xtrain)
    }
    if (any(lengths(list(n_train, n_test, predictor_count)) != 1L)) {
        stop("Could not determine task dimensions for: ", path,
             call. = FALSE)
    }
    data.frame(
        dataset = dataset,
        task_type = task$task_type,
        n_train = n_train,
        n_test = n_test,
        p = predictor_count,
        q = response_count,
        stringsAsFactors = FALSE
    )
}

manifest <- do.call(rbind, lapply(task_files, describe_task))
write.csv(
    manifest,
    file.path(task_directory, "prepared_task_manifest.csv"),
    row.names = FALSE
)
