#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
value <- function(name, default = NULL) {
    prefix <- paste0("--", name, "=")
    hit <- args[startsWith(args, prefix)]
    if (!length(hit)) return(default)
    substring(hit[[length(hit)]], nchar(prefix) + 1L)
}

library_path <- value("library")
task_path <- value("dataset")
output_path <- value("output")
backend <- value("backend", "cuda")
classifier <- value("classifier", "lda")
method <- value("method", "simpls")
ncomp <- as.integer(strsplit(value("ncomp", "10,20,30,40,50"), ",",
                             fixed = TRUE)[[1L]])
repetitions <- as.integer(value("repetitions", "11"))

if (any(!nzchar(c(library_path, task_path, output_path)))) {
    stop("Required arguments: --library, --dataset, and --output")
}
.libPaths(unique(c(library_path, .libPaths())))
suppressPackageStartupMessages(library(fastPLS))
task <- readRDS(task_path)
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

rows <- vector("list", repetitions)
for (index in seq_len(repetitions)) {
    gc(FALSE)
    started <- proc.time()[[3L]]
    fit <- pls(
        task$Xtrain, task$Ytrain, ncomp = ncomp, method = method,
        backend = backend, classifier = classifier, fit = FALSE,
        return_variance = FALSE, return_loadings = FALSE, seed = 123
    )
    fit_seconds <- proc.time()[[3L]] - started
    started <- proc.time()[[3L]]
    prediction <- predict(fit, task$Xtest, backend = backend, top = 5L)
    prediction_seconds <- proc.time()[[3L]] - started
    top1 <- vapply(
        prediction$Ypred,
        function(estimate) mean(estimate == task$Ytest),
        numeric(1)
    )
    top5 <- vapply(
        prediction$Ypred_top,
        function(estimate) {
            mean(rowSums(estimate == as.character(task$Ytest)) > 0L)
        },
        numeric(1)
    )
    rows[[index]] <- data.frame(
        package_version = as.character(packageVersion("fastPLS")),
        backend = backend,
        method = method,
        classifier = classifier,
        replicate = index,
        fit_seconds = unname(fit_seconds),
        prediction_seconds = unname(prediction_seconds),
        total_seconds = unname(fit_seconds + prediction_seconds),
        top1_last = unname(tail(top1, 1L)),
        top5_last = unname(tail(top5, 1L)),
        stringsAsFactors = FALSE
    )
}
utils::write.csv(do.call(rbind, rows), output_path, row.names = FALSE)
