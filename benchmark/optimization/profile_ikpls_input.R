#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 2L) {
    stop("Usage: profile_ikpls_input.R DATASET_DIR OUTPUT_CSV", call. = FALSE)
}

benchmark_lib <- Sys.getenv("FASTPLS_BENCH_LIB", "")
if (nzchar(benchmark_lib)) {
    .libPaths(unique(c(benchmark_lib, .libPaths())))
}

dataset_dir <- normalizePath(args[[1L]], mustWork = TRUE)
output_csv <- args[[2L]]
metadata <- utils::read.delim(
    file.path(dataset_dir, "metadata.tsv"),
    stringsAsFactors = FALSE
)
value <- function(key) metadata$value[match(key, metadata$key)]
n_train <- as.integer(value("n_train"))
n_test <- as.integer(value("n_test"))
p <- as.integer(value("p"))
q <- as.integer(value("q"))
ncomp <- as.integer(value("ncomp"))

read_matrix <- function(path, rows, columns) {
    connection <- file(path, open = "rb")
    on.exit(close(connection), add = TRUE)
    matrix(
        readBin(
            connection,
            what = "double",
            n = rows * columns,
            size = 8L,
            endian = "little"
        ),
        nrow = rows,
        ncol = columns,
        byrow = TRUE
    )
}

Xtrain <- read_matrix(file.path(dataset_dir, "Xtrain.f64"), n_train, p)
Xtest <- read_matrix(file.path(dataset_dir, "Xtest.f64"), n_test, p)
Ytrain <- read_matrix(file.path(dataset_dir, "Ytrain.f64"), n_train, q)

suppressPackageStartupMessages(library(fastPLS))
Sys.setenv(FASTPLS_BENCH_PHASE_TIMING = "1")
on.exit(Sys.unsetenv("FASTPLS_BENCH_PHASE_TIMING"), add = TRUE)

fit_elapsed <- system.time({
    model <- pls(
        Xtrain,
        Ytrain,
        ncomp = ncomp,
        scaling = "none",
        method = "simpls",
        backend = "cpu",
        svd.method = "rsvd",
        fit = FALSE,
        return_variance = FALSE,
        return_loadings = FALSE,
        proj = FALSE,
        seed = 123L,
        oversample = 32L,
        power = 5L
    )
})[["elapsed"]]
internal <- attr(model, "fastPLS_internal", exact = TRUE)
phases <- internal$benchmark_phase_timing
if (is.null(phases)) {
    stop("The package did not return benchmark phase timing.", call. = FALSE)
}
prediction_elapsed <- system.time({
    prediction <- predict(model, Xtest, backend = "cpu")
})[["elapsed"]]

result <- as.data.frame(as.list(phases), check.names = FALSE)
result$fit_elapsed_sec <- unname(fit_elapsed)
result$prediction_elapsed_sec <- unname(prediction_elapsed)
result$total_elapsed_sec <- unname(fit_elapsed + prediction_elapsed)
result$dataset <- value("dataset")
result$n_train <- n_train
result$n_test <- n_test
result$p <- p
result$q <- q
result$ncomp <- ncomp
result$package_version <- as.character(packageVersion("fastPLS"))
result$blas_threads <- as.integer(Sys.getenv("OPENBLAS_NUM_THREADS", "1"))
dir.create(dirname(output_csv), recursive = TRUE, showWarnings = FALSE)
write.csv(result, output_csv, row.names = FALSE)
