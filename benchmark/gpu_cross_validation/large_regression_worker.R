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
X <- task$X %||% task$Xtrain
Y <- task$Y %||% task$Ytrain
if (is.null(X) || is.null(Y)) stop("Task does not contain X/Y training data.")
if (is.factor(Y) || is.character(Y)) {
    stop("large_regression_worker.R requires a regression response.")
}

precision <- match.arg(value("precision", "float32"), c("float32", "float64"))
backend <- match.arg(args$backend, c("cpu", "cuda", "metal"))
if (identical(precision, "float32")) {
    if (!inherits(X, "float32")) X <- float::fl(as.matrix(X))
    if (!inherits(Y, "float32")) Y <- float::fl(as.matrix(Y))
} else {
    if (inherits(X, "float32")) X <- float::dbl(X) else X <- as.matrix(X)
    if (inherits(Y, "float32")) Y <- float::dbl(Y) else Y <- as.matrix(Y)
}

constrain <- task$constrain %||% task$constrain_train %||% seq_len(nrow(X))
if (length(constrain) != nrow(X)) {
    stop("constrain must contain one value per training row.")
}
ncomp <- as.integer(strsplit(value("ncomp", "50"), ",", fixed = TRUE)[[1L]])
kfold <- as.integer(value("kfold", "10"))
seed <- as.integer(value("seed", "123"))
method <- match.arg(
    value("method", "simpls"),
    c("plssvd", "simpls", "opls", "kernelpls")
)
kernel <- match.arg(value("kernel", "linear"), c("linear", "rbf", "poly"))
north <- as.integer(value("north", "1"))

gc(full = TRUE)
timing <- system.time({
    result <- pls.single.cv(
        X,
        Y,
        constrain = constrain,
        ncomp = ncomp,
        kfold = kfold,
        method = method,
        backend = backend,
        kernel = kernel,
        north = north,
        fit = FALSE,
        seed = seed,
        selection_metric = "rmsd"
    )
})

prediction <- result$Ypred
sample_index <- unique(round(seq(
    1L,
    length(prediction),
    length.out = min(4096L, length(prediction))
)))
row <- data.frame(
    package_version = as.character(packageVersion("fastPLS")),
    task = basename(task_path),
    backend = backend,
    precision = precision,
    method = method,
    kernel = if (identical(method, "kernelpls")) kernel else NA_character_,
    north = if (identical(method, "opls")) north else NA_integer_,
    n = nrow(X),
    p = ncol(X),
    q = ncol(Y),
    folds = kfold,
    requested_ncomp = paste(ncomp, collapse = ";"),
    best_ncomp = result$best_ncomp,
    elapsed_sec = unname(timing[["elapsed"]]),
    user_sec = unname(timing[["user.self"]]),
    system_sec = unname(timing[["sys.self"]]),
    RMSD = result$RMSD[[result$best_index]],
    Q2Y = result$Q2Y[[result$best_index]],
    prediction_rows = dim(prediction)[[1L]],
    prediction_columns = dim(prediction)[[2L]],
    prediction_components = dim(prediction)[[3L]],
    sampled_prediction_sum = sum(as.numeric(prediction[sample_index])),
    groups_preserved = all(vapply(
        split(result$fold, constrain),
        function(x) length(unique(x)) == 1L,
        logical(1L)
    )),
    status = "ok",
    stringsAsFactors = FALSE
)
write.csv(row, args$output, row.names = FALSE)
print(row)
