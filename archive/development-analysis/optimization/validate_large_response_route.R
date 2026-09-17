#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
value <- function(name, default = NULL) {
    prefix <- paste0("--", name, "=")
    hit <- args[startsWith(args, prefix)]
    if (!length(hit)) return(default)
    substring(hit[[length(hit)]], nchar(prefix) + 1L)
}

task_path <- value("task")
library_path <- value("library")
output_path <- value("output")
if (any(!nzchar(c(task_path, library_path, output_path)))) {
    stop("Required arguments: --task=PATH --library=PATH --output=PATH")
}

.libPaths(unique(c(library_path, .libPaths())))
suppressPackageStartupMessages(library(fastPLS))
`%||%` <- function(left, right) {
    if (is.null(left) || !length(left)) right else left
}
task <- readRDS(task_path)
task$Xtrain <- float::fl(as.matrix(task$Xtrain))
task$Xtest <- float::fl(as.matrix(task$Xtest))
classification <- is.factor(task$Ytrain) || is.character(task$Ytrain)
if (!classification) {
    task$Ytrain <- float::fl(as.matrix(task$Ytrain))
    task$Ytest <- as.matrix(task$Ytest)
}

backend <- value("backend", "metal")
family <- value("family", "simpls")
scaling <- match.arg(
    value("scaling", "centering"),
    c("centering", "autoscaling", "none")
)
components <- as.integer(strsplit(value("components", "1,2,5,10,20,50"),
                                  ",", fixed = TRUE)[[1L]])
seeds <- as.integer(strsplit(value("seeds", "1,2,3,4,5"),
                             ",", fixed = TRUE)[[1L]])
oversample <- value("oversample", "auto")
power <- value("power", "auto")
if (xor(identical(oversample, "auto"), identical(power, "auto"))) {
    stop("oversample and power must both be 'auto' or both be integers")
}
if (!identical(oversample, "auto")) {
    oversample <- as.integer(oversample)
    power <- as.integer(power)
    if (is.na(oversample) || oversample < 0L || is.na(power) || power < 0L) {
        stop("oversample and power must be non-negative integers")
    }
}
if (anyNA(components) || any(components < 1L) ||
        anyNA(seeds) || any(seeds < 0L)) {
    stop("components must be positive and seeds non-negative integers")
}

rows <- vector("list", length(seeds) * length(components))
position <- 0L
for (seed in seeds) {
    gc(FALSE)
    started <- proc.time()[[3L]]
    fit_arguments <- list(
        task$Xtrain,
        task$Ytrain,
        ncomp = components,
        scaling = scaling,
        method = family,
        svd.method = "rsvd",
        backend = backend,
        classifier = "argmax",
        fit = FALSE,
        return_variance = FALSE,
        return_loadings = FALSE,
        proj = FALSE,
        seed = seed
    )
    if (!identical(oversample, "auto")) {
        fit_arguments$oversample <- oversample
        fit_arguments$power <- power
    }
    fit <- suppressWarnings(do.call(pls, fit_arguments))
    fit_seconds <- unname(proc.time()[[3L]] - started)
    started <- proc.time()[[3L]]
    prediction <- predict(fit, task$Xtest, backend = backend)$Ypred
    prediction_seconds <- unname(proc.time()[[3L]] - started)
    if (!is.list(prediction)) prediction <- list(prediction)
    controls <- fit$diagnostics$rsvd %||%
        fit$diagnostics$resident_controls %||%
        fit$diagnostics$simpls %||% list()

    for (index in seq_along(components)) {
        position <- position + 1L
        predicted <- prediction[[index]]
        if (inherits(predicted, "float32")) predicted <- float::dbl(predicted)
        metric <- if (classification) {
            mean(factor(predicted, levels = levels(task$Ytest)) == task$Ytest)
        } else {
            sqrt(mean((task$Ytest - predicted)^2))
        }
        rows[[position]] <- data.frame(
            dataset = task$dataset,
            package_version = as.character(packageVersion("fastPLS")),
            family = family,
            backend = backend,
            precision = "float32",
            scaling = scaling,
            component = components[[index]],
            seed = seed,
            fit_path_seconds = fit_seconds,
            prediction_path_seconds = prediction_seconds,
            metric_name = if (classification) "accuracy" else "rmsd",
            metric = metric,
            oversample = controls$effective_oversample %||%
                controls$oversample %||% NA_integer_,
            power = controls$effective_power %||%
                controls$power %||% NA_integer_,
            route = fit$xprod_mode %||%
                fit$diagnostics$residency$route %||% NA_character_,
            stringsAsFactors = FALSE
        )
    }
}

result <- do.call(rbind, rows)
dir.create(dirname(output_path), recursive = TRUE, showWarnings = FALSE)
write.csv(result, output_path, row.names = FALSE)
