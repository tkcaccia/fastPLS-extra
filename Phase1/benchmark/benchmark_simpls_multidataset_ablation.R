#!/usr/bin/env Rscript

# One isolated SIMPLS optimization-ablation run. The shell driver samples RSS
# only after data loading and before fitting begins.

options(stringsAsFactors = FALSE)

parse_args <- function(x = commandArgs(trailingOnly = TRUE)) {
  out <- list()
  for (item in x) {
    if (!startsWith(item, "--")) next
    kv <- strsplit(substring(item, 3L), "=", fixed = TRUE)[[1L]]
    out[[gsub("-", "_", kv[[1L]])]] <-
      if (length(kv) > 1L) paste(kv[-1L], collapse = "=") else "TRUE"
  }
  out
}

args <- parse_args()
arg <- function(name, default = NULL) {
  value <- args[[name]]
  if (is.null(value) || !nzchar(value)) default else value
}

task_path <- normalizePath(arg("task"), mustWork = TRUE)
output <- arg("output", "ablation_row.csv")
prediction_output <- arg("prediction_output", "")
dataset <- arg("dataset", sub("_task\\.rds$", "", basename(task_path)))
configuration <- arg("configuration", "full_explicit")
ncomp <- as.integer(arg("ncomp", "10"))
replicate_id <- as.integer(arg("replicate", "1"))
seed <- as.integer(arg("seed", "123"))
ready_file <- arg("ready_file", "")
go_file <- arg("go_file", "")

configs <- list(
  xtx_off = list(pair = "cached_XtX", optimized = "0", incremental = "1",
                 deflcache = "1", store_B = "always", xprod = FALSE),
  xtx_on = list(pair = "cached_XtX", optimized = "1", incremental = "1",
                deflcache = "1", store_B = "always", xprod = FALSE),
  coefficients_recomputed = list(
    pair = "incremental_coefficients", optimized = "1", incremental = "0",
    deflcache = "1", store_B = "always", xprod = FALSE
  ),
  coefficients_incremental = list(
    pair = "incremental_coefficients", optimized = "1", incremental = "1",
    deflcache = "1", store_B = "always", xprod = FALSE
  ),
  deflation_inline = list(
    pair = "cached_deflation_products", optimized = "1", incremental = "1",
    deflcache = "0", store_B = "always", xprod = FALSE
  ),
  deflation_cached = list(
    pair = "cached_deflation_products", optimized = "1", incremental = "1",
    deflcache = "1", store_B = "always", xprod = FALSE
  ),
  coefficient_cube = list(
    pair = "compact_prediction", optimized = "1", incremental = "1",
    deflcache = "1", store_B = "always", xprod = FALSE
  ),
  compact_prediction = list(
    pair = "compact_prediction", optimized = "1", incremental = "1",
    deflcache = "1", store_B = "never", xprod = FALSE
  ),
  explicit_crosscov = list(
    pair = "matrix_free", optimized = "1", incremental = "1",
    deflcache = "1", store_B = "never", xprod = FALSE
  ),
  matrix_free = list(
    pair = "matrix_free", optimized = "1", incremental = "1",
    deflcache = "1", store_B = "never", xprod = TRUE
  )
)
cfg <- configs[[configuration]]
if (is.null(cfg)) stop("Unknown configuration: ", configuration)

lib <- Sys.getenv("FASTPLS_ABLATION_LIB", "")
if (nzchar(lib)) .libPaths(unique(c(lib, .libPaths())))
suppressPackageStartupMessages(library(fastPLS))

task <- readRDS(task_path)
Xtrain <- as.matrix(task$Xtrain)
Xtest <- as.matrix(task$Xtest)
classification <- identical(task$task_type, "classification") ||
  is.factor(task$Ytrain)
if (classification) {
  Ytrain <- droplevels(factor(task$Ytrain))
  Ytest <- factor(task$Ytest, levels = levels(Ytrain))
} else {
  Ytrain <- as.matrix(task$Ytrain)
  Ytest <- as.matrix(task$Ytest)
}

Sys.setenv(
  FASTPLS_ABLATION_MODE = "1",
  FASTPLS_FAST_CENTER_T = "0",
  FASTPLS_FAST_REORTH_V = "0",
  FASTPLS_FAST_OPTIMIZED = cfg$optimized,
  FASTPLS_INCREMENTAL_COEFFICIENTS = cfg$incremental,
  FASTPLS_FAST_DEFLCACHE = cfg$deflcache,
  FASTPLS_STORE_B = cfg$store_B,
  FASTPLS_RETURN_TTRAIN = "0",
  FASTPLS_ABLATION_XPROD = if (isTRUE(cfg$xprod)) "1" else "0"
)

