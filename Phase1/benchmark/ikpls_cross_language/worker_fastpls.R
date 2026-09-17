#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 4L) stop("Usage: worker_fastpls.R DATASET_DIR METHOD REPLICATE OUTPUT_CSV")
bench_lib <- Sys.getenv("FASTPLS_BENCH_LIB", "")
if (nzchar(bench_lib)) .libPaths(unique(c(bench_lib, .libPaths())))
dataset_dir <- args[[1L]]
solver <- match.arg(args[[2L]], c("irlba", "rsvd"))
replicate_id <- as.integer(args[[3L]])
output_csv <- args[[4L]]
backend <- Sys.getenv("FASTPLS_BENCH_BACKEND", "cpu")
benchmark_seed <- as.integer(Sys.getenv("FASTPLS_BENCH_SEED", "123"))
if (length(benchmark_seed) != 1L || is.na(benchmark_seed)) {
  stop("FASTPLS_BENCH_SEED must be one integer")
}

meta <- utils::read.delim(file.path(dataset_dir, "metadata.tsv"), stringsAsFactors = FALSE)
value <- function(key) meta$value[match(key, meta$key)]
n_train <- as.integer(value("n_train")); n_test <- as.integer(value("n_test"))
p <- as.integer(value("p")); q <- as.integer(value("q")); ncomp <- as.integer(value("ncomp"))

read_matrix <- function(path, nrow, ncol) {
  con <- file(path, open = "rb")
  on.exit(close(con), add = TRUE)
  matrix(readBin(con, what = "double", n = nrow * ncol, size = 8L, endian = "little"),
         nrow = nrow, ncol = ncol, byrow = TRUE)
}

Xtrain <- read_matrix(file.path(dataset_dir, "Xtrain.f64"), n_train, p)
Xtest <- read_matrix(file.path(dataset_dir, "Xtest.f64"), n_test, p)
Ytrain <- read_matrix(file.path(dataset_dir, "Ytrain.f64"), n_train, q)
Ymean <- as.vector(read_matrix(file.path(dataset_dir, "Ymean.f64"), 1L, q))
ytest <- scan(file.path(dataset_dir, "ytest.txt"), quiet = TRUE)

current_rss_mb <- function() {
  value <- suppressWarnings(as.numeric(system2(
    "ps", c("-o", "rss=", "-p", as.character(Sys.getpid())), stdout = TRUE, stderr = FALSE
  )))
  if (length(value) && is.finite(value[[1L]])) value[[1L]] / 1024 else NA_real_
}

library(fastPLS)
gc(FALSE)
prefit_rss_mb <- current_rss_mb()
fit_start <- proc.time()[[3L]]
fit <- pls(
  Xtrain, Ytrain,
  ncomp = ncomp,
  scaling = "none",
  method = "simpls",
  svd.method = solver,
  backend = backend,
  fit = FALSE,
  return_variance = FALSE,
  return_loadings = FALSE,
  proj = FALSE,
  seed = benchmark_seed,
  oversample = 32L,
  power = if (identical(solver, "rsvd")) 5L else 1L
)
fit_sec <- unname(proc.time()[[3L]] - fit_start)

pred_start <- proc.time()[[3L]]
prediction <- predict(fit, Xtest, backend = backend)$Ypred
if (length(dim(prediction)) == 3L) prediction <- prediction[, , dim(prediction)[3L], drop = TRUE]
prediction <- sweep(as.matrix(prediction), 2L, Ymean, "+")
predicted <- max.col(prediction, ties.method = "first") - 1L
prediction_sec <- unname(proc.time()[[3L]] - pred_start)

row <- data.frame(
  dataset = value("dataset"), implementation = paste0("fastPLS_", backend, "_", solver),
  package_version = as.character(utils::packageVersion("fastPLS")), algorithm = "SIMPLS",
  source_archive_sha256 = Sys.getenv("FASTPLS_SOURCE_ARCHIVE_SHA256", NA_character_),
  solver = toupper(solver), precision = "float64", replicate = replicate_id,
  n_train = n_train, n_test = n_test, p = p, q = q, ncomp = ncomp,
  rsvd_oversample = if (identical(solver, "rsvd")) 32L else NA_integer_,
  rsvd_power = if (identical(solver, "rsvd")) 5L else NA_integer_,
  seed = benchmark_seed,
  fit_sec = fit_sec, prediction_sec = prediction_sec, total_sec = fit_sec + prediction_sec,
  accuracy = mean(predicted == ytest), prediction_checksum = sum(predicted * seq_along(predicted)),
  prefit_rss_mb = prefit_rss_mb,
  retained_output = "final predictions requested; compact fastPLS model retained",
  numerical_status = if (identical(solver, "rsvd")) {
    sprintf(
      "approximate; evaluated controls oversample=32, power=5, seed=%d",
      benchmark_seed
    )
  } else {
    "fixed-control iterative comparator"
  },
  stringsAsFactors = FALSE
)
utils::write.csv(row, output_csv, row.names = FALSE)
