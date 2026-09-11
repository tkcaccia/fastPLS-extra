#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 5L) {
    stop(
        "Usage: validate_fold_cache_predictions.R LIB TASK BACKEND METHOD NCOMP",
        call. = FALSE
    )
}

.libPaths(unique(c(args[[1L]], .libPaths())))
suppressPackageStartupMessages(library(fastPLS))
task <- readRDS(args[[2L]])
backend <- args[[3L]]
method <- args[[4L]]
ncomp <- as.integer(args[[5L]])
X <- if (inherits(task$Xtrain, "float32")) {
    task$Xtrain
} else {
    float::fl(as.matrix(task$Xtrain))
}
Y <- factor(task$Ytrain)
constrain <- task$constrain_train
if (is.null(constrain)) constrain <- seq_len(nrow(X))

extract_prediction <- function(result) {
    prediction <- result$pred
    if (is.data.frame(prediction) || is.list(prediction)) {
        prediction <- prediction[[length(prediction)]]
    } else if (is.matrix(prediction)) {
        prediction <- prediction[, ncol(prediction)]
    }
    as.character(prediction)
}

run <- function(cache) {
    value <- if (cache) "1" else "0"
    Sys.setenv(
        FASTPLS_CV_FOLD_GRAM_CACHE = value,
        FASTPLS_CV_FOLD_CROSSCOV_CACHE = value,
        FASTPLS_CV_CLASS_SUM_CACHE = value
    )
    fit <- pls.single.cv(
        X, Y, constrain = constrain, ncomp = ncomp, kfold = 10,
        method = method, backend = backend, classifier = "argmax",
        fit = FALSE, seed = 123, selection_metric = "accuracy"
    )
    list(
        prediction = extract_prediction(fit),
        fold = fit$fold,
        best_ncomp = fit$best_ncomp,
        accuracy = fit$best_metric_value
    )
}

optimized <- run(TRUE)
reference <- run(FALSE)
cat(sprintf(
    paste0(
        "backend=%s method=%s ncomp=%d agreement=%.10f disagreements=%d ",
        "accuracy_on=%.10f accuracy_off=%.10f best_on=%d best_off=%d ",
        "fold_equal=%s\n"
    ),
    backend, method, ncomp,
    mean(optimized$prediction == reference$prediction),
    sum(optimized$prediction != reference$prediction),
    optimized$accuracy, reference$accuracy,
    optimized$best_ncomp, reference$best_ncomp,
    identical(optimized$fold, reference$fold)
))
