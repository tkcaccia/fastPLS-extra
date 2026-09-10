#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 12L) {
    stop(paste(
        "Usage: precision_worker.R LIB DATASET METHOD BACKEND PRECISION",
        "CLASSIFIER KERNEL NCOMP REPLICATE OUTPUT READY GO"
    ), call. = FALSE)
}

lib <- args[[1L]]
dataset <- args[[2L]]
method <- args[[3L]]
backend <- args[[4L]]
precision <- args[[5L]]
classifier <- args[[6L]]
kernel <- args[[7L]]
ncomp <- as.integer(args[[8L]])
replicate_id <- as.integer(args[[9L]])
output <- args[[10L]]
ready <- args[[11L]]
go <- args[[12L]]

.libPaths(c(lib, .libPaths()))
suppressPackageStartupMessages(library(fastPLS))
if (!identical(as.character(packageVersion("fastPLS")), "0.99.42")) {
    stop("precision benchmark requires fastPLS 0.99.42", call. = FALSE)
}

`%||%` <- function(x, y) {
    if (is.null(x) || length(x) == 0L) y else x
}

script <- sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[[1L]])
source(file.path(dirname(dirname(normalizePath(script))),
                 "helpers_dataset_memory_compare.R"))

task <- as_task(find_dataset_rdata(dataset), dataset, split_seed = 123L)
task <- coerce_task_precision(task, precision)
classification <- identical(task$task_type, "classification")
gc(full = TRUE)

rss_mib <- function() {
    value <- ps::ps_memory_info(ps::ps_handle())[["rss"]]
    as.numeric(value) / 1024^2
}
writeLines(format(rss_mib(), digits = 15L), ready)
while (!file.exists(go)) Sys.sleep(0.01)

fit_time <- system.time({
    fit <- pls(
        task$Xtrain,
        task$Ytrain,
        ncomp = ncomp,
        method = method,
        backend = backend,
        classifier = classifier,
        kernel = kernel,
        north = 1L,
        fit = FALSE,
        proj = FALSE,
        return_variance = FALSE,
        seed = 123L
    )
})[["elapsed"]]
prediction_time <- system.time({
    prediction <- predict(fit, task$Xtest, backend = backend)
})[["elapsed"]]

value <- prediction$Ypred
prediction_names <- names(value)
key <- if (length(prediction_names)) {
    tail(prediction_names, 1L)
} else {
    paste0("ncomp=", ncomp)
}
effective_ncomp <- suppressWarnings(as.integer(sub("^ncomp=", "", key)))
if (!is.finite(effective_ncomp)) effective_ncomp <- ncomp
if (classification) {
    predicted <- value[[key]]
    metric_name <- "accuracy"
    metric_value <- mean(as.character(predicted) == as.character(task$Ytest))
} else {
    predicted <- if (is.list(value) && !is.data.frame(value)) {
        value[[key]]
    } else if (length(dim(value)) == 3L) {
        value[, , dim(value)[[3L]], drop = TRUE]
    } else {
        value
    }
    if (inherits(predicted, "float32")) predicted <- float::dbl(predicted)
    observed <- task$Ytest
    if (inherits(observed, "float32")) observed <- float::dbl(observed)
    metric_name <- "RMSD"
    metric_value <- sqrt(mean((as.matrix(predicted) - as.matrix(observed))^2))
}

internal <- attr(fit, "fastPLS_internal", exact = TRUE)
route <- fit$diagnostics$residency$route
if (is.null(route) && !is.null(internal$resident_backend)) {
    route <- paste("resident", internal$resident_backend)
}
row <- data.frame(
    package_version = as.character(packageVersion("fastPLS")),
    dataset = dataset,
    method = method,
    backend = backend,
    precision = precision,
    classifier = if (classification) classifier else NA_character_,
    kernel = kernel,
    ncomp_requested = ncomp,
    ncomp_effective = effective_ncomp,
    replicate = replicate_id,
    n_train = nrow(task$Xtrain),
    n_test = nrow(task$Xtest),
    p = ncol(task$Xtrain),
    q = if (classification) nlevels(task$Ytrain) else ncol(task$Ytrain),
    fit_sec = fit_time,
    prediction_sec = prediction_time,
    total_sec = fit_time + prediction_time,
    metric_name = metric_name,
    metric_value = metric_value,
    prefit_rss_mib = as.numeric(readLines(ready, warn = FALSE)[[1L]]),
    final_rss_mib = rss_mib(),
    resident_route = route %||% NA_character_,
    status = "success",
    stringsAsFactors = FALSE
)
dir.create(dirname(output), recursive = TRUE, showWarnings = FALSE)
write.csv(row, output, row.names = FALSE)
