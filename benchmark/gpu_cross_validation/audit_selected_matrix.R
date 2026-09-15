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

rows_per_dataset <- 4L * 2L * 2L * 5L
expected_rows <- 13L * rows_per_dataset + 12L * rows_per_dataset
if (nrow(raw) != expected_rows) {
    stop("Expected ", expected_rows, " raw rows; found ", nrow(raw), ".")
}
platform_counts <- table(raw$platform)
expected_platform_counts <- c(
    linux_nvidia = 13L * rows_per_dataset,
    mac_apple_silicon = 12L * rows_per_dataset
)
if (!identical(
        as.integer(platform_counts[names(expected_platform_counts)]),
        as.integer(expected_platform_counts)
    )) {
    stop("Platform row counts do not match the expected benchmark matrix.")
}
mac_datasets <- unique(raw$dataset[raw$platform == "mac_apple_silicon"])
if ("imagenet" %in% mac_datasets) {
    stop("The 8-GiB Mac profile must not claim the ImageNet CV workload.")
}
if (any(raw$status == "error") || any(!is.finite(raw$elapsed_sec))) {
    stop("At least one benchmark worker failed.")
}
if (any(runtime$completed != 5L) || any(runtime$attempted != 5L)) {
    stop("Every summarized cell must contain five completed repetitions.")
}

cv_raw <- raw[raw$workload == "cv", ]
fold_group <- interaction(cv_raw$platform, cv_raw$dataset, cv_raw$method,
    drop = TRUE)
fold_counts <- vapply(split(cv_raw$fold_signature, fold_group),
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
accuracy <- tolower(accelerator$selection_metric) == "accuracy"
rmsd <- tolower(accelerator$selection_metric) == "rmsd"
accelerator$relative_metric_difference <- NA_real_
accelerator$relative_metric_difference[rmsd] <-
    accelerator$absolute_metric_difference[rmsd] /
        pmax(abs(accelerator$cpu_metric[rmsd]), .Machine$double.eps)

audit <- data.frame(
    check = c(
        "raw_rows", "expected_mac_imagenet_omissions", "failed_rows",
        "cells_with_five_repetitions",
        "paired_fold_signatures", "stable_prediction_fingerprints",
        "maximum_accuracy_difference", "maximum_relative_rmsd_difference"
    ),
    value = c(
        nrow(raw), rows_per_dataset, sum(raw$status == "error"), nrow(runtime),
        length(fold_counts), length(prediction_counts),
        max(accelerator$absolute_metric_difference[accuracy], na.rm = TRUE),
        max(accelerator$relative_metric_difference[rmsd], na.rm = TRUE)
    ),
    stringsAsFactors = FALSE
)
write.csv(audit, file.path(summary_dir, "gpu_cv_audit.csv"), row.names = FALSE)
print(audit, row.names = FALSE)
