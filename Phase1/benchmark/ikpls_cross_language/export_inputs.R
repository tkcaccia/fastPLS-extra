#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
out_dir <- if (length(args)) args[[1L]] else {
  results_root <- Sys.getenv("FASTPLS_RESULTS_ROOT")
  if (!nzchar(results_root)) stop("Supply an output directory or set FASTPLS_RESULTS_ROOT.")
  file.path(results_root, "ikpls_cross_language", "inputs")
}
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

write_matrix <- function(x, path) {
  x <- as.matrix(x)
  con <- file(path, open = "wb")
  on.exit(close(con), add = TRUE)
  writeBin(as.double(t(x)), con, size = 8L, endian = "little")
}

write_dataset <- function(id, Xtrain, ytrain, Xtest, ytest, ncomp) {
  Xtrain <- as.matrix(Xtrain)
  Xtest <- as.matrix(Xtest)
  ytrain <- droplevels(as.factor(ytrain))
  ytest <- factor(ytest, levels = levels(ytrain))
  if (anyNA(ytest)) {
    stop(
      "Held-out labels contain classes absent from training for ", id,
      "; no samples were removed.",
      call. = FALSE
    )
  }

  x_mean <- colMeans(Xtrain)
  Xtrain <- sweep(Xtrain, 2L, x_mean, "-")
  Xtest <- sweep(Xtest, 2L, x_mean, "-")
  Ytrain <- stats::model.matrix(~ ytrain - 1L)
  colnames(Ytrain) <- levels(ytrain)
  y_mean <- colMeans(Ytrain)
  Ytrain <- sweep(Ytrain, 2L, y_mean, "-")

  target <- file.path(out_dir, id)
  dir.create(target, recursive = TRUE, showWarnings = FALSE)
  write_matrix(Xtrain, file.path(target, "Xtrain.f64"))
  write_matrix(Xtest, file.path(target, "Xtest.f64"))
  write_matrix(Ytrain, file.path(target, "Ytrain.f64"))
  write_matrix(matrix(y_mean, nrow = 1L), file.path(target, "Ymean.f64"))
  writeLines(as.character(as.integer(ytest) - 1L), file.path(target, "ytest.txt"))
  writeLines(levels(ytrain), file.path(target, "class_levels.txt"))
  meta <- data.frame(
    key = c("dataset", "n_train", "n_test", "p", "q", "ncomp", "precision", "preprocessing"),
    value = c(id, nrow(Xtrain), nrow(Xtest), ncol(Xtrain), ncol(Ytrain), ncomp,
              "float64", "training-column centering applied once before both implementations")
  )
  utils::write.table(meta, file.path(target, "metadata.tsv"), sep = "\t", row.names = FALSE, quote = FALSE)
}

repo_root <- normalizePath(file.path(dirname(sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[1L])), "..", ".."))

breast_env <- new.env(parent = emptyenv())
breast_path <- Sys.getenv("FASTPLS_BREAST_RDA", file.path(repo_root, "data", "breast.rda"))
if (file.exists(breast_path)) {
  load(breast_path, envir = breast_env)
} else {
  utils::data("breast", package = "fastPLS", envir = breast_env)
}
if (!exists("breast", envir = breast_env, inherits = FALSE)) {
  stop("The packaged breast dataset could not be loaded.", call. = FALSE)
}
write_dataset(
  "breast", breast_env$breast$X_train, breast_env$breast$y_train,
  breast_env$breast$X_test, breast_env$breast$y_test, 10L
)

metref_path <- Sys.getenv(
  "FASTPLS_METREF_TASK",
  file.path(Sys.getenv("FASTPLS_DATA_ROOT"), "metref_task.rds")
)
metref_task <- readRDS(metref_path)
to_double <- function(x) {
  if (inherits(x, "float32")) float::dbl(x) else as.matrix(x)
}
write_dataset(
  "metref", to_double(metref_task$Xtrain), metref_task$Ytrain,
  to_double(metref_task$Xtest), metref_task$Ytest, 22L
)

cifar_env <- new.env(parent = emptyenv())
cifar_path <- Sys.getenv("FASTPLS_CIFAR_RDATA")
if (!nzchar(cifar_path)) stop("Set FASTPLS_CIFAR_RDATA.", call. = FALSE)
load(cifar_path, envir = cifar_env)
cifar <- cifar_env$r
feature_columns <- grep("^feat_", names(cifar), value = TRUE)
train <- cifar$split == "train"
write_dataset(
  "cifar100", as.matrix(cifar[train, feature_columns, drop = FALSE]), cifar$label_name[train],
  as.matrix(cifar[!train, feature_columns, drop = FALSE]), cifar$label_name[!train], 50L
)

message("Wrote matched benchmark inputs to ", normalizePath(out_dir))
