#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 3L) {
  stop("Usage: export_large_float32.R <nmr|imagenet> <input> <output_dir>")
}

dataset <- args[[1L]]
input <- normalizePath(args[[2L]], mustWork = TRUE)
out <- args[[3L]]
dir.create(out, recursive = TRUE, showWarnings = FALSE)
script_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
script_path <- normalizePath(
  sub("^--file=", "", script_arg[[1L]]), mustWork = TRUE
)

write_f32 <- function(x, path) {
  con <- file(path, "wb")
  on.exit(close(con), add = TRUE)
  writeBin(as.numeric(x), con, size = 4L, endian = "little")
}

write_float_bits <- function(x, path) {
  if (!inherits(x, "float32")) stop("Expected a float32 matrix")
  con <- file(path, "wb")
  on.exit(close(con), add = TRUE)
  # float stores IEEE-754 payloads in an integer matrix. Writing those integers
  # preserves the bits without a float64 conversion.
  block_cols <- 16L
  for (lo in seq.int(1L, ncol(x), by = block_cols)) {
    hi <- min(ncol(x), lo + block_cols - 1L)
    writeBin(
      as.integer(x@Data[, lo:hi, drop = FALSE]),
      con,
      size = 4L,
      endian = "little"
    )
  }
}

if (dataset == "nmr") {
  source(file.path(dirname(dirname(script_path)), "nmr_protocol_helpers.R"))
  protocol <- fastpls_nmr_protocol(input)
  Xtrain <- protocol$Xtrain
  Xtest <- protocol$Xtest
  Ytrain <- protocol$Ytrain
  Ytest <- protocol$Ytest
  xmean <- colMeans(Xtrain)
  ymean <- colMeans(Ytrain)
  write_f32(sweep(Xtrain, 2L, xmean, "-"), file.path(out, "Xtrain_centered.f32"))
  write_f32(sweep(Xtest, 2L, xmean, "-"), file.path(out, "Xtest_centered.f32"))
  write_f32(sweep(Ytrain, 2L, ymean, "-"), file.path(out, "Ytrain_centered.f32"))
  write_f32(Ytest, file.path(out, "Ytest.f32"))
  write_f32(ymean, file.path(out, "Ymean.f32"))
  meta <- data.frame(
    key = c("dataset", "n_train", "n_test", "p", "q", "precision", "water_predictors_zeroed"),
    value = c(
      "nmr", nrow(Xtrain), nrow(Xtest), ncol(Xtrain), ncol(Ytrain),
      "float32", protocol$metadata$water_columns_masked
    )
  )
} else if (dataset == "imagenet") {
  if (!requireNamespace("float", quietly = TRUE)) stop("float is required")
  task <- readRDS(input)
  Xtrain <- readRDS(task$Xtrain_rds)
  write_float_bits(Xtrain, file.path(out, "Xtrain_raw.f32"))
  rm(Xtrain)
  gc(FALSE)
  Xtest <- readRDS(task$Xtest_rds)
  write_float_bits(Xtest, file.path(out, "Xtest_raw.f32"))
  labels_train <- as.integer(factor(task$Ytrain, levels = task$levels)) - 1L
  labels_test <- as.integer(factor(task$Ytest, levels = task$levels)) - 1L
  writeBin(labels_train, file.path(out, "ytrain.i32"), size = 4L, endian = "little")
  writeBin(labels_test, file.path(out, "ytest.i32"), size = 4L, endian = "little")
  meta <- data.frame(
    key = c("dataset", "n_train", "n_test", "p", "q", "precision", "split_seed"),
    value = c("imagenet", task$n_train, task$n_test, task$p, task$n_classes, "float32", task$seed)
  )
} else {
  stop("Unknown dataset: ", dataset)
}

write.table(meta, file.path(out, "metadata.tsv"), sep = "\t", row.names = FALSE, quote = FALSE)
