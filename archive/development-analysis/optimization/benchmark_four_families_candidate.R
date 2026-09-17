#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
value <- function(name, default = NULL) {
    prefix <- paste0("--", name, "=")
    hit <- args[startsWith(args, prefix)]
    if (!length(hit)) return(default)
    substring(hit[[length(hit)]], nchar(prefix) + 1L)
}

task_path <- value("task")
library_path <- value("library")
output_path <- value("output")
if (any(!nzchar(c(task_path, library_path, output_path)))) {
    stop("Required arguments: --task=PATH --library=PATH --output=PATH")
}

.libPaths(unique(c(library_path, .libPaths())))
suppressPackageStartupMessages(library(fastPLS))
task <- readRDS(task_path)
requested_precision <- value("precision", "input")
if (!requested_precision %in% c("input", "float32", "float64")) {
    stop("precision must be input, float32, or float64")
}
if (identical(requested_precision, "float32")) {
    task$Xtrain <- float::fl(as.matrix(task$Xtrain))
    task$Xtest <- float::fl(as.matrix(task$Xtest))
    if (!is.factor(task$Ytrain) && !is.character(task$Ytrain)) {
        task$Ytrain <- float::fl(as.matrix(task$Ytrain))
        task$Ytest <- float::fl(as.matrix(task$Ytest))
    }
} else if (identical(requested_precision, "float64")) {
    task$Xtrain <- as.matrix(task$Xtrain)
    task$Xtest <- as.matrix(task$Xtest)
    if (!is.factor(task$Ytrain) && !is.character(task$Ytrain)) {
        task$Ytrain <- as.matrix(task$Ytrain)
        task$Ytest <- as.matrix(task$Ytest)
    }
}
families <- strsplit(value("families", "plssvd,simpls,opls,kernelpls"), ",",
                     fixed = TRUE)[[1L]]
backend <- value("backend", "cpu")
kernel <- value("kernel", "linear")
ncomp <- as.integer(value("ncomp", "50"))
repetitions <- as.integer(value("repetitions", "5"))
seed <- as.integer(value("seed", "123"))
parse_control <- function(name) {
    requested <- tolower(value(name, "auto"))
    if (identical(requested, "auto")) return(NULL)
    parsed <- as.integer(requested)
    if (is.na(parsed) || parsed < 0L) {
        stop(name, " must be a non-negative integer or 'auto'")
    }
    parsed
}
oversample <- parse_control("oversample")
power <- parse_control("power")
if (anyNA(c(ncomp, repetitions, seed)) ||
        ncomp < 1L || repetitions < 1L) {
    stop("ncomp, repetitions, and seed must be positive integers")
}

classification <- is.factor(task$Ytrain) || is.character(task$Ytrain)
metric_name <- if (classification) "accuracy" else "rmsd"
rows <- vector("list", length(families) * repetitions)
position <- 0L

for (family in families) {
    for (replicate_id in seq_len(repetitions)) {
        position <- position + 1L
        gc(FALSE)
        status <- "success"
        error_message <- NA_character_
        fit_seconds <- prediction_seconds <- metric <- NA_real_
        effective_oversample <- effective_power <- NA_integer_
        control_profile <- NA_character_
        result <- tryCatch({
            started <- proc.time()[[3L]]
            fit_arguments <- list(
                task$Xtrain,
                task$Ytrain,
                ncomp = ncomp,
                scaling = "none",
                method = family,
                svd.method = "rsvd",
                backend = backend,
                classifier = "argmax",
                kernel = kernel,
                fit = FALSE,
                return_variance = FALSE,
                return_loadings = FALSE,
                proj = FALSE,
                seed = seed
            )
            if (!is.null(oversample)) fit_arguments$oversample <- oversample
            if (!is.null(power)) fit_arguments$power <- power
            fit <- do.call(pls, fit_arguments)
            fit_seconds <- unname(proc.time()[[3L]] - started)
            effective_oversample <- fit$diagnostics$rsvd$oversample
            effective_power <- fit$diagnostics$rsvd$power
            control_profile <- fit$diagnostics$rsvd$control_profile
            started <- proc.time()[[3L]]
            prediction <- predict(fit, task$Xtest, backend = backend)$Ypred
            if (is.list(prediction)) prediction <- prediction[[length(prediction)]]
            if (length(dim(prediction)) == 3L) {
                prediction <- prediction[, , dim(prediction)[[3L]], drop = FALSE]
                dim(prediction) <- dim(prediction)[1:2]
            }
            if (inherits(prediction, "float32")) {
                prediction <- float::dbl(prediction)
            }
            prediction_seconds <- unname(proc.time()[[3L]] - started)
            if (classification) {
                predicted <- factor(prediction, levels = levels(task$Ytest))
                metric <- mean(predicted == task$Ytest)
            } else {
                observed <- task$Ytest
                if (inherits(observed, "float32")) {
                    observed <- float::dbl(observed)
                }
                assessed <- evaluate(observed = observed, predicted = prediction)
                metric <- unname(assessed$metrics[["RMSD"]])
            }
            NULL
        }, error = function(condition) condition)
        if (inherits(result, "condition")) {
            status <- "error"
            error_message <- conditionMessage(result)
        }
        rows[[position]] <- data.frame(
            dataset = task$dataset,
            family = family,
            kernel = if (family == "kernelpls") kernel else NA_character_,
            backend = backend,
            precision = if (inherits(task$Xtrain, "float32")) "float32" else "float64",
            package_version = as.character(packageVersion("fastPLS")),
            ncomp = ncomp,
            replicate = replicate_id,
            oversample = effective_oversample,
            power = effective_power,
            control_profile = control_profile,
            seed = seed,
            fit_seconds = fit_seconds,
            prediction_seconds = prediction_seconds,
            total_seconds = fit_seconds + prediction_seconds,
            metric = metric,
            metric_name = metric_name,
            status = status,
            error = error_message,
            stringsAsFactors = FALSE
        )
    }
}

result <- do.call(rbind, rows)
dir.create(dirname(output_path), recursive = TRUE, showWarnings = FALSE)
write.csv(result, output_path, row.names = FALSE)
