#!/usr/bin/env Rscript

# Precision agreement screen for the four public PLS families.  It is kept
# intentionally small so it can be run on CPU, CUDA, or Metal before a larger
# benchmark; unavailable backend combinations are recorded rather than hidden.

args <- commandArgs(trailingOnly = TRUE)
get_arg <- function(name, default) {
  key <- paste0("--", name, "=")
  value <- args[startsWith(args, key)]
  if (!length(value)) return(default)
  sub(key, "", value[[1L]], fixed = TRUE)
}

benchmark_lib <- Sys.getenv("FASTPLS_BENCH_LIB", "")
if (nzchar(benchmark_lib)) {
  .libPaths(unique(c(benchmark_lib, .libPaths())))
}

if (!requireNamespace("fastPLS", quietly = TRUE) ||
    !requireNamespace("float", quietly = TRUE)) {
  stop("fastPLS and float must be installed.", call. = FALSE)
}

suppressPackageStartupMessages(library(fastPLS))

backend <- match.arg(get_arg("backend", "cpu"), c("cpu", "cuda", "metal"))
out_dir <- get_arg("out", "")
if (!nzchar(out_dir)) {
  results_root <- Sys.getenv("FASTPLS_RESULTS_ROOT")
  if (!nzchar(results_root)) stop("Set --out or FASTPLS_RESULTS_ROOT.")
  out_dir <- file.path(results_root, "float32_backend_agreement")
}
seed <- as.integer(get_arg("seed", "123"))
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

backend_available <- switch(
  backend,
  cpu = TRUE,
  cuda = isTRUE(fastPLS::has_cuda()),
  metal = isTRUE(fastPLS::has_metal())
)

make_classification_task <- function() {
  set.seed(seed)
  X <- as.matrix(iris[, 1:4])
  y <- factor(iris$Species)
  take <- unlist(lapply(split(seq_len(nrow(X)), y), function(index) {
    sample(index, 35L)
  }), use.names = FALSE)
  test <- setdiff(seq_len(nrow(X)), take)
  list(
    name = "iris_classification",
    classification = TRUE,
    Xtrain = X[take, , drop = FALSE], ytrain = y[take],
    Xtest = X[test, , drop = FALSE], ytest = y[test]
  )
}

make_regression_task <- function() {
  set.seed(seed)
  dat <- mtcars
  X <- scale(as.matrix(dat[, setdiff(names(dat), "mpg")]))
  y <- matrix(dat$mpg, ncol = 1L)
  take <- sample(seq_len(nrow(X)), 22L)
  test <- setdiff(seq_len(nrow(X)), take)
  list(
    name = "mtcars_regression",
    classification = FALSE,
    Xtrain = X[take, , drop = FALSE], ytrain = y[take, , drop = FALSE],
    Xtest = X[test, , drop = FALSE], ytest = y[test, , drop = FALSE]
  )
}

last_prediction <- function(value) {
  if (is.data.frame(value)) {
    if (!ncol(value)) stop("Prediction data frame has no columns.")
    return(value[[ncol(value)]])
  }
  if (is.list(value) && !is.data.frame(value)) {
    return(value[[length(value)]])
  }
  if (length(dim(value)) == 3L) {
    return(value[, , dim(value)[3L], drop = FALSE][, , 1L])
  }
  value
}

relative_error <- function(observed, predicted) {
  observed <- as.matrix(observed)
  predicted <- as.matrix(predicted)
  sqrt(sum((observed - predicted)^2)) /
    max(sqrt(sum(observed^2)), .Machine$double.eps)
}

as_numeric_prediction <- function(x) {
  if (inherits(x, "float32")) {
    return(as.matrix(float::dbl(x)))
  }
  as.matrix(x)
}

fit_one <- function(task, family, precision, classifier = "argmax", kernel = "linear") {
  Xtrain <- task$Xtrain
  Xtest <- task$Xtest
  ytrain <- task$ytrain
  ytest <- task$ytest
  if (identical(precision, "float32")) {
    Xtrain <- float::fl(Xtrain)
    Xtest <- float::fl(Xtest)
    if (!task$classification) {
      ytrain <- float::fl(ytrain)
      ytest <- float::fl(ytest)
    }
  }
  svd_method <- if (identical(backend, "cuda")) "rsvd" else "rsvd"
  elapsed <- system.time({
    fit <- fastPLS::pls(
      Xtrain = Xtrain,
      Ytrain = ytrain,
      Xtest = Xtest,
      Ytest = ytest,
      ncomp = 2L,
      method = family,
      kernel = kernel,
      backend = backend,
      svd.method = svd_method,
      scaling = "centering",
      classifier = classifier,
      fit = TRUE,
      return_variance = FALSE,
      oversample = 32L,
      power = 5L,
      seed = seed
    )
  })[["elapsed"]]
  prediction <- last_prediction(fit$Ypred)
  list(fit = fit, prediction = prediction, elapsed_sec = elapsed)
}

