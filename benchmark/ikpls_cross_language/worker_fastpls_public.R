#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 5L) {
  stop("Usage: worker_fastpls_public.R TASK_RDS LIBRARY BACKEND REPLICATE OUTPUT_CSV")
}

task_path <- args[[1L]]
library_path <- args[[2L]]
backend <- match.arg(args[[3L]], c("cpu", "cuda", "metal"))
replicate_id <- as.integer(args[[4L]])
output_csv <- args[[5L]]
.libPaths(unique(c(library_path, .libPaths())))

seed <- as.integer(Sys.getenv("FASTPLS_BENCH_SEED", "123"))
oversample <- as.integer(Sys.getenv("FASTPLS_BENCH_OVERSAMPLE", "32"))
power <- as.integer(Sys.getenv("FASTPLS_BENCH_POWER", "5"))
ncomp <- as.integer(Sys.getenv("FASTPLS_BENCH_NCOMP", "50"))
if (anyNA(c(seed, oversample, power, ncomp))) {
  stop("Benchmark controls must be integers")
}

task <- readRDS(task_path)
library(fastPLS)
gc(FALSE)

fit_start <- proc.time()[[3L]]
fit <- pls(
  task$Xtrain,
  task$Ytrain,
  ncomp = ncomp,
  scaling = "none",
  method = "simpls",
  svd.method = "rsvd",
  backend = backend,
  classifier = "argmax",
  fit = FALSE,
  return_variance = FALSE,
  return_loadings = FALSE,
  proj = FALSE,
  seed = seed,
  oversample = oversample,
  power = power
)
fit_sec <- unname(proc.time()[[3L]] - fit_start)

prediction_start <- proc.time()[[3L]]
prediction <- predict(fit, task$Xtest, backend = backend)$Ypred
if (is.list(prediction)) prediction <- prediction[[length(prediction)]]
prediction_sec <- unname(proc.time()[[3L]] - prediction_start)

predicted <- factor(prediction, levels = levels(task$Ytest))
utils::write.csv(data.frame(
  dataset = task$dataset,
  backend = backend,
  package_version = as.character(utils::packageVersion("fastPLS")),
  replicate = replicate_id,
  ncomp = ncomp,
  oversample = oversample,
  power = power,
  seed = seed,
  fit_sec = fit_sec,
  prediction_sec = prediction_sec,
  total_sec = fit_sec + prediction_sec,
  accuracy = mean(predicted == task$Ytest),
  prediction_checksum = sum(as.integer(predicted) * seq_along(predicted))
), output_csv, row.names = FALSE)
