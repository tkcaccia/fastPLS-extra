#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
value <- function(name, default = NULL) {
    prefix <- paste0("--", name, "=")
    hit <- args[startsWith(args, prefix)]
    if (!length(hit)) return(default)
    substring(hit[[length(hit)]], nchar(prefix) + 1L)
}
`%||%` <- function(left, right) if (is.null(left)) right else left

task_path <- value("task")
library_path <- value("library")
output_path <- value("output")
backend <- value("backend")
precision <- value("precision", "float32")
ncomp <- as.integer(value("ncomp", "50"))
seed <- as.integer(value("seed", "123"))
oversample <- as.integer(value("oversample", "32"))
power <- as.integer(value("power", "5"))
families <- strsplit(
    value("families", "plssvd,simpls,opls,kernelpls"), ",", fixed = TRUE
)[[1L]]

if (any(!nzchar(c(task_path, library_path, output_path, backend)))) {
    stop("Required arguments: --task, --library, --output, and --backend")
}
if (!backend %in% c("cuda", "metal")) {
    stop("backend must be cuda or metal")
}
if (!precision %in% c("float32", "float64")) {
    stop("precision must be float32 or float64")
}

.libPaths(unique(c(library_path, .libPaths())))
suppressPackageStartupMessages(library(fastPLS))
task <- readRDS(task_path)
if (identical(precision, "float32")) {
    task$Xtrain <- float::fl(as.matrix(task$Xtrain))
    task$Xtest <- float::fl(as.matrix(task$Xtest))
    if (!is.factor(task$Ytrain) && !is.character(task$Ytrain)) {
        task$Ytrain <- float::fl(as.matrix(task$Ytrain))
        task$Ytest <- float::fl(as.matrix(task$Ytest))
    }
} else {
    task$Xtrain <- as.matrix(task$Xtrain)
    task$Xtest <- as.matrix(task$Xtest)
    if (!is.factor(task$Ytrain) && !is.character(task$Ytrain)) {
        task$Ytrain <- as.matrix(task$Ytrain)
        task$Ytest <- as.matrix(task$Ytest)
    }
}

classification <- is.factor(task$Ytrain) || is.character(task$Ytrain)
prediction <- function(model, backend) {
    output <- predict(model, task$Xtest, backend = backend)$Ypred
    if (is.list(output)) output <- output[[length(output)]]
    if (length(dim(output)) == 3L) {
        output <- output[, , dim(output)[[3L]], drop = FALSE]
        dim(output) <- dim(output)[1:2]
    }
    if (inherits(output, "float32")) output <- float::dbl(output)
    output
}

rows <- vector("list", length(families))
for (index in seq_along(families)) {
    family <- families[[index]]
    fit_one <- function(backend) {
        pls(
            task$Xtrain, task$Ytrain,
            ncomp = ncomp,
            scaling = "none",
            method = family,
            backend = backend,
            svd.method = "rsvd",
            classifier = "argmax",
            kernel = "linear",
            fit = FALSE,
            return_variance = FALSE,
            return_loadings = FALSE,
            seed = seed,
            oversample = oversample,
            power = power
        )
    }
    reference <- fit_one("cpu")
    candidate <- fit_one(backend)
    reference_prediction <- prediction(reference, "cpu")
    candidate_prediction <- prediction(candidate, backend)
    if (classification) {
        observed <- task$Ytest
        reference_labels <- factor(reference_prediction, levels = levels(observed))
        candidate_labels <- factor(candidate_prediction, levels = levels(observed))
        reference_metric <- mean(reference_labels == observed)
        candidate_metric <- mean(candidate_labels == observed)
        prediction_agreement <- mean(reference_labels == candidate_labels)
        relative_prediction_error <- NA_real_
    } else {
        observed <- task$Ytest
        if (inherits(observed, "float32")) observed <- float::dbl(observed)
        reference_metric <- unname(evaluate(observed, reference_prediction)$metrics[["RMSD"]])
        candidate_metric <- unname(evaluate(observed, candidate_prediction)$metrics[["RMSD"]])
        prediction_agreement <- NA_real_
        denominator <- sqrt(sum(reference_prediction^2))
        relative_prediction_error <- sqrt(sum(
            (candidate_prediction - reference_prediction)^2
        )) / max(denominator, .Machine$double.eps)
    }
    rows[[index]] <- data.frame(
        dataset = task$dataset,
        family = family,
        precision = precision,
        reference_backend = "cpu",
        candidate_backend = backend,
        ncomp = ncomp,
        reference_metric = reference_metric,
        candidate_metric = candidate_metric,
        metric_difference = candidate_metric - reference_metric,
        prediction_agreement = prediction_agreement,
        relative_prediction_error = relative_prediction_error,
        reference_direction_rule =
            reference$diagnostics$simpls_direction$rule %||% NA_character_,
        candidate_direction_rule =
            candidate$diagnostics$simpls_direction$rule %||% NA_character_,
        candidate_refresh_width =
            candidate$diagnostics$simpls_direction$refresh_width %||% NA_integer_,
        stringsAsFactors = FALSE
    )
}

dir.create(dirname(output_path), recursive = TRUE, showWarnings = FALSE)
write.csv(do.call(rbind, rows), output_path, row.names = FALSE)
