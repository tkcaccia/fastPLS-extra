#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 6L) {
    stop(
        "Usage: save_nmr_prediction.R LIB TASK BACKEND FAMILY NCOMP OUTPUT",
        call. = FALSE
    )
}

library_path <- normalizePath(args[[1L]], mustWork = TRUE)
task_path <- normalizePath(args[[2L]], mustWork = TRUE)
backend <- match.arg(args[[3L]], c("cpu", "metal"))
family <- match.arg(args[[4L]], c("plssvd", "simpls", "opls", "kernelpls"))
ncomp <- as.integer(args[[5L]])
output <- args[[6L]]

.libPaths(unique(c(library_path, .libPaths())))
suppressPackageStartupMessages(library(fastPLS))
if (!identical(as.character(packageVersion("fastPLS")), "0.99.42")) {
    stop("This evidence script requires fastPLS 0.99.42.", call. = FALSE)
}
if (backend == "metal" && !isTRUE(has_metal())) {
    stop("Metal is unavailable; no CPU fallback is permitted.", call. = FALSE)
}

task <- readRDS(task_path)
to_float <- function(value) {
    if (inherits(value, "float32")) value else float::fl(as.matrix(value))
}
task$Xtrain <- to_float(task$Xtrain)
task$Xtest <- to_float(task$Xtest)
task$Ytrain <- to_float(task$Ytrain)
task$Ytest <- to_float(task$Ytest)

fit <- suppressWarnings(pls(
    task$Xtrain,
    task$Ytrain,
    ncomp = ncomp,
    method = family,
    backend = backend,
    classifier = "argmax",
    kernel = "linear",
    north = 1L,
    fit = FALSE,
    proj = FALSE,
    return_variance = FALSE,
    return_loadings = FALSE,
    seed = 123L
))
prediction <- predict(fit, task$Xtest, backend = backend)$Ypred
if (is.list(prediction)) prediction <- prediction[[length(prediction)]]
if (inherits(prediction, "float32")) prediction <- float::dbl(prediction)
observed <- float::dbl(task$Ytest)
prediction <- as.matrix(prediction)
observed <- as.matrix(observed)

result <- list(
    package_version = as.character(packageVersion("fastPLS")),
    backend = backend,
    family = family,
    precision = "float32",
    ncomp = ncomp,
    observed = observed,
    predicted = prediction,
    per_sample_rmsd = sqrt(rowMeans((observed - prediction)^2)),
    per_response_rmsd = sqrt(colMeans((observed - prediction)^2)),
    residency = fit$diagnostics$residency,
    metal_operation_split = fit$diagnostics$metal_operation_split,
    rsvd = fit$diagnostics$rsvd
)
dir.create(dirname(output), recursive = TRUE, showWarnings = FALSE)
saveRDS(result, output, version = 3L)

