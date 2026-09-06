#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 2L) {
  stop("Usage: audit_fastpls_seeds.R DATASET_DIR OUTPUT_CSV [SEED ...]")
}

bench_lib <- Sys.getenv("FASTPLS_BENCH_LIB", "")
if (nzchar(bench_lib)) .libPaths(unique(c(bench_lib, .libPaths())))

dataset_dir <- args[[1L]]
output_csv <- args[[2L]]
seeds <- if (length(args) > 2L) as.integer(args[-(1:2)]) else c(1L, 2L, 3L, 11L, 123L)
if (anyNA(seeds)) stop("Every seed must be an integer")

meta <- utils::read.delim(file.path(dataset_dir, "metadata.tsv"), stringsAsFactors = FALSE)
value <- function(key) meta$value[match(key, meta$key)]
n_train <- as.integer(value("n_train"))
n_test <- as.integer(value("n_test"))
p <- as.integer(value("p"))
q <- as.integer(value("q"))
ncomp <- as.integer(value("ncomp"))

read_matrix <- function(path, nrow, ncol) {
  con <- file(path, open = "rb")
  on.exit(close(con), add = TRUE)
  matrix(
    readBin(con, what = "double", n = nrow * ncol, size = 8L, endian = "little"),
    nrow = nrow,
    ncol = ncol,
    byrow = TRUE
  )
}

Xtrain <- read_matrix(file.path(dataset_dir, "Xtrain.f64"), n_train, p)
Xtest <- read_matrix(file.path(dataset_dir, "Xtest.f64"), n_test, p)
Ytrain <- read_matrix(file.path(dataset_dir, "Ytrain.f64"), n_train, q)
Ymean <- as.vector(read_matrix(file.path(dataset_dir, "Ymean.f64"), 1L, q))
ytest <- scan(file.path(dataset_dir, "ytest.txt"), quiet = TRUE)

library(fastPLS)
predictions <- vector("list", length(seeds))
rows <- vector("list", length(seeds))
for (i in seq_along(seeds)) {
  fit <- pls(
    Xtrain,
    Ytrain,
    ncomp = ncomp,
    scaling = "none",
    method = "simpls",
    svd.method = "rsvd",
    backend = "cpu",
    fit = FALSE,
    return_variance = FALSE,
    return_loadings = FALSE,
    proj = FALSE,
    seed = seeds[[i]],
    oversample = 32L,
    power = 5L
  )
  prediction <- predict(fit, Xtest, backend = "cpu")$Ypred
  if (length(dim(prediction)) == 3L) {
    prediction <- prediction[, , dim(prediction)[3L], drop = TRUE]
  }
  prediction <- sweep(as.matrix(prediction), 2L, Ymean, "+")
  predictions[[i]] <- max.col(prediction, ties.method = "first") - 1L
  rows[[i]] <- data.frame(
    dataset = value("dataset"),
    seed = seeds[[i]],
    accuracy = mean(predictions[[i]] == ytest),
    agreement_with_first = mean(predictions[[i]] == predictions[[1L]])
  )
}

out <- do.call(rbind, rows)
out$minimum_pairwise_agreement <- min(vapply(
  seq_along(predictions),
  function(i) min(vapply(
    seq_along(predictions),
    function(j) mean(predictions[[i]] == predictions[[j]]),
    numeric(1)
  )),
  numeric(1)
))
utils::write.csv(out, output_csv, row.names = FALSE)