rows <- list()
row_id <- 1L
for (task in list(make_classification_task(), make_regression_task())) {
  configurations <- data.frame(
    family = c("plssvd", "simpls", "opls", "kernelpls", "kernelpls"),
    classifier = "argmax",
    kernel = c("linear", "linear", "linear", "linear", "rbf"),
    stringsAsFactors = FALSE
  )
  if (task$classification) {
    configurations <- rbind(
      configurations,
      data.frame(
        family = "simpls", classifier = "lda", kernel = "linear",
        stringsAsFactors = FALSE
      )
    )
  }
  for (configuration_id in seq_len(nrow(configurations))) {
    family <- configurations$family[[configuration_id]]
    classifier <- configurations$classifier[[configuration_id]]
    kernel <- configurations$kernel[[configuration_id]]
    row <- data.frame(
      package_version = as.character(utils::packageVersion("fastPLS")),
      dataset = task$name,
      task_type = if (task$classification) "classification" else "regression",
      method = family,
      classifier = classifier,
      kernel = kernel,
      backend = backend,
      n_train = nrow(task$Xtrain),
      n_test = nrow(task$Xtest),
      p = ncol(task$Xtrain),
      ncomp = 2L,
      oversample = 32L,
      power = 5L,
      status = "skipped_backend_unavailable",
      float64_time_sec = NA_real_,
      float32_time_sec = NA_real_,
      float64_metric = NA_real_,
      float32_metric = NA_real_,
      metric_delta_float32_minus_float64 = NA_real_,
      prediction_agreement = NA_real_,
      relative_prediction_error = NA_real_,
      notes = NA_character_,
      stringsAsFactors = FALSE
    )
    if (!backend_available) {
      row$notes <- sprintf("backend='%s' is unavailable on this host", backend)
      rows[[row_id]] <- row
      row_id <- row_id + 1L
      next
    }
    result <- tryCatch({
      double <- fit_one(task, family, "float64", classifier, kernel)
      single <- fit_one(task, family, "float32", classifier, kernel)
      if (task$classification) {
        p64 <- as.character(double$prediction)
        p32 <- as.character(single$prediction)
        row$float64_metric <- mean(p64 == as.character(task$ytest))
        row$float32_metric <- mean(p32 == as.character(task$ytest))
        row$prediction_agreement <- mean(p64 == p32)
      } else {
        p64 <- as_numeric_prediction(double$prediction)
        p32 <- as_numeric_prediction(single$prediction)
        row$float64_metric <- sqrt(mean((p64 - task$ytest)^2))
        row$float32_metric <- sqrt(mean((p32 - task$ytest)^2))
        row$prediction_agreement <- stats::cor(as.vector(p64), as.vector(p32))
        row$relative_prediction_error <- relative_error(p64, p32)
      }
      row$float64_time_sec <- double$elapsed_sec
      row$float32_time_sec <- single$elapsed_sec
      row$metric_delta_float32_minus_float64 <-
        row$float32_metric - row$float64_metric
      row$status <- "ok"
      row
    }, error = function(error) {
      row$status <- "failed"
      row$notes <- conditionMessage(error)
      row
    })
    rows[[row_id]] <- result
    row_id <- row_id + 1L
  }
}

results <- do.call(rbind, rows)
stamp <- format(Sys.time(), "%Y%m%d_%H%M%S")
path <- file.path(out_dir, paste0("float32_backend_agreement_", backend, "_", stamp, ".csv"))
utils::write.csv(results, path, row.names = FALSE, na = "")
saveRDS(list(results = results, session = utils::sessionInfo()), sub("[.]csv$", ".rds", path))
print(results)
cat("Saved: ", normalizePath(path, winslash = "/", mustWork = FALSE), "\n", sep = "")
