#!/usr/bin/env Rscript

library_path <- Sys.getenv("FASTPLS_LIB")
task_path <- Sys.getenv("TASK_RDS")
output_path <- Sys.getenv("OUTPUT_RDS")
if (any(!nzchar(c(library_path, task_path, output_path)))) {
    stop("Set FASTPLS_LIB, TASK_RDS, and OUTPUT_RDS")
}
.libPaths(unique(c(library_path, .libPaths())))
suppressPackageStartupMessages(library(fastPLS))
task <- readRDS(task_path)
ncomp <- as.integer(strsplit(Sys.getenv("NCOMP", "50"), ",", fixed = TRUE)[[1L]])
classifier <- Sys.getenv("CLASSIFIER", "argmax")
backend <- Sys.getenv("BACKEND", "cuda")
precision <- Sys.getenv("PRECISION", "float32")

if (identical(precision, "float32")) {
    task$Xtrain <- if (inherits(task$Xtrain, "float32")) {
        task$Xtrain
    } else {
        float::fl(as.matrix(task$Xtrain))
    }
    task$Xtest <- if (inherits(task$Xtest, "float32")) {
        task$Xtest
    } else {
        float::fl(as.matrix(task$Xtest))
    }
} else if (!identical(precision, "float64")) {
    stop("PRECISION must be float32 or float64")
}
fit <- pls(
    task$Xtrain,
    task$Ytrain,
    ncomp = ncomp,
    method = Sys.getenv("METHOD", "simpls"),
    backend = backend,
    classifier = classifier,
    fit = FALSE,
    return_variance = FALSE,
    return_loadings = FALSE,
    seed = as.integer(Sys.getenv("SEED", "123"))
)
prediction <- predict(fit, task$Xtest, backend = backend, top = 5L)
saveRDS(
    list(
        version = as.character(packageVersion("fastPLS")),
        classifier = classifier,
        backend = backend,
        precision = precision,
        ncomp = ncomp,
        prediction = prediction,
        diagnostics = fit$diagnostics
    ),
    output_path,
    compress = FALSE
)
