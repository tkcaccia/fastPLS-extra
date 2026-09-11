#!/usr/bin/env Rscript

# Benchmarks the compiled CV engine without retaining fold predictions. This
# separates model fitting, prediction, and metric reduction from public-object
# materialization, which can dominate high-response workloads such as NMR.

`%||%` <- function(left, right) {
    if (is.null(left) || !length(left)) right else left
}

parse_args <- function(values = commandArgs(trailingOnly = TRUE)) {
    result <- list()
    for (entry in values) {
        if (!startsWith(entry, "--")) next
        fields <- strsplit(substring(entry, 3L), "=", fixed = TRUE)[[1L]]
        result[[gsub("-", "_", fields[[1L]], fixed = TRUE)]] <-
            paste(fields[-1L], collapse = "=")
    }
    result
}

args <- parse_args()
required <- c("library", "task", "output", "backend")
missing <- required[!vapply(required, function(name) {
    is.character(args[[name]]) && nzchar(args[[name]])
}, logical(1L))]
if (length(missing)) stop("Missing --", paste(missing, collapse = ", --"))
value <- function(name, default) args[[name]] %||% default

.libPaths(unique(c(args$library, .libPaths())))
suppressPackageStartupMessages(library(fastPLS))
task <- readRDS(normalizePath(args$task, mustWork = TRUE))
X <- task$X %||% task$Xtrain
Y <- task$Y %||% task$Ytrain
if (is.null(X) || is.null(Y)) stop("Task does not contain X and Y data.")

classification <- is.factor(Y) || is.character(Y)
precision <- match.arg(value("precision", "float32"), c("float32", "float64"))
if (identical(precision, "float32")) {
    if (!inherits(X, "float32")) X <- float::fl(as.matrix(X))
    if (!classification && !inherits(Y, "float32")) {
        Y <- float::fl(as.matrix(Y))
    }
} else {
    if (inherits(X, "float32")) X <- float::dbl(X)
    if (!classification && inherits(Y, "float32")) Y <- float::dbl(Y)
}

backend <- match.arg(args$backend, c("cpu", "cuda", "metal"))
fastPLS:::.fastpls_require_backend_available(backend, "compact CV benchmark")
compiled_backend <- if (identical(backend, "cpu")) "cpp" else backend
ncomp <- as.integer(strsplit(value("ncomp", "10"), ",", fixed = TRUE)[[1L]])
constrain <- task$constrain %||% task$constrain_train %||% seq_len(nrow(X))
selection_metric <- value(
    "selection_metric", if (classification) "accuracy" else "rmsd"
)

gc(full = TRUE)
timing <- system.time(result <- fastPLS:::.pls_cv_compiled(
    Xdata = X,
    Ydata = Y,
    constrain = constrain,
    ncomp = ncomp,
    kfold = as.integer(value("kfold", "5")),
    scaling = value("scaling", "centering"),
    method = value("method", "simpls"),
    backend = compiled_backend,
    svd.method = "rsvd",
    seed = as.integer(value("seed", "123")),
    classifier = value("classifier", "argmax"),
    return_scores = FALSE,
    store_predictions = FALSE,
    selection_metric = selection_metric
))

row <- data.frame(
    package_version = as.character(packageVersion("fastPLS")),
    implementation = value("implementation", "current"),
    task = basename(args$task),
    backend = backend,
    precision = precision,
    n = nrow(X),
    p = ncol(X),
    q = if (classification) nlevels(factor(Y)) else ncol(Y),
    ncomp = paste(ncomp, collapse = ";"),
    metric_path = paste(signif(result$metrics$metric_value, 12L), collapse = ";"),
    elapsed_sec = unname(timing[["elapsed"]]),
    output_mib = as.numeric(object.size(result)) / 1024^2,
    prediction_retained = !is.null(result$Ypred),
    replicate = as.integer(value("replicate", "1")),
    stringsAsFactors = FALSE
)
write.table(
    row, args$output, sep = ",", row.names = FALSE,
    col.names = !file.exists(args$output), append = file.exists(args$output)
)
