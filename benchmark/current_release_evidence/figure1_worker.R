#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 12L) {
    stop(paste(
        "Usage: figure1_worker.R LIB DATASET METHOD CLASSIFIER NCOMP REPLICATE",
        "OUTPUT READY GO OVERSAMPLE POWER EXPECTED_VERSION"
    ), call. = FALSE)
}

lib <- args[[1L]]
dataset <- args[[2L]]
method <- args[[3L]]
classifier <- args[[4L]]
ncomp <- as.integer(args[[5L]])
replicate_id <- as.integer(args[[6L]])
output <- args[[7L]]
ready <- args[[8L]]
go <- args[[9L]]
oversample <- as.integer(args[[10L]])
power <- as.integer(args[[11L]])
expected_version <- args[[12L]]

if (!method %in% c("simpls", "plssvd")) {
    stop("METHOD must be 'simpls' or 'plssvd'", call. = FALSE)
}

.libPaths(c(lib, .libPaths()))
suppressPackageStartupMessages(library(fastPLS))
loaded_version <- as.character(packageVersion("fastPLS"))
if (!identical(loaded_version, expected_version)) {
    stop(
        "Figure 1 benchmark expected fastPLS ", expected_version,
        " but loaded ", loaded_version,
        call. = FALSE
    )
}

script <- sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[[1L]])
source(file.path(dirname(dirname(normalizePath(script))),
                 "helpers_dataset_memory_compare.R"))

task <- as_task(find_dataset_rdata(dataset), dataset, split_seed = 123L)
if (!identical(task$task_type, "classification")) {
    stop("Figure 1 worker requires a classification dataset", call. = FALSE)
}
task <- coerce_task_precision(task, "float32")
invisible(gc(full = TRUE))

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
        method = method,
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
truth <- factor(task$Ytest)
predicted <- factor(predicted, levels = levels(truth))
recall <- vapply(
    levels(truth),
    function(level) {
        keep <- truth == level
        if (!any(keep)) return(NA_real_)
        mean(predicted[keep] == level)
    },
    numeric(1L)
)
direction <- if (identical(method, "simpls")) {
    fit$diagnostics$simpls_direction
} else {
    list()
}
blas <- tryCatch(
    as.character(sessionInfo()$BLAS),
    error = function(error) NA_character_
)
row <- data.frame(
    package_version = loaded_version,
    package_path = find.package("fastPLS"),
    platform = R.version$platform,
    blas = blas,
    dataset = dataset,
    method = method,
    backend = "cpu",
    precision = "float32",
    classifier = classifier,
    ncomp = ncomp,
    replicate = replicate_id,
    fit_sec = fit_time,
    prediction_sec = prediction_time,
    total_sec = fit_time + prediction_time,
    accuracy = mean(predicted == truth),
    balanced_accuracy = mean(recall, na.rm = TRUE),
    correct = sum(predicted == truth),
    test_total = length(truth),
    prefit_rss_mib = as.numeric(readLines(ready, warn = FALSE)[[1L]]),
    final_rss_mib = rss_mib(),
    oversample = oversample,
    power = power,
    seed = 123L,
    direction_rule = direction$rule %||% NA_character_,
    directions_per_solve = direction$directions_per_solve %||% NA_integer_,
    refresh_width = direction$refresh_width %||% NA_integer_,
    fresh_start = direction$fresh_start %||% NA,
    status = "success",
    stringsAsFactors = FALSE
)
dir.create(dirname(output), recursive = TRUE, showWarnings = FALSE)
write.csv(row, output, row.names = FALSE)
