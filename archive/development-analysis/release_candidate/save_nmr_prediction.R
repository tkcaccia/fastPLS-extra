#!/usr/bin/env Rscript

# Save one NMR prediction from an isolated package library. Representation
# conversion is completed before timing so the result can be compared across
# explicit and implicit CUDA operator implementations.

args <- commandArgs(trailingOnly = TRUE)
argument <- function(name, default = NULL) {
    prefix <- paste0("--", name, "=")
    hit <- args[startsWith(args, prefix)]
    if (!length(hit)) return(default)
    substring(hit[[length(hit)]], nchar(prefix) + 1L)
}

task_path <- normalizePath(argument("task"), mustWork = TRUE)
library_path <- normalizePath(argument("library"), mustWork = TRUE)
output_path <- argument("output")
precision <- match.arg(argument("precision", "float32"),
                       c("float32", "float64"))
ncomp <- as.integer(argument("ncomp", "50"))
seed <- as.integer(argument("seed", "123"))
rsvd_oversample <- as.integer(argument("rsvd-oversample", "12"))
rsvd_power <- as.integer(argument("rsvd-power", "1"))
method <- match.arg(argument("method", "simpls"), c("plssvd", "simpls"))
if (!nzchar(output_path) || anyNA(c(ncomp, seed, rsvd_oversample, rsvd_power)) ||
        rsvd_oversample < 0L || rsvd_power < 0L) {
    stop("output, component count, seed, and rSVD controls must be valid")
}

.libPaths(unique(c(library_path, .libPaths())))
suppressPackageStartupMessages(library(fastPLS))
task <- readRDS(task_path)
to_float <- function(value) float::fl(as.matrix(value))
to_double <- function(value) {
    if (inherits(value, "float32")) value <- float::dbl(value)
    value <- as.matrix(value)
    storage.mode(value) <- "double"
    value
}
convert <- if (identical(precision, "float32")) to_float else to_double
task$Xtrain <- convert(task$Xtrain)
task$Ytrain <- convert(task$Ytrain)
task$Xtest <- convert(task$Xtest)

gc(full = TRUE)
fit_started <- proc.time()[[3L]]
fit <- pls(
    task$Xtrain,
    task$Ytrain,
    ncomp = ncomp,
    method = method,
    backend = "cuda",
    scaling = "centering",
    fit = FALSE,
    return_variance = FALSE,
    rsvd_oversample = rsvd_oversample,
    rsvd_power = rsvd_power,
    seed = seed
)
fit_seconds <- unname(proc.time()[[3L]] - fit_started)
prediction_started <- proc.time()[[3L]]
prediction <- predict(fit, task$Xtest, backend = "cuda")$Ypred
prediction_seconds <- unname(proc.time()[[3L]] - prediction_started)
if (is.list(prediction)) prediction <- prediction[[length(prediction)]]
if (length(dim(prediction)) == 3L) {
    prediction <- prediction[, , dim(prediction)[[3L]], drop = FALSE]
    dim(prediction) <- dim(prediction)[1:2]
}
if (inherits(prediction, "float32")) prediction <- float::dbl(prediction)
prediction <- as.matrix(prediction)

result <- list(
    prediction = prediction,
    package_version = as.character(packageVersion("fastPLS")),
    package_library = normalizePath(find.package("fastPLS"), mustWork = TRUE),
    precision = precision,
    method = method,
    ncomp = ncomp,
    seed = seed,
    rsvd_oversample = rsvd_oversample,
    rsvd_power = rsvd_power,
    fit_seconds = fit_seconds,
    prediction_seconds = prediction_seconds,
    diagnostics = fit$diagnostics
)
dir.create(dirname(output_path), recursive = TRUE, showWarnings = FALSE)
saveRDS(result, output_path, compress = FALSE)
print(result[setdiff(names(result), "prediction")])
