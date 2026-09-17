#!/usr/bin/env Rscript

library_path <- Sys.getenv("FASTPLS_LIB")
task_path <- Sys.getenv("TASK_RDS")
if (!nzchar(library_path) || !nzchar(task_path)) {
    stop("Set FASTPLS_LIB and TASK_RDS")
}
.libPaths(unique(c(library_path, .libPaths())))
suppressPackageStartupMessages(library(fastPLS))
task <- readRDS(task_path)
if (all(c("Xtrain_rds", "Xtest_rds") %in% names(task))) {
    task$Xtrain <- readRDS(task$Xtrain_rds)
    task$Xtest <- readRDS(task$Xtest_rds)
}
if (!all(c("Xtrain", "Ytrain", "Xtest") %in% names(task))) {
    stop("Task must contain Xtrain, Ytrain, and Xtest data or RDS paths")
}
fit <- pls(
    task$Xtrain,
    task$Ytrain,
    ncomp = as.integer(Sys.getenv("NCOMP", "50")),
    method = Sys.getenv("METHOD", "simpls"),
    backend = "cuda",
    classifier = Sys.getenv("CLASSIFIER", "argmax"),
    fit = FALSE,
    return_variance = FALSE,
    return_loadings = FALSE,
    seed = as.integer(Sys.getenv("SEED", "123"))
)
prediction <- predict(fit, task$Xtest, backend = "cuda")
stopifnot(length(prediction$Ypred) > 0L)
