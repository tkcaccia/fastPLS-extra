#!/usr/bin/env Rscript

options(stringsAsFactors = FALSE)

args <- commandArgs(trailingOnly = TRUE)
parse_args <- function(values) {
    result <- list()
    for (value in values) {
        bits <- strsplit(sub("^--", "", value), "=", fixed = TRUE)[[1L]]
        result[[bits[[1L]]]] <- paste(bits[-1L], collapse = "=")
    }
    result
}
arg <- parse_args(args)
value <- function(name, default = NULL) arg[[name]] %||% default
`%||%` <- function(x, y) if (is.null(x) || !length(x)) y else x

library_path <- value("library", Sys.getenv("FASTPLS_TEST_LIB", ""))
if (nzchar(library_path)) {
    .libPaths(c(normalizePath(library_path, mustWork = TRUE), .libPaths()))
}
suppressPackageStartupMessages(library(fastPLS))

helper <- value(
    "helper",
    {
        script_arg <- grep("^--file=", commandArgs(FALSE), value = TRUE)
        script_path <- sub("^--file=", "", script_arg[[1L]])
        file.path(dirname(dirname(normalizePath(script_path))),
                  "helpers_dataset_memory_compare.R")
    }
)
source(helper)

dataset <- tolower(value("dataset", "metref"))
method <- tolower(value("method", "opls"))
backend <- tolower(value("backend", "cuda"))
precision <- tolower(value("precision", "float32"))
classifier <- tolower(value("classifier", "argmax"))
kernel <- tolower(value("kernel", "linear"))
ncomp <- as.integer(value("ncomp", "10"))
north <- as.integer(value("north", "1"))
seed <- as.integer(value("seed", "123"))
output <- value("output", "")

task <- as_task(find_dataset_rdata(dataset), dataset, split_seed = seed)
task <- coerce_task_precision(task, precision)
classification <- identical(task$task_type, "classification")

start <- proc.time()[["elapsed"]]
status <- "ok"
message <- ""
fit <- tryCatch(
    pls(
        task$Xtrain,
        task$Ytrain,
        task$Xtest,
        task$Ytest,
        ncomp = ncomp,
        method = method,
        backend = backend,
        classifier = classifier,
        kernel = kernel,
        north = north,
        fit = FALSE,
        proj = FALSE,
        return_variance = FALSE,
        seed = seed
    ),
    error = function(error) {
        status <<- "error"
        message <<- conditionMessage(error)
        NULL
    }
)
seconds <- proc.time()[["elapsed"]] - start

metric_name <- metric_value <- NA
resident_route <- NA_character_
if (!is.null(fit)) {
    index <- length(fit$Ypred)
    if (classification) {
        metric_name <- "accuracy"
        metric_value <- mean(
            as.character(fit$Ypred[[index]]) == as.character(task$Ytest)
        )
    } else {
        metric_name <- "RMSD"
        predicted <- if (is.array(fit$Ypred) && length(dim(fit$Ypred)) == 3L) {
            fit$Ypred[, , dim(fit$Ypred)[[3L]], drop = TRUE]
        } else {
            value <- fit$Ypred[[index]]
            if (inherits(value, "float32")) float::dbl(value) else as.matrix(value)
        }
        observed <- if (inherits(task$Ytest, "float32")) {
            float::dbl(task$Ytest)
        } else {
            as.matrix(task$Ytest)
        }
        metric_value <- sqrt(mean((predicted - observed)^2))
    }
    resident_route <- fit$diagnostics$residency$route %||% NA_character_
}

record <- data.frame(
    dataset = dataset,
    n_train = nrow(task$Xtrain),
    n_test = nrow(task$Xtest),
    p = ncol(task$Xtrain),
    q = if (classification) nlevels(task$Ytrain) else ncol(task$Ytrain),
    method = method,
    kernel = kernel,
    classifier = if (classification) classifier else NA_character_,
    backend = backend,
    precision = precision,
    ncomp = ncomp,
    north = if (method == "opls") north else NA_integer_,
    seconds = seconds,
    metric_name = metric_name,
    metric_value = metric_value,
    resident_route = resident_route,
    status = status,
    message = message,
    stringsAsFactors = FALSE
)

if (nzchar(output)) {
    dir.create(dirname(output), recursive = TRUE, showWarnings = FALSE)
    write.csv(record, output, row.names = FALSE)
}
print(record, row.names = FALSE)
