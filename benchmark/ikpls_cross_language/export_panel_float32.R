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
        if (length(Ytrain_factor) != nrow(Xtrain) ||
            length(Ytest_factor) != nrow(Xtest) || anyNA(Ytrain_factor) ||
            anyNA(Ytest_factor) ||
            any(!nzchar(trimws(as.character(Ytrain_factor)))) ||
            any(!nzchar(trimws(as.character(Ytest_factor))))) {
            stop(
                "Every exported sample must have one valid label for ",
                dataset, "; no samples were removed.",
                call. = FALSE
            )
        }
        Ytrain <- stats::model.matrix(~ Ytrain_factor - 1L)
        Ytest <- matrix(as.integer(Ytest_factor) - 1L, ncol = 1L)
        class_count <- nlevels(Ytrain_factor)
        if (identical(dataset, "tabula")) {
            labels <- c(as.character(Ytrain_factor), as.character(Ytest_factor))
            expected_counts <- c(
                droplet_Bladder = 2500L, droplet_Heart_and_Aorta = 624L,
                droplet_Kidney = 2777L, droplet_Limb_Muscle = 4536L,
                droplet_Liver = 1845L, droplet_Lung = 5449L,
                droplet_Mammary_Gland = 4478L, droplet_Marrow = 3651L,
                droplet_Spleen = 9552L, droplet_Thymus = 1429L,
                droplet_Tongue = 7537L, droplet_Trachea = 11269L,
                facs_Aorta = 406L, facs_Bladder = 1355L,
                facs_Brain_Myeloid = 4455L,
                `facs_Brain_Non-Myeloid` = 3372L,
                facs_Diaphragm = 870L, facs_Fat = 4955L,
                facs_Heart = 4364L, facs_Kidney = 519L,
                facs_Large_Intestine = 3708L, facs_Limb_Muscle = 1090L,
                facs_Liver = 585L, facs_Lung = 1716L,
                facs_Mammary_Gland = 2402L, facs_Marrow = 5021L,
                facs_Pancreas = 1536L, facs_Skin = 2303L,
                facs_Spleen = 1697L, facs_Thymus = 1349L,
                facs_Tongue = 1402L, facs_Trachea = 1350L
            )
            observed_counts <- table(labels)
            tabula_valid <- nrow(Xtrain) + nrow(Xtest) == 100102L &&
                ncol(Xtrain) == 50L && class_count == 32L &&
                !anyNA(Ytrain_factor) && !anyNA(Ytest_factor) && identical(
                    as.integer(observed_counts[names(expected_counts)]),
                    unname(expected_counts)
                )
            if (!tabula_valid) {
                stop(
                    paste(
                        "Tabula Muris export requires the verified",
                        "100,102-cell, 32-class PCA50 task."
                    ),
                    call. = FALSE
                )
            }
        }
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