rss_mb <- function() {
  if (file.exists("/proc/self/status")) {
    line <- grep("^VmRSS:", readLines("/proc/self/status", warn = FALSE), value = TRUE)
    if (length(line)) {
      return(as.numeric(sub("^VmRSS:\\s*([0-9.]+).*", "\\1", line[[1L]])) / 1024)
    }
  }
  if (requireNamespace("ps", quietly = TRUE)) {
    info <- tryCatch(ps::ps_memory_info(ps::ps_handle()), error = function(e) NULL)
    if (!is.null(info) && is.finite(info[["rss"]])) return(info[["rss"]] / 1024^2)
  }
  NA_real_
}

extract_prediction <- function(fit, n_test, q) {
  pred <- fit$Ypred
  if (classification) {
    if (is.list(pred)) pred <- pred[[length(pred)]]
    return(factor(as.character(pred), levels = levels(Ytrain)))
  }
  if (is.list(pred)) pred <- pred[[length(pred)]]
  dims <- dim(pred)
  if (length(dims) == 3L) pred <- pred[, , dims[[3L]], drop = TRUE]
  matrix(as.numeric(pred), nrow = n_test, ncol = q)
}

gc()
baseline_rss <- rss_mb()
if (nzchar(ready_file)) {
  dir.create(dirname(ready_file), recursive = TRUE, showWarnings = FALSE)
  writeLines(sprintf("%.6f", baseline_rss), ready_file)
  if (nzchar(go_file)) {
    deadline <- Sys.time() + 120
    while (!file.exists(go_file) && Sys.time() < deadline) Sys.sleep(0.02)
    if (!file.exists(go_file)) stop("Timed out waiting for RSS monitor")
  }
}

set.seed(seed)
component_path <- seq_len(ncomp)
status <- "success"
error <- ""
fit_time <- predict_time <- NA_real_
metric_name <- if (classification) "accuracy" else "rmsd"
metric_value <- NA_real_
prediction <- NULL

tryCatch({
  fit_time <- unname(system.time({
    model <- pls(
      Xtrain, Ytrain,
      ncomp = component_path,
      method = "simpls",
      backend = "cpu",
      svd.method = "irlba",
      scaling = "centering",
      classifier = "argmax",
      fit = FALSE,
      proj = FALSE,
      return_variance = FALSE,
      seed = seed
    )
  })[["elapsed"]])
  predict_time <- unname(system.time({
    prediction_fit <- predict(model, Xtest, Ytest, backend = "cpu")
    prediction <- extract_prediction(
      prediction_fit,
      nrow(Xtest),
      if (classification) nlevels(Ytrain) else ncol(Ytrain)
    )
  })[["elapsed"]])
  if (classification) {
    metric_value <- mean(as.character(prediction) == as.character(Ytest), na.rm = TRUE)
  } else {
    metric_value <- sqrt(mean((prediction - Ytest)^2, na.rm = TRUE))
  }
}, error = function(e) {
  status <<- "failed"
  error <<- conditionMessage(e)
})

if (identical(status, "success") && nzchar(prediction_output)) {
  dir.create(dirname(prediction_output), recursive = TRUE, showWarnings = FALSE)
  saveRDS(prediction, prediction_output, compress = FALSE)
}

row <- data.frame(
  dataset = dataset,
  task_type = if (classification) "classification" else "regression",
  n_train = nrow(Xtrain),
  n_test = nrow(Xtest),
  p = ncol(Xtrain),
  q = if (classification) nlevels(Ytrain) else ncol(Ytrain),
  ncomp = ncomp,
  method = "simpls",
  backend = "cpu",
  svd_method = "irlba",
  pair = cfg$pair,
  configuration = configuration,
  optimized_value = configuration %in% c(
    "xtx_on", "coefficients_incremental", "deflation_cached",
    "compact_prediction", "matrix_free"
  ),
  optimization_applicable = if (identical(cfg$pair, "cached_XtX")) {
    ncomp >= 20L && ncol(Xtrain) <= nrow(Xtrain) &&
      nrow(Xtrain) >= 8L * ncol(Xtrain) && ncol(Xtrain) <= 512L
  } else {
    TRUE
  },
  xprod = cfg$xprod,
  replicate = replicate_id,
  fit_time_sec = fit_time,
  predict_time_sec = predict_time,
  total_time_sec = fit_time + predict_time,
  metric_name = metric_name,
  metric_value = metric_value,
  rss_before_fit_mb = baseline_rss,
  status = status,
  error = error,
  stringsAsFactors = FALSE
)
dir.create(dirname(output), recursive = TRUE, showWarnings = FALSE)
write.csv(row, output, row.names = FALSE)
print(row)
