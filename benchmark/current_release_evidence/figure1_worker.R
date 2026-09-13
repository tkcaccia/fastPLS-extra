#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 13L) {
    stop(paste(
        "Usage: figure1_worker.R LIB TASK DATASET METHOD CLASSIFIER NCOMP REPLICATE",
        "OUTPUT READY GO OVERSAMPLE POWER EXPECTED_VERSION"
    ), call. = FALSE)
}

lib <- args[[1L]]
task_path <- normalizePath(args[[2L]], mustWork = TRUE)
dataset <- args[[3L]]
method <- args[[4L]]
classifier <- args[[5L]]
ncomp <- as.integer(args[[6L]])
replicate_id <- as.integer(args[[7L]])
output <- args[[8L]]
ready <- args[[9L]]
go <- args[[10L]]
oversample <- as.integer(args[[11L]])
power <- as.integer(args[[12L]])
expected_version <- args[[13L]]

if (!method %in% c("simpls", "plssvd")) {
    stop("METHOD must be 'simpls' or 'plssvd'", call. = FALSE)
}

.libPaths(c(lib, .libPaths()))
suppressPackageStartupMessages(library(fastPLS))
loaded_version <- as.character(packageVersion("fastPLS"))
if (!identical(loaded_version, expected_version)) {
    stop(
        "Figure 1 benchmark expected fastPLS ", expected_version,
        " but loaded ", loaded_version,
        call. = FALSE
    )
}
linked_blas <- fastPLS_blas()
if (!identical(linked_blas, "OpenBLAS")) {
    stop(
        "Figure 1 publication benchmark requires an OpenBLAS-linked fastPLS build; detected ",
        linked_blas,
        call. = FALSE
    )
}

script <- sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[[1L]])
source(file.path(dirname(dirname(normalizePath(script))),
                 "helpers_dataset_memory_compare.R"))

task <- readRDS(task_path)
task <- validate_publication_task(task, dataset)
if (!task$task_type %in% c("classification", "regression")) {
    stop("Figure 1 worker requires a classification or regression dataset", call. = FALSE)
}
task <- coerce_task_precision(task, "float32")
invisible(gc(full = TRUE))

rss_mib <- function() {
    value <- ps::ps_memory_info(ps::ps_handle())[["rss"]]
    as.numeric(value) / 1024^2
}
writeLines(format(rss_mib(), digits = 15L), ready)
while (!file.exists(go)) Sys.sleep(0.01)

fit_time <- system.time({
    fit <- pls(
        task$Xtrain,
        task$Ytrain,
        ncomp = ncomp,
        scaling = "centering",
        method = method,
        backend = "cpu",
        n.cores = 1L,
        classifier = if (identical(task$task_type, "classification")) {
            classifier
        } else {
            "argmax"
        },
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
    prediction <- predict(fit, task$Xtest, backend = "cpu")
})[["elapsed"]]

prediction_keys <- names(prediction$Ypred)
if (!length(prediction_keys)) {
    stop("Figure 1 prediction returned no component path", call. = FALSE)
}
key <- prediction_keys[[length(prediction_keys)]]
effective_ncomp <- as.integer(sub("^ncomp=", "", key))
predicted <- prediction$Ypred[[key]]
if (identical(task$task_type, "classification")) {
    truth <- factor(task$Ytest)
    predicted <- factor(predicted, levels = levels(truth))
    recall <- vapply(
        levels(truth),
        function(level) {
            keep <- truth == level
            if (!any(keep)) return(NA_real_)
            mean(predicted[keep] == level)
        },
        numeric(1L)
    )
    accuracy <- mean(predicted == truth)
    balanced_accuracy <- mean(recall, na.rm = TRUE)
    correct <- sum(predicted == truth)
    test_total <- length(truth)
    rmsd <- q2 <- mae <- NA_real_
} else {
    truth <- as_double_matrix(task$Ytest)
    predicted <- as_double_matrix(predicted)
    evaluated <- evaluate(
        observed = truth,
        predicted = predicted,
        ytrain = as_double_matrix(task$Ytrain),
        bycol = FALSE
    )$metrics
    accuracy <- balanced_accuracy <- correct <- NA_real_
    test_total <- nrow(truth)
    rmsd <- evaluated[["RMSD"]]
    q2 <- evaluated[["Q2"]]
    mae <- evaluated[["MAE"]]
}
direction <- if (identical(method, "simpls")) {
    fit$diagnostics$simpls_direction
} else {
    list()
}
blas <- linked_blas
blas_path <- tryCatch(
    as.character(sessionInfo()$BLAS),
    error = function(error) NA_character_
)
row <- data.frame(
    package_version = loaded_version,
    package_path = find.package("fastPLS"),
    platform = R.version$platform,
    blas = blas,
    blas_path = blas_path,
    dataset = dataset,
    task_type = task$task_type,
    n_train = nrow(task$Xtrain),
    n_test = nrow(task$Xtest),
    p = ncol(task$Xtrain),
    q = if (identical(task$task_type, "classification")) {
        nlevels(factor(task$Ytrain))
    } else {
        ncol(task$Ytrain)
    },
    split_seed = task$split_seed %||% NA_integer_,
    method = method,
    backend = "cpu",
    precision = "float32",
    classifier = if (identical(task$task_type, "classification")) {
        classifier
    } else {
        "none"
    },
    ncomp_requested = ncomp,
    ncomp = effective_ncomp,
    replicate = replicate_id,
    fit_sec = fit_time,
    prediction_sec = prediction_time,
    total_sec = fit_time + prediction_time,
    accuracy = accuracy,
    balanced_accuracy = balanced_accuracy,
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
    direction_rule = direction$rule %||% NA_character_,
    directions_per_solve = direction$directions_per_solve %||% NA_integer_,
    refresh_width = direction$refresh_width %||% NA_integer_,
    fresh_start = direction$fresh_start %||% NA,
    status = "success",
    stringsAsFactors = FALSE
)
dir.create(dirname(output), recursive = TRUE, showWarnings = FALSE)
write.csv(row, output, row.names = FALSE)
