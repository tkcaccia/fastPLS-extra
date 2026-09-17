#!/usr/bin/env Rscript

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
task_path <- normalizePath(args$task, mustWork = TRUE)
task <- readRDS(task_path)
Xsource <- task$X %||% task$Xtrain
Y <- task$Y %||% task$Ytrain
if (is.null(Xsource) || is.null(Y)) stop("Task does not contain X/Y data.")

classification <- is.factor(Y) || is.character(Y)
if (classification) Y <- factor(Y)
precision <- match.arg(value("precision", "float32"), c("float32", "float64"))
backend <- match.arg(args$backend, c("cpu", "metal"))
if (backend == "metal" && precision != "float32") {
    stop("Metal CV supports float32 only; no fallback is permitted.")
}
fastPLS:::.fastpls_require_backend_available(backend, "Fold-local CV audit")

if (precision == "float32") {
    X <- if (inherits(Xsource, "float32")) Xsource else {
        float::fl(as.matrix(Xsource))
    }
    if (!classification) {
        Y <- if (inherits(Y, "float32")) Y else float::fl(as.matrix(Y))
    }
} else {
    X <- if (inherits(Xsource, "float32")) float::dbl(Xsource) else {
        as.matrix(Xsource)
    }
    if (!classification) {
        Y <- if (inherits(Y, "float32")) float::dbl(Y) else as.matrix(Y)
    }
}

constrain <- task$constrain %||% task$constrain_train %||% seq_len(nrow(X))
if (length(constrain) != nrow(X)) stop("Invalid constraint-vector length.")
ncomp <- as.integer(strsplit(value("ncomp", "10"), ",", fixed = TRUE)[[1L]])
kfold <- as.integer(value("kfold", "10"))
seed <- as.integer(value("seed", "123"))
method <- match.arg(value("method", "simpls"),
    c("plssvd", "simpls", "opls", "kernelpls"))
classifier <- match.arg(value("classifier", "argmax"), c("argmax", "lda"))
selection_metric <- value(
    "selection_metric", if (classification) "accuracy" else "rmsd"
)

fingerprint <- function(object) {
    path <- tempfile(fileext = ".rds")
    on.exit(unlink(path), add = TRUE)
    saveRDS(object, path, version = 3L)
    unname(tools::md5sum(path))
}

result <- NULL
timing <- system.time({
    result <- fastPLS:::.pls_cv_via_pls(
        Xdata = X,
        Ydata = Y,
        constrain = constrain,
        ncomp = ncomp,
        kfold = kfold,
        scaling = "centering",
        method = method,
        backend = backend,
        svd.method = "rsvd",
        seed = seed,
        classifier = classifier,
        store_predictions = TRUE,
        selection_metric = selection_metric
    )
})

metric <- as.numeric(result$metrics$metric_value)
best_index <- if (classification || identical(tolower(selection_metric), "q2")) {
    which.max(metric)
} else {
    which.min(metric)
}
row <- data.frame(
    package_version = as.character(packageVersion("fastPLS")),
    implementation = "fold_local_public_semantics",
    task = basename(task_path),
    backend = backend,
    precision = precision,
    method = method,
    classifier = if (classification) classifier else NA_character_,
    n = nrow(X),
    p = ncol(X),
    q = if (classification) nlevels(Y) else ncol(Y),
    folds = length(unique(result$fold)),
    ncomp = paste(ncomp, collapse = ";"),
    best_ncomp = ncomp[[best_index]],
    best_metric = metric[[best_index]],
    metric_path = paste(signif(metric, 12L), collapse = ";"),
    elapsed_sec = unname(timing[["elapsed"]]),
    user_sec = unname(timing[["user.self"]]),
    system_sec = unname(timing[["sys.self"]]),
    output_mib = as.numeric(object.size(result)) / 1024^2,
    fold_signature = fingerprint(result$fold),
    prediction_signature = fingerprint(result$Ypred),
    status = "ok",
    stringsAsFactors = FALSE
)
write.table(
    row, args$output, sep = ",", row.names = FALSE,
    col.names = !file.exists(args$output), append = file.exists(args$output)
)
