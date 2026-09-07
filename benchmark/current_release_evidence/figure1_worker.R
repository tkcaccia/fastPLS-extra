#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 10L) {
    stop(paste(
        "Usage: figure1_worker.R LIB DATASET CLASSIFIER NCOMP REPLICATE",
        "OUTPUT READY GO OVERSAMPLE POWER"
    ), call. = FALSE)
}

lib <- args[[1L]]
dataset <- args[[2L]]
classifier <- args[[3L]]
ncomp <- as.integer(args[[4L]])
replicate_id <- as.integer(args[[5L]])
output <- args[[6L]]
ready <- args[[7L]]
go <- args[[8L]]
oversample <- as.integer(args[[9L]])
power <- as.integer(args[[10L]])

.libPaths(c(lib, .libPaths()))
suppressPackageStartupMessages(library(fastPLS))
if (!identical(as.character(packageVersion("fastPLS")), "0.99.40")) {
    stop("Figure 1 benchmark requires fastPLS 0.99.40", call. = FALSE)
}

script <- sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[[1L]])
source(file.path(dirname(dirname(normalizePath(script))),
                 "helpers_dataset_memory_compare.R"))

task <- as_task(find_dataset_rdata(dataset), dataset, split_seed = 123L)
if (!identical(task$task_type, "classification")) {
    stop("Figure 1 worker requires a classification dataset", call. = FALSE)
}
task <- coerce_task_precision(task, "float32")
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
        scaling = "centering",
        method = "simpls",
        svd.method = "rsvd",
        backend = "cpu",
        classifier = classifier,
        fit = FALSE,
        proj = FALSE,
        return_variance = FALSE,
        oversample = oversample,
        power = power,
        seed = 123L
    )
})[["elapsed"]]
prediction_time <- system.time({
    prediction <- predict(fit, task$Xtest, backend = "cpu")
})[["elapsed"]]

key <- paste0("ncomp=", ncomp)
predicted <- prediction$Ypred[[key]]
row <- data.frame(
    package_version = as.character(packageVersion("fastPLS")),
    dataset = dataset,
    method = "simpls",
    backend = "cpu",
    precision = "float32",
    classifier = classifier,
    ncomp = ncomp,
    replicate = replicate_id,
    fit_sec = fit_time,
    prediction_sec = prediction_time,
    total_sec = fit_time + prediction_time,
    accuracy = mean(as.character(predicted) == as.character(task$Ytest)),
    prefit_rss_mib = as.numeric(readLines(ready, warn = FALSE)[[1L]]),
    final_rss_mib = rss_mib(),
    oversample = oversample,
    power = power,
    seed = 123L,
    status = "success",
    stringsAsFactors = FALSE
)
dir.create(dirname(output), recursive = TRUE, showWarnings = FALSE)
write.csv(row, output, row.names = FALSE)
