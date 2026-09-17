#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
library_path <- if (length(args) >= 1L) args[[1L]] else
    "/private/tmp/fastpls-0.99.40-metal-lib"
task_path <- if (length(args) >= 2L) args[[2L]] else
    "/Users/stefano/Documents/GPUPLS/Data/metal_matched/cifar100_task.rds"
output_path <- if (length(args) >= 3L) args[[3L]] else
    "/Users/stefano/Documents/GPUPLS/local_results/metal_optimization_20260907/cifar_cold_warm.csv"

.libPaths(unique(c(library_path, .libPaths())))
suppressPackageStartupMessages(library(fastPLS))
if (!has_metal()) stop("Metal is unavailable", call. = FALSE)

task <- readRDS(task_path)
Xtrain <- float::fl(as.matrix(task$Xtrain))
Xtest <- float::fl(as.matrix(task$Xtest))
profile_power <- as.integer(Sys.getenv("PROFILE_POWER", "5"))
profile_seed <- as.integer(Sys.getenv("PROFILE_SEED", "123"))

run_once <- function(backend, replicate_id) {
    gc(full = TRUE)
    fit_elapsed <- system.time({
        fit <- pls(
            Xtrain, task$Ytrain,
            ncomp = 298L,
            method = "simpls",
            svd.method = "rsvd",
            backend = backend,
            classifier = "argmax",
            kernel = "linear",
            fit = FALSE,
            proj = FALSE,
            return_variance = FALSE,
            return_loadings = FALSE,
            power = profile_power,
            seed = profile_seed
        )
    })[["elapsed"]]
    prediction_elapsed <- system.time({
        predicted <- predict(fit, Xtest, backend = backend)$Ypred
    })[["elapsed"]]
    if (is.list(predicted)) predicted <- predicted[[length(predicted)]]
    data.frame(
        backend = backend,
        replicate = replicate_id,
        fit_sec = fit_elapsed,
        prediction_sec = prediction_elapsed,
        total_sec = fit_elapsed + prediction_elapsed,
        accuracy = mean(as.character(predicted) == as.character(task$Ytest)),
        route = fit$diagnostics$residency$route %||% "compiled CPU"
    )
}

`%||%` <- function(left, right) {
    if (is.null(left) || !length(left)) right else left
}

results <- do.call(rbind, c(
    lapply(1:5, function(index) run_once("metal", index)),
    lapply(1:5, function(index) run_once("cpu", index))
))
dir.create(dirname(output_path), recursive = TRUE, showWarnings = FALSE)
write.csv(results, output_path, row.names = FALSE)
print(results)
