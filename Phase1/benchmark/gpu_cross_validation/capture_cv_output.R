#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
if (!length(args) %in% 3:4) {
    stop("Usage: capture_cv_output.R LIBRARY TASK OUTPUT [CLASSIFIER]")
}
classifier <- if (length(args) == 4L) args[[4L]] else "lda"

.libPaths(unique(c(args[[1L]], .libPaths())))
suppressPackageStartupMessages(library(fastPLS))
task <- readRDS(args[[2L]])

result <- pls.single.cv(
    task$Xtrain,
    task$Ytrain,
    constrain = task$constrain_train,
    ncomp = 1:6,
    kfold = 5,
    method = "simpls",
    backend = "cuda",
    classifier = classifier,
    fit = FALSE,
    seed = 123
)

saveRDS(
    list(
        pred = result$pred,
        Ypred = result$Ypred,
        Q2Y = result$Q2Y,
        RMSD = result$RMSD,
        accuracy = result$accuracy,
        fold = result$fold
    ),
    args[[3L]],
    version = 3L
)
