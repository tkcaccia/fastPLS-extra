#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 11L) {
    stop(paste(
        "Usage: figure_s_cuda_worker.R LIB TASK DATASET NCOMP REPLICATE",
        "OUTPUT READY GO OVERSAMPLE POWER EXPECTED_VERSION"
    ), call. = FALSE)
}

lib <- args[[1L]]
task_path <- normalizePath(args[[2L]], mustWork = TRUE)
dataset <- args[[3L]]
ncomp <- as.integer(args[[4L]])
replicate_id <- as.integer(args[[5L]])
output <- args[[6L]]
ready <- args[[7L]]
go <- args[[8L]]
oversample <- as.integer(args[[9L]])
power <- as.integer(args[[10L]])
expected_version <- args[[11L]]

.libPaths(c(lib, .libPaths()))
suppressPackageStartupMessages(library(fastPLS))
loaded_version <- as.character(packageVersion("fastPLS"))
if (!identical(loaded_version, expected_version)) {
    stop(
        "CUDA comparison expected fastPLS ", expected_version,
        " but loaded ", loaded_version,
        call. = FALSE
    )
}

script <- sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[[1L]])
source(file.path(dirname(dirname(normalizePath(script))),
                 "helpers_dataset_memory_compare.R"))

task <- readRDS(task_path)
if (!is.null(task$Xtrain_rds) && !is.null(task$Xtest_rds)) {
    task$Xtrain <- readRDS(task$Xtrain_rds)
    task$Xtest <- readRDS(task$Xtest_rds)
    task$task_type <- "classification"
    task$split_seed <- task$seed
}
task <- validate_publication_task(task, dataset)
task <- coerce_task_precision(task, "float32")
task_type <- match.arg(task$task_type, c("classification", "regression"))
classifier <- if (identical(task_type, "classification")) "lda" else "argmax"
invisible(gc(full = TRUE))

rss_mib <- function() {
    as.numeric(ps::ps_memory_info(ps::ps_handle())[["rss"]]) / 1024^2
}

fit_once <- function() {
    fit_time <- system.time({
        fit <- pls(
            task$Xtrain,
            task$Ytrain,
            ncomp = ncomp,
            scaling = "centering",
            method = "simpls",
            backend = "cuda",
            n.cores = 1L,
            classifier = classifier,
            fit = FALSE,
            proj = FALSE,
            return_variance = FALSE,
            return_loadings = FALSE,
            oversample = oversample,
            power = power,
            seed = 123L
        )
    })[["elapsed"]]
    prediction_time <- system.time({
        prediction <- predict(fit, task$Xtest, backend = "cuda")
    })[["elapsed"]]
    list(
        fit = fit,
        prediction = prediction,
        fit_sec = fit_time,
        prediction_sec = prediction_time,
        total_sec = fit_time + prediction_time
    )
}

writeLines(format(rss_mib(), digits = 15L), ready)
while (!file.exists(go)) Sys.sleep(0.01)

cold <- fit_once()
warm <- fit_once()

prediction_keys <- names(cold$prediction$Ypred)
if (!length(prediction_keys)) {
    stop("CUDA prediction returned no component path", call. = FALSE)
}
key <- prediction_keys[[length(prediction_keys)]]
effective_ncomp <- as.integer(sub("^ncomp=", "", key))
predicted <- cold$prediction$Ypred[[key]]

accuracy <- balanced_accuracy <- top5_accuracy <- rmsd <- q2 <- mae <- NA_real_
correct <- NA_integer_
test_total <- nrow(task$Xtest)
if (identical(task_type, "classification")) {
    truth <- factor(task$Ytest)
    predicted <- factor(predicted, levels = levels(truth))
    recalls <- vapply(
        levels(truth),
        function(level) {
            keep <- truth == level
            if (!any(keep)) return(NA_real_)
            mean(predicted[keep] == level)
        },
        numeric(1L)
    )
    correct <- sum(predicted == truth)
    accuracy <- correct / length(truth)
    balanced_accuracy <- mean(recalls, na.rm = TRUE)
    if (!is.null(cold$prediction$top)) {
        ranked <- cold$prediction$top[[key]]
        if (is.matrix(ranked) && ncol(ranked) >= 5L) {
            top5_accuracy <- mean(vapply(
                seq_along(truth),
                function(index) as.character(truth[[index]]) %in%
                    as.character(ranked[index, seq_len(5L)]),
                logical(1L)
            ))
        }
    }
} else {
    truth <- as_double_matrix(task$Ytest)
    predicted <- as_double_matrix(predicted)
    evaluated <- evaluate(
        observed = truth,
        predicted = predicted,
        ytrain = as_double_matrix(task$Ytrain),
        bycol = FALSE
    )$metrics
    rmsd <- evaluated[["RMSD"]]
    q2 <- evaluated[["Q2"]]
    mae <- evaluated[["MAE"]]
}

diagnostics <- cold$fit$diagnostics
row <- data.frame(
    dataset = dataset,
    task_type = task_type,
    implementation = "fastPLS_cuda",
    package_version = loaded_version,
    precision = "float32",
    backend = "cuda",
    method = "simpls",
    classifier = if (identical(task_type, "classification")) "lda" else "none",
    replicate = replicate_id,
    n_train = nrow(task$Xtrain),
    n_test = nrow(task$Xtest),
    p = ncol(task$Xtrain),
    q = if (identical(task_type, "classification")) {
        nlevels(factor(task$Ytrain))
    } else {
        ncol(task$Ytrain)
    },
    ncomp_requested = ncomp,
    ncomp = effective_ncomp,
    cold_fit_sec = cold$fit_sec,
    cold_prediction_sec = cold$prediction_sec,
    cold_total_sec = cold$total_sec,
    warm_fit_sec = warm$fit_sec,
    warm_prediction_sec = warm$prediction_sec,
    warm_total_sec = warm$total_sec,
    accuracy = accuracy,
    balanced_accuracy = balanced_accuracy,
    top5_accuracy = top5_accuracy,
    correct = correct,
    test_total = test_total,
    rmsd = rmsd,
    q2 = q2,
    mae = mae,
    prefit_rss_mib = as.numeric(readLines(ready, warn = FALSE)[[1L]]),
    final_rss_mib = rss_mib(),
    oversample = oversample,
    power = power,
    seed = 123L,
    execution_route = diagnostics$execution_route %||% NA_character_,
    status = "success",
    error = "",
    retained_output = "compact fitted model and final held-out predictions",
    stringsAsFactors = FALSE
)
dir.create(dirname(output), recursive = TRUE, showWarnings = FALSE)
write.csv(row, output, row.names = FALSE)
