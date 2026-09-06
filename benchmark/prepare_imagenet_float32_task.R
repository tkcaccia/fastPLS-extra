#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
source_file <- if (length(args) >= 1L) args[[1L]] else Sys.getenv(
  "FASTPLS_IMAGENET_FLOAT32_RDATA",
  unset = "~/Documents/fastpls/data/imagenet_float32.RData"
)
task_file <- if (length(args) >= 2L) args[[2L]] else Sys.getenv(
  "FASTPLS_IMAGENET_FLOAT32_TASK",
  unset = "~/Documents/fastpls/data/imagenet_float32_seed123_train1000000_task.rds"
)
train_n <- if (length(args) >= 3L) as.integer(args[[3L]]) else 1000000L
seed <- if (length(args) >= 4L) as.integer(args[[4L]]) else 123L

source_file <- path.expand(source_file)
task_file <- path.expand(task_file)

stamp <- function(...) {
  message("[", format(Sys.time(), "%Y-%m-%d %H:%M:%S"), "] ", paste0(..., collapse = ""))
}

if (!requireNamespace("float", quietly = TRUE)) {
  stop("The float package is required to prepare the ImageNet float32 task.")
}
if (!file.exists(source_file)) {
  stop("ImageNet float32 source file not found: ", source_file)
}

is_float32 <- function(x) inherits(x, "float32") || methods::is(x, "float32")

extract_xy <- function(env) {
  objects <- mget(ls(env, all.names = TRUE), envir = env, inherits = FALSE)

  candidate_from_list <- function(x) {
    if (!is.list(x)) return(NULL)
    pairs <- list(
      c("data", "labels"), c("X", "y"), c("x", "y"),
      c("features", "labels"), c("X", "labels")
    )
    for (pair in pairs) {
      if (all(pair %in% names(x))) {
        return(list(X = x[[pair[[1L]]]], y = x[[pair[[2L]]]]))
      }
    }
    if (all(c("Xtrain", "Ytrain", "Xtest", "Ytest") %in% names(x))) {
      return(list(
        X = rbind(x$Xtrain, x$Xtest),
        y = c(as.character(x$Ytrain), as.character(x$Ytest))
      ))
    }
    NULL
  }

  preferred <- c("dataset_float32", "dataset", "imagenet", "r")
  for (name in intersect(preferred, names(objects))) {
    out <- candidate_from_list(objects[[name]])
    if (!is.null(out)) return(out)
  }
  for (x in objects) {
    out <- candidate_from_list(x)
    if (!is.null(out)) return(out)
  }

  pairs <- list(
    c("data", "labels"), c("X", "y"), c("x", "y"),
    c("features", "labels"), c("X", "labels")
  )
  for (pair in pairs) {
    if (all(pair %in% names(objects))) {
      return(list(X = objects[[pair[[1L]]]], y = objects[[pair[[2L]]]]))
    }
  }

  if ("r" %in% names(objects) && is.data.frame(objects$r) &&
      "label_idx" %in% names(objects$r)) {
    feature_cols <- grep("^feat_", names(objects$r), value = TRUE)
    if (!length(feature_cols)) {
      feature_cols <- setdiff(names(objects$r), c("image_path", "split", "label_idx", "label_name"))
    }
    return(list(X = as.matrix(objects$r[, feature_cols, drop = FALSE]), y = objects$r$label_idx))
  }
  stop("Could not locate an ImageNet feature matrix and labels in ", source_file)
}

stamp("Loading ", source_file)
loaded <- new.env(parent = emptyenv())
load(source_file, envir = loaded)
xy <- extract_xy(loaded)
rm(loaded)
gc(FALSE)

if (!is_float32(xy$X)) {
  stop(
    "The ImageNet source matrix is not float32. Refusing a silent conversion because ",
    "this task is intended to validate end-to-end float32 memory use."
  )
}
if (length(dim(xy$X)) != 2L || nrow(xy$X) < 2L || ncol(xy$X) < 1L) {
  stop("ImageNet X must be a non-empty two-dimensional matrix.")
}

y <- factor(as.vector(xy$y))
if (length(y) != nrow(xy$X)) {
  stop("ImageNet labels length does not match nrow(X).")
}
if (!is.finite(train_n) || train_n < 1L || train_n >= nrow(xy$X)) {
  stop("train_n must be between 1 and nrow(X) - 1.")
}

set.seed(seed)
train_idx <- sort(sample.int(nrow(xy$X), train_n, replace = FALSE))
test_idx <- setdiff(seq_len(nrow(xy$X)), train_idx)
stamp(
  "Creating fixed split: train=", length(train_idx),
  ", test=", length(test_idx), ", p=", ncol(xy$X),
  ", classes=", nlevels(y)
)

Xtrain <- xy$X[train_idx, , drop = FALSE]
Xtest <- xy$X[test_idx, , drop = FALSE]
if (!is_float32(Xtrain) || !is_float32(Xtest)) {
  stop("Subsetting the ImageNet feature matrix did not preserve float32 storage.")
}

task_base <- sub("\\.rds$", "", task_file, ignore.case = TRUE)
train_file <- paste0(task_base, "_Xtrain.rds")
test_file <- paste0(task_base, "_Xtest.rds")
dir.create(dirname(task_file), recursive = TRUE, showWarnings = FALSE)

stamp("Saving float32 training matrix to ", train_file)
saveRDS(Xtrain, train_file, compress = FALSE)
rm(Xtrain)
gc(FALSE)
stamp("Saving float32 test matrix to ", test_file)
saveRDS(Xtest, test_file, compress = FALSE)
rm(Xtest)
gc(FALSE)

task <- list(
  Xtrain_rds = normalizePath(train_file, mustWork = TRUE),
  Ytrain = factor(y[train_idx], levels = levels(y)),
  Xtest_rds = normalizePath(test_file, mustWork = TRUE),
  Ytest = factor(y[test_idx], levels = levels(y)),
  train_idx = train_idx,
  test_idx = test_idx,
  n_train = length(train_idx),
  n_test = length(test_idx),
  p = ncol(xy$X),
  n_classes = nlevels(y),
  levels = levels(y),
  precision = "float32",
  seed = seed,
  split_method = "random_without_replacement_from_pooled_archive",
  split_is_standard_imagenet = FALSE,
  split_is_stratified = FALSE,
  split_overlap_n = length(intersect(train_idx, test_idx)),
  split_union_n = length(union(train_idx, test_idx)),
  evaluation_role = "exploratory_development_holdout_not_external_validation",
  source_file = normalizePath(source_file, mustWork = TRUE),
  source_size_bytes = unname(file.info(source_file)$size),
  train_matrix_size_bytes = unname(file.info(train_file)$size),
  test_matrix_size_bytes = unname(file.info(test_file)$size),
  prepared_at = format(Sys.time(), "%Y-%m-%d %H:%M:%S %Z")
)

rm(xy, y, train_idx, test_idx)
gc(FALSE)
stamp("Saving task metadata to ", task_file)
saveRDS(task, task_file, compress = FALSE)
stamp(
  "Saved task: train=", round(file.info(train_file)$size / 1024^3, 3),
  " GiB, test=", round(file.info(test_file)$size / 1024^3, 3), " GiB"
)
