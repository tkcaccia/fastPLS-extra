#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 5L) {
    stop(
        "Usage: profile_simpls_phases.R LIB DATASET NCOMP OVERSAMPLE POWER",
        call. = FALSE
    )
}

.libPaths(c(args[[1L]], .libPaths()))
suppressPackageStartupMessages(library(fastPLS))

profile_cores <- Sys.getenv("PROFILE_CORES", unset = "")
if (nzchar(profile_cores)) {
    options(cores = as.integer(profile_cores))
}

script <- sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[[1L]])
source(file.path(dirname(dirname(normalizePath(script))),
                 "helpers_dataset_memory_compare.R"))

task <- as_task(find_dataset_rdata(args[[2L]]), args[[2L]], split_seed = 123L)
task <- coerce_task_precision(task, "float32")
gc(full = TRUE)

elapsed <- system.time({
    fit <- pls(
        task$Xtrain,
        task$Ytrain,
        ncomp = as.integer(args[[3L]]),
        scaling = "centering",
        method = "simpls",
        svd.method = "rsvd",
        backend = "cpu",
        classifier = "argmax",
        fit = FALSE,
        proj = FALSE,
        return_variance = FALSE,
        oversample = as.integer(args[[4L]]),
        power = as.integer(args[[5L]]),
        seed = 123L
    )
})[["elapsed"]]
prediction_elapsed <- system.time({
    prediction <- predict(fit, task$Xtest, backend = "cpu")
})[["elapsed"]]
key <- paste0("ncomp=", as.integer(args[[3L]]))
accuracy <- mean(
    as.character(prediction$Ypred[[key]]) == as.character(task$Ytest)
)
prediction_hash <- if (requireNamespace("digest", quietly = TRUE)) {
    digest::digest(as.character(prediction$Ypred[[key]]), algo = "sha256")
} else {
    NA_character_
}
prediction_file <- Sys.getenv("PROFILE_PREDICTION_FILE", unset = "")
if (nzchar(prediction_file)) {
    saveRDS(as.character(prediction$Ypred[[key]]), prediction_file)
}

internal <- attr(fit, "fastPLS_internal", exact = TRUE)
cat("elapsed=", format(elapsed, digits = 12L), "\n", sep = "")
cat("prediction_elapsed=", format(prediction_elapsed, digits = 12L), "\n", sep = "")
cat("accuracy=", format(accuracy, digits = 12L), "\n", sep = "")
cat("prediction_hash=", prediction_hash, "\n", sep = "")
print(internal$benchmark_phase_timing)
print(fit$diagnostics$simpls_direction)
