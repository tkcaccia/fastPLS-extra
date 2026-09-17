#!/usr/bin/env Rscript

# Compare explicit fresh-start rSVD controls with one fixed NMR IRLBA fit.

options(stringsAsFactors = FALSE)

parse_args <- function(values = commandArgs(trailingOnly = TRUE)) {
  output <- list()
  for (value in values) {
    if (!startsWith(value, "--")) next
    fields <- strsplit(substring(value, 3L), "=", fixed = TRUE)[[1L]]
    output[[gsub("-", "_", fields[[1L]])]] <-
      if (length(fields) > 1L) paste(fields[-1L], collapse = "=") else "TRUE"
  }
  output
}

args <- parse_args()
arg <- function(name, default = NULL) args[[name]] %||% default
`%||%` <- function(x, y) if (is.null(x) || !length(x) || !nzchar(x)) y else x

input <- normalizePath(arg("input"), mustWork = TRUE)
reference_path <- normalizePath(arg("reference"), mustWork = TRUE)
output <- arg("output", "nmr_rsvd_control_sweep.csv")
backend <- match.arg(arg("backend", "cpu"), c("cpu", "cuda", "metal"))
family <- match.arg(arg("family", "simpls"), c("simpls", "plssvd"))
ncomp <- as.integer(arg("ncomp", "50"))
controls <- strsplit(arg("controls", "10:1,16:2,20:2,24:3,32:5"), ",",
                     fixed = TRUE)[[1L]]
seeds <- as.integer(strsplit(arg("seeds", "11,29,47"), ",", fixed = TRUE)[[1L]])

script_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
script_path <- normalizePath(sub("^--file=", "", script_arg[[1L]]),
                             mustWork = TRUE)
source(file.path(dirname(script_path), "nmr_protocol_helpers.R"))

fastpls_lib <- Sys.getenv("FASTPLS_LIB", unset = "")
if (nzchar(fastpls_lib)) .libPaths(unique(c(fastpls_lib, .libPaths())))
suppressPackageStartupMessages(library(fastPLS))
if (backend == "cuda" && !isTRUE(has_cuda())) stop("CUDA is unavailable.")
if (backend == "metal" && !isTRUE(has_metal())) stop("Metal is unavailable.")

protocol <- fastpls_nmr_protocol(input)
reference <- readRDS(reference_path)
stopifnot(identical(dim(reference$predicted), dim(reference$observed)))
stopifnot(identical(dim(reference$observed), dim(protocol$Ytest)))

extract_prediction <- function(value, component) {
  prediction <- value$Ypred
  key <- paste0("ncomp=", component)
  if (is.list(prediction) && !is.data.frame(prediction)) {
    return(as.matrix(prediction[[key]] %||% prediction[[length(prediction)]]))
  }
  if (length(dim(prediction)) == 3L) {
    index <- match(key, dimnames(prediction)[[3L]])
    if (is.na(index)) index <- dim(prediction)[[3L]]
    return(matrix(prediction[, , index], nrow = dim(prediction)[1L]))
  }
  as.matrix(prediction)
}

metric_values <- function(predicted) {
  error <- predicted - protocol$Ytest
  centered <- sweep(protocol$Ytest, 2L, colMeans(protocol$Ytrain), "-")
  sse <- sum(error^2)
  c(
    RMSD = sqrt(mean(error^2)),
    Q2 = 1 - sse / sum(centered^2),
    MAE = mean(abs(error))
  )
}

reference_norm <- sqrt(sum(reference$predicted^2))
rows <- list()
index <- 0L
for (control in controls) {
  values <- as.integer(strsplit(control, ":", fixed = TRUE)[[1L]])
  if (length(values) != 2L || anyNA(values)) {
    stop("Each control must use oversample:power format.")
  }
  for (seed in seeds) {
    index <- index + 1L
    gc(full = TRUE)
    set.seed(seed)
    fit_seconds <- unname(system.time({
      model <- pls(
        protocol$Xtrain,
        protocol$Ytrain,
        ncomp = ncomp,
        method = family,
        backend = backend,
        svd.method = "rsvd",
        scaling = "centering",
        oversample = values[[1L]],
        power = values[[2L]],
        seed = seed,
        fit = FALSE,
        return_variance = FALSE
      )
    })[["elapsed"]])
    prediction_seconds <- unname(system.time({
      prediction <- extract_prediction(
        predict(model, protocol$Xtest, backend = backend),
        ncomp
      )
    })[["elapsed"]])
    metrics <- metric_values(prediction)
    relative_error <- sqrt(sum((prediction - reference$predicted)^2)) /
      max(reference_norm, .Machine$double.eps)
    correlation <- suppressWarnings(cor(
      as.vector(prediction),
      as.vector(reference$predicted)
    ))
    rows[[index]] <- data.frame(
      package_version = as.character(packageVersion("fastPLS")),
      family = family,
      backend = backend,
      ncomp = ncomp,
      oversample = values[[1L]],
      power = values[[2L]],
      seed = seed,
      fit_sec = fit_seconds,
      prediction_sec = prediction_seconds,
      total_sec = fit_seconds + prediction_seconds,
      RMSD = unname(metrics[["RMSD"]]),
      Q2 = unname(metrics[["Q2"]]),
      MAE = unname(metrics[["MAE"]]),
      prediction_relative_error = relative_error,
      prediction_correlation = correlation,
      within_prediction_tolerance =
        relative_error <= 0.01 && correlation >= 0.995,
      direction_rule = model$diagnostics$simpls_direction$rule %||%
        NA_character_,
      status = "success",
      stringsAsFactors = FALSE
    )
    rm(model, prediction)
  }
}

result <- do.call(rbind, rows)
dir.create(dirname(output), recursive = TRUE, showWarnings = FALSE)
write.csv(result, output, row.names = FALSE)
print(result)
