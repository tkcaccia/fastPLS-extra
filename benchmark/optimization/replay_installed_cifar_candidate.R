#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 5L) {
    stop(
        "Usage: replay_installed_cifar_candidate.R ",
        "TASK_RDS LIBRARY BACKEND REPLICATE OUTPUT_CSV"
    )
}

task_path <- args[[1L]]
library_path <- args[[2L]]
backend <- match.arg(args[[3L]], c("cpu", "cuda", "metal"))
replicate_id <- as.integer(args[[4L]])
output_csv <- args[[5L]]
.libPaths(unique(c(library_path, .libPaths())))

ncomp <- as.integer(Sys.getenv("FASTPLS_BENCH_NCOMP", "50"))
oversample <- as.integer(Sys.getenv("FASTPLS_BENCH_OVERSAMPLE", "32"))
power <- as.integer(Sys.getenv("FASTPLS_BENCH_POWER", "5"))
seed <- as.integer(Sys.getenv("FASTPLS_BENCH_SEED", "123"))
precision <- match.arg(
    Sys.getenv("FASTPLS_BENCH_PRECISION", "float32"),
    c("float32", "float64")
)

task <- readRDS(task_path)
suppressPackageStartupMessages(library(fastPLS))
if (identical(precision, "float32")) {
    task$Xtrain <- float::fl(as.matrix(task$Xtrain))
    task$Xtest <- float::fl(as.matrix(task$Xtest))
} else {
    task$Xtrain <- as.matrix(task$Xtrain)
    task$Xtest <- as.matrix(task$Xtest)
    storage.mode(task$Xtrain) <- "double"
    storage.mode(task$Xtest) <- "double"
}
gc(FALSE)

fit_elapsed <- system.time({
    fit <- pls(
        task$Xtrain,
        task$Ytrain,
        ncomp = ncomp,
        scaling = "none",
        method = "simpls",
        svd.method = "rsvd",
        backend = backend,
        classifier = "argmax",
        fit = FALSE,
        return_variance = FALSE,
        return_loadings = FALSE,
        proj = FALSE,
        seed = seed,
        oversample = oversample,
        power = power
    )
})[["elapsed"]]
prediction_elapsed <- system.time({
    prediction <- predict(fit, task$Xtest, backend = backend)$Ypred
})[["elapsed"]]
if (is.list(prediction)) {
    prediction <- prediction[[length(prediction)]]
}
predicted <- factor(prediction, levels = levels(task$Ytest))

utils::write.csv(data.frame(
    package_version = as.character(utils::packageVersion("fastPLS")),
    package_library = find.package("fastPLS"),
    backend = backend,
    precision = precision,
    replicate = replicate_id,
    ncomp = ncomp,
    oversample = oversample,
    power = power,
    fit_sec = unname(fit_elapsed),
    prediction_sec = unname(prediction_elapsed),
    total_sec = unname(fit_elapsed + prediction_elapsed),
    accuracy = mean(predicted == task$Ytest),
    prediction_checksum = sum(as.integer(predicted) * seq_along(predicted))
), output_csv, row.names = FALSE)
