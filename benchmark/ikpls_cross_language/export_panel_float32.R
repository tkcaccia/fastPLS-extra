#!/usr/bin/env Rscript

# Export the standard benchmark tasks for a precision- and component-matched
# IKPLS comparison. Conversion is performed before timed Python workers start.

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 3L) {
    stop(
        "Usage: export_panel_float32.R <task_root> <selected_components.csv> <output_dir>",
        call. = FALSE
    )
}

task_root <- normalizePath(args[[1L]], mustWork = TRUE)
selection_path <- normalizePath(args[[2L]], mustWork = TRUE)
output_root <- args[[3L]]
dir.create(output_root, recursive = TRUE, showWarnings = FALSE)

`%||%` <- function(x, fallback) if (is.null(x)) fallback else x

selection <- read.csv(selection_path, stringsAsFactors = FALSE)
required_selection <- c("dataset", "family", "selected_ncomp")
if (!all(required_selection %in% names(selection))) {
    stop("The component-selection table has an incompatible schema.", call. = FALSE)
}
selection <- selection[selection$family == "simpls", , drop = FALSE]
if (anyDuplicated(selection$dataset)) {
    stop("The SIMPLS component-selection table contains duplicate datasets.", call. = FALSE)
}

task_files <- list.files(task_root, pattern = "_task[.]rds$", full.names = TRUE)
dataset_ids <- sub("_task[.]rds$", "", basename(task_files))
task_files <- setNames(task_files, dataset_ids)
missing <- setdiff(selection$dataset, names(task_files))
if (length(missing)) {
    stop("Missing task files: ", paste(missing, collapse = ", "), call. = FALSE)
}

as_double_matrix <- function(value) {
    if (inherits(value, "float32")) {
        if (!requireNamespace("float", quietly = TRUE)) {
            stop("The float package is required to export float32 task objects.")
        }
        return(float::dbl(value))
    }
    as.matrix(value)
}

write_float32 <- function(value, path) {
    value <- as_double_matrix(value)
    connection <- file(path, open = "wb")
    on.exit(close(connection), add = TRUE)
    # NumPy reads C-order rows, whereas R stores matrices by column.
    writeBin(as.numeric(t(value)), connection, size = 4L, endian = "little")
}

write_int32 <- function(value, path) {
    connection <- file(path, open = "wb")
    on.exit(close(connection), add = TRUE)
    writeBin(as.integer(value), connection, size = 4L, endian = "little")
}

manifest <- vector("list", nrow(selection))
for (index in seq_len(nrow(selection))) {
    dataset <- selection$dataset[[index]]
    task <- readRDS(task_files[[dataset]])
    task_type <- match.arg(task$task_type, c("classification", "regression"))
    Xtrain <- as_double_matrix(task$Xtrain)
    Xtest <- as_double_matrix(task$Xtest)
    if (ncol(Xtrain) != ncol(Xtest)) {
        stop("Predictor dimensions differ for ", dataset, call. = FALSE)
    }

    if (task_type == "classification") {
        Ytrain_factor <- droplevels(as.factor(task$Ytrain))
        Ytest_factor <- factor(task$Ytest, levels = levels(Ytrain_factor))
        if (anyNA(Ytest_factor)) {
            stop("Held-out labels contain unseen classes for ", dataset, call. = FALSE)
        }
        Ytrain <- stats::model.matrix(~ Ytrain_factor - 1L)
        Ytest <- matrix(as.integer(Ytest_factor) - 1L, ncol = 1L)
        class_count <- nlevels(Ytrain_factor)
    } else {
        Ytrain <- as_double_matrix(task$Ytrain)
        Ytest <- as_double_matrix(task$Ytest)
        class_count <- NA_integer_
    }
    if (nrow(Xtrain) != nrow(Ytrain) || nrow(Xtest) != nrow(Ytest) ||
        ncol(Ytrain) < 1L) {
        stop("Response dimensions differ for ", dataset, call. = FALSE)
    }

    ncomp <- as.integer(selection$selected_ncomp[[index]])
    component_bound <- min(nrow(Xtrain) - 1L, ncol(Xtrain))
    if (!is.finite(ncomp) || ncomp < 1L || ncomp > component_bound) {
        stop("Invalid selected component count for ", dataset, call. = FALSE)
    }

    target <- file.path(output_root, dataset)
    dir.create(target, recursive = TRUE, showWarnings = FALSE)
    write_float32(Xtrain, file.path(target, "Xtrain.f32"))
    write_float32(Xtest, file.path(target, "Xtest.f32"))
    write_float32(Ytrain, file.path(target, "Ytrain.f32"))
    if (task_type == "classification") {
        write_int32(Ytest, file.path(target, "Ytest.i32"))
    } else {
        write_float32(Ytest, file.path(target, "Ytest.f32"))
    }

    metadata <- data.frame(
        key = c(
            "dataset", "task_type", "n_train", "n_test", "p", "q",
            "ncomp", "precision", "split_seed", "class_count",
            "preprocessing_timing"
        ),
        value = c(
            dataset, task_type, nrow(Xtrain), nrow(Xtest), ncol(Xtrain),
            ncol(Ytrain), ncomp, "float32", task$split_seed %||% NA_integer_,
            class_count, "centering included in timed IKPLS fit and prediction"
        )
    )
    write.table(
        metadata, file.path(target, "metadata.tsv"), sep = "\t",
        row.names = FALSE, quote = FALSE
    )
    manifest[[index]] <- data.frame(
        dataset = dataset, task_type = task_type, n_train = nrow(Xtrain),
        n_test = nrow(Xtest), p = ncol(Xtrain), q = ncol(Ytrain),
        ncomp = ncomp, precision = "float32", stringsAsFactors = FALSE
    )
    rm(task, Xtrain, Xtest, Ytrain, Ytest)
    gc(FALSE)
}

write.csv(
    do.call(rbind, manifest), file.path(output_root, "manifest.csv"),
    row.names = FALSE
)
message("Exported ", length(manifest), " matched IKPLS tasks to ", output_root)
