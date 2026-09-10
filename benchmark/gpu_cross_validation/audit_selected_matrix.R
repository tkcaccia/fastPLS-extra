#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 1L) {
    stop("Usage: audit_selected_matrix.R <summary-dir>")
}

summary_dir <- normalizePath(args[[1L]], mustWork = TRUE)
raw <- read.csv(file.path(summary_dir, "gpu_cv_raw_combined.csv"),
    stringsAsFactors = FALSE)
runtime <- read.csv(file.path(summary_dir, "gpu_cv_runtime_summary.csv"),
    stringsAsFactors = FALSE)
accelerator <- read.csv(file.path(
    summary_dir, "gpu_cv_cpu_accelerator_comparison.csv"
), stringsAsFactors = FALSE)

expected_rows <- 2L * 11L * 4L * 2L * 2L * 5L
if (nrow(raw) != expected_rows) {
    stop("Expected ", expected_rows, " raw rows; found ", nrow(raw), ".")
}
if (any(raw$status == "error") || any(!is.finite(raw$elapsed_sec))) {
    stop("At least one benchmark worker failed.")
}
if (any(runtime$completed != 5L) || any(runtime$attempted != 5L)) {
    stop("Every summarized cell must contain five completed repetitions.")
}

fold_group <- interaction(raw$platform, raw$dataset, raw$method, drop = TRUE)
fold_counts <- vapply(split(raw$fold_signature, fold_group),
    function(value) length(unique(value)), integer(1L))
if (any(fold_counts != 1L)) stop("Fold signatures differ within a paired cell.")

prediction_group <- interaction(
    raw$platform, raw$dataset, raw$method, raw$backend, raw$workload,
    drop = TRUE
)
prediction_counts <- vapply(split(raw$prediction_signature, prediction_group),
    function(value) length(unique(value)), integer(1L))
if (any(prediction_counts != 1L)) {
    stop("Prediction fingerprints vary across repeated cells.")
}

accelerator$absolute_metric_difference <- abs(accelerator$metric_difference)
accuracy <- accelerator$selection_metric == "accuracy"
rmsd <- accelerator$selection_metric == "rmsd"
accelerator$relative_metric_difference <- NA_real_
accelerator$relative_metric_difference[rmsd] <-
    accelerator$absolute_metric_difference[rmsd] /
        pmax(abs(accelerator$cpu_metric[rmsd]), .Machine$double.eps)

audit <- data.frame(
    check = c(
        "raw_rows", "failed_rows", "cells_with_five_repetitions",
        "paired_fold_signatures", "stable_prediction_fingerprints",
        "maximum_accuracy_difference", "maximum_relative_rmsd_difference"
    ),
    value = c(
        nrow(raw), sum(raw$status == "error"), nrow(runtime),
        length(fold_counts), length(prediction_counts),
        max(accelerator$absolute_metric_difference[accuracy], na.rm = TRUE),
        max(accelerator$relative_metric_difference[rmsd], na.rm = TRUE)
    ),
    stringsAsFactors = FALSE
)
write.csv(audit, file.path(summary_dir, "gpu_cv_audit.csv"), row.names = FALSE)
print(audit, row.names = FALSE)
