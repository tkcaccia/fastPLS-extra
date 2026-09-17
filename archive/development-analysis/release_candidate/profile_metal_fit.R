#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 4L) {
    stop("usage: profile_metal_fit.R LIBRARY TASK NCOMP CLASSIFIER")
}

.libPaths(unique(c(normalizePath(args[[1L]], mustWork = TRUE), .libPaths())))
suppressPackageStartupMessages(library(fastPLS))
stopifnot(isTRUE(has_metal()))

task <- readRDS(args[[2L]])
ncomp <- as.integer(args[[3L]])
classifier <- match.arg(args[[4L]], c("argmax", "lda"))
if (is.na(ncomp) || ncomp < 1L) {
    stop("NCOMP must be a positive integer")
}

to_float <- function(value) {
    if (inherits(value, "float32")) value else float::fl(as.matrix(value))
}
task$Xtrain <- to_float(task$Xtrain)
task$Xtest <- to_float(task$Xtest)

fit <- pls(
    task$Xtrain,
    task$Ytrain,
    ncomp = ncomp,
    method = "simpls",
    backend = "metal",
    classifier = classifier,
    fit = FALSE,
    proj = FALSE,
    return_variance = FALSE,
    return_loadings = FALSE,
    seed = 123
)
prediction <- predict(fit, task$Xtest, backend = "metal")$Ypred
if (is.list(prediction)) {
    prediction <- prediction[[length(prediction)]]
}
cat(sprintf("accuracy=%.9f\n", mean(prediction == task$Ytest)))
