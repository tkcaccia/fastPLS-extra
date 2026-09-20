#!/usr/bin/env Rscript

# Reproduce the current fastPLS CUDA classification routes on the stored
# ImageNet/DINOv2 development split. One maximal component path supplies all
# requested prefixes for one classification head.

options(stringsAsFactors = FALSE)

env <- function(name, default = "") {
  value <- Sys.getenv(name, unset = default)
  if (nzchar(value)) value else default
}
stamp <- function(...) {
  message(
    "[", format(Sys.time(), "%Y-%m-%d %H:%M:%S"), "] ",
    paste0(..., collapse = "")
  )
}
rss_mb <- function() {
  if (!file.exists("/proc/self/status")) return(NA_real_)
  line <- grep("^VmRSS:", readLines("/proc/self/status", warn = FALSE),
               value = TRUE)
  if (!length(line)) return(NA_real_)
  as.numeric(sub("^VmRSS:\\s*([0-9.]+).*", "\\1", line[[1L]])) / 1024
}
peak_rss_mb <- function() {
  if (!file.exists("/proc/self/status")) return(NA_real_)
  line <- grep("^VmHWM:", readLines("/proc/self/status", warn = FALSE),
               value = TRUE)
  if (!length(line)) return(NA_real_)
  as.numeric(sub("^VmHWM:\\s*([0-9.]+).*", "\\1", line[[1L]])) / 1024
}
gpu_used_mb <- function() {
  value <- tryCatch(
    suppressWarnings(system2(
      "nvidia-smi",
      c("--query-gpu=memory.used", "--format=csv,noheader,nounits"),
      stdout = TRUE, stderr = FALSE
    )),
    error = function(e) character()
  )
  if (!length(value)) return(NA_real_)
  as.numeric(trimws(value[[1L]]))
}
as_double_matrix <- function(x) {
  if (inherits(x, "float32")) {
    return(as.matrix(float::dbl(x)))
  }
  as.matrix(x)
}
component_value <- function(x, ncomp, index, effective_ncomp = ncomp,
                            path_length = 1L) {
  keys <- unique(paste0("ncomp=", c(ncomp, effective_ncomp)))
  if (is.list(x) && !is.data.frame(x)) {
    if (!is.null(names(x))) {
      matched <- keys[keys %in% names(x)]
      if (length(matched)) return(x[[matched[[1L]]]])
    }
    if (index > length(x)) {
      stop("Prediction path is shorter than the requested component path")
    }
    return(x[[index]])
  }
  if (is.data.frame(x)) {
    matched <- keys[keys %in% names(x)]
    if (!length(matched)) {
      stop("Prediction data frame lacks the requested/effective component")
    }
    return(x[[matched[[1L]]]])
  }
  dims <- dim(x)
  if (length(dims) == 3L) {
    if (index > dims[[3L]]) {
      stop("Prediction array is shorter than the requested component path")
    }
    return(x[, , index, drop = TRUE])
  }
  if (length(dims) == 2L) {
    if (!is.null(colnames(x))) {
      matched <- keys[keys %in% colnames(x)]
      if (length(matched)) return(x[, matched[[1L]], drop = TRUE])
    }
    if (ncol(x) == 1L) return(x[, 1L])
    if (ncol(x) == path_length) {
      if (index > ncol(x)) {
        stop("Prediction matrix is shorter than the requested component path")
      }
      return(x[, index, drop = TRUE])
    }
  }
  x
}
api_classification_metrics <- function(prediction, index) {
  evaluation <- prediction$metrics
  if (is.null(evaluation$by_component) ||
      length(evaluation$by_component) < index) {
    stop("predict() did not return per-component evaluation results")
  }
  component <- evaluation$by_component[[index]]
  ordinary <- component$metrics
  topk <- component$topk
  top5_row <- which(as.integer(topk$k) == 5L)
  if (nrow(ordinary) != 1L || !length(top5_row)) {
    stop("predict() evaluation does not contain the requested top-5 result")
  }
  c(
    top1_accuracy = ordinary$accuracy[[1L]],
    top5_accuracy = topk$accuracy[[top5_row[[1L]]]],
    balanced_accuracy = ordinary$balanced_accuracy[[1L]],
    macro_f1 = ordinary$macro_f1[[1L]]
  )
}
audit_api_metrics <- function(truth, predicted, top_labels, metrics) {
  truth <- as.character(truth)
  predicted <- as.character(predicted)
  top_labels <- as.matrix(top_labels)
  if (length(predicted) != length(truth) || nrow(top_labels) != length(truth)) {
    stop("Prediction dimensions do not match the held-out labels")
  }
  top1 <- mean(predicted == truth)
  truth_matrix <- matrix(truth, nrow = length(truth), ncol = ncol(top_labels))
  top5 <- mean(rowSums(top_labels == truth_matrix) > 0L)
  if (!isTRUE(all.equal(top1, unname(metrics[["top1_accuracy"]]),
                        tolerance = 1e-12)) ||
      !isTRUE(all.equal(top5, unname(metrics[["top5_accuracy"]]),
                        tolerance = 1e-12))) {
    stop("predict() evaluation metrics disagree with returned class predictions")
  }
}

lib <- env("FASTPLS_LIB")
if (nzchar(lib)) .libPaths(unique(c(lib, .libPaths())))
suppressPackageStartupMessages(library(fastPLS))
loaded_package_path <- normalizePath(
  system.file(package = "fastPLS"),
  winslash = "/",
  mustWork = TRUE
)
loaded_package_version <- as.character(utils::packageVersion("fastPLS"))
if (nzchar(lib)) {
  requested_library <- normalizePath(lib, winslash = "/", mustWork = TRUE)
  if (!startsWith(
    loaded_package_path,
    paste0(requested_library, .Platform$file.sep)
  )) {
    stop("Loaded fastPLS outside FASTPLS_LIB: ", loaded_package_path)
  }
}
source_id <- env("FASTPLS_SOURCE_ID", "unrecorded")

task_file <- path.expand(env(
  "TASK_RDS",
  "~/Documents/fastpls/data/imagenet_float32_seed123_train1000000_task.rds"
))
output_csv <- path.expand(env(
  "OUTPUT_CSV",
  "imagenet_current_fused_lda.csv"
))
ncomp_grid <- as.integer(strsplit(env(
  "NCOMP_GRID", "50,100,200,300,400,500,600,700,800,900,1000"
), ",", fixed = TRUE)[[1L]])
ncomp_grid <- sort(unique(ncomp_grid[is.finite(ncomp_grid) & ncomp_grid > 0L]))
if (!length(ncomp_grid)) stop("NCOMP_GRID must contain positive integers")
method <- match.arg(
  env("METHOD", "simpls"),
  c("plssvd", "simpls", "opls", "kernelpls")
)
classifier <- match.arg(env("CLASSIFIER", "lda"), c("argmax", "lda"))
oversample_arg <- env("OVERSAMPLE", "auto")
power_arg <- env("POWER", "auto")
automatic_controls <- identical(oversample_arg, "auto") &&
  identical(power_arg, "auto")
if (xor(identical(oversample_arg, "auto"), identical(power_arg, "auto"))) {
  stop("OVERSAMPLE and POWER must both be 'auto' or both be numeric")
}
oversample <- if (automatic_controls) NA_integer_ else as.integer(oversample_arg)
power <- if (automatic_controls) NA_integer_ else as.integer(power_arg)
seed <- as.integer(env("SEED", "123"))
replicate_id <- as.integer(env("REPLICATE", "1"))
precision <- match.arg(env("PRECISION", "float32"), c("float32", "float64"))

dir.create(dirname(output_csv), recursive = TRUE, showWarnings = FALSE)
row_template <- data.frame(
  dataset = "imagenet",
  train_n = NA_integer_,
  test_n = NA_integer_,
  p = NA_integer_,
  q = NA_integer_,
  method = method,
  solver = "rsvd",
  backend = "cuda",
  classifier = classifier,
  precision = precision,
  ncomp_requested = ncomp_grid[[1L]],
  ncomp_effective = NA_integer_,
  oversample = oversample,
  power = power,
  control_profile = if (automatic_controls) "automatic" else "explicit",
  effective_oversample = NA_integer_,
  effective_power = NA_integer_,
  seed = seed,
  replicate = replicate_id,
  fit_time_sec = NA_real_,
  fit_predict_time_sec = NA_real_,
  top5_prediction_time_sec = NA_real_,
  total_time_sec = NA_real_,
  top1_accuracy = NA_real_,
  top5_accuracy = NA_real_,
  balanced_accuracy = NA_real_,
  macro_f1 = NA_real_,
  rss_before_data_mb = rss_mb(),
  rss_before_fit_mb = NA_real_,
  rss_after_fit_mb = NA_real_,
  rss_after_top5_mb = NA_real_,
  gpu_before_fit_mb = NA_real_,
  gpu_after_fit_mb = NA_real_,
  gpu_after_top5_mb = NA_real_,
  gpu_peak_mb = NA_real_,
  gpu_incremental_peak_mb = NA_real_,
  process_peak_rss_mb = NA_real_,
  incremental_peak_rss_mb = NA_real_,
  executed_estimator = NA_character_,
  prediction_backend = NA_character_,
  classifier_train_backend = NA_character_,
  model_gpu_resident = NA,
  fit_residency = NA_character_,
  prediction_residency = NA_character_,
  metric_source = "predict(Ytest=..., top=5)$metrics",
  audit_status = "approximate_workflow_result",
  loaded_package_path = loaded_package_path,
  loaded_package_version = loaded_package_version,
  source_id = source_id,
  algorithm_variant = NA_character_,
  status = "started",
  error = "",
  stringsAsFactors = FALSE
)

rows <- lapply(ncomp_grid, function(k) {
  out <- row_template
  out$ncomp_requested <- k
  out
})

tryCatch({
  if (!file.exists(task_file)) stop("Task metadata not found: ", task_file)
  if (!isTRUE(has_cuda())) stop("CUDA backend is unavailable")
  task <- readRDS(task_file)
  required <- c("Xtrain_rds", "Ytrain", "Xtest_rds", "Ytest")
  if (!all(required %in% names(task))) {
    stop("Task metadata must contain: ", paste(required, collapse = ", "))
  }
  for (i in seq_along(rows)) {
    rows[[i]]$train_n <- task$n_train
    rows[[i]]$test_n <- task$n_test
    rows[[i]]$p <- task$p
    rows[[i]]$q <- task$n_classes
  }

  stamp("Loading training matrix in ", precision)
  Xtrain_stored <- readRDS(task$Xtrain_rds)
  Xtrain <- if (precision == "float32") {
    if (!inherits(Xtrain_stored, "float32")) {
      float::fl(as.matrix(Xtrain_stored))
    } else {
      Xtrain_stored
    }
  } else {
    as_double_matrix(Xtrain_stored)
  }
  rm(Xtrain_stored)
  gc(FALSE)

  stamp("Loading held-out matrix in ", precision)
  Xtest_stored <- readRDS(task$Xtest_rds)
  Xtest <- if (precision == "float32") {
    if (!inherits(Xtest_stored, "float32")) {
      float::fl(as.matrix(Xtest_stored))
    } else {
      Xtest_stored
    }
  } else {
    as_double_matrix(Xtest_stored)
  }
  rm(Xtest_stored)
  gc(FALSE)

  rss_before_fit <- rss_mb()
  gpu_before_fit <- gpu_used_mb()
  set.seed(seed)
  stamp(
    "Fitting current CUDA ", toupper(method), "-", toupper(classifier),
    ": ncomp=", paste(ncomp_grid, collapse = ","),
    " controls=", if (automatic_controls) {
      "public automatic"
    } else {
      paste0("oversample ", oversample, ", power ", power)
    }
  )
  fit_arguments <- list(
    Xtrain = Xtrain,
    Ytrain = task$Ytrain,
    ncomp = ncomp_grid,
    method = method,
    backend = "cuda",
    classifier = classifier,
    scaling = "centering",
    fit = FALSE,
    return_variance = FALSE,
    seed = seed
  )
  if (method == "kernelpls") fit_arguments$kernel <- "linear"
  if (!automatic_controls) {
    fit_arguments$oversample <- oversample
    fit_arguments$power <- power
  }
  fit_time <- unname(system.time({
    fit <- do.call(pls, fit_arguments)
  })[["elapsed"]])
  rss_after_fit <- rss_mb()
  gpu_after_fit <- gpu_used_mb()

  internal <- attr(fit, "fastPLS_internal", exact = TRUE)
  rsvd_diagnostics <- fit$diagnostics$rsvd
  control_profile <- if (!is.null(rsvd_diagnostics$control_profile)) {
    as.character(rsvd_diagnostics$control_profile)[1L]
  } else if (automatic_controls) {
    "automatic"
  } else {
    "explicit"
  }
  effective_oversample <- if (!is.null(rsvd_diagnostics$oversample)) {
    as.integer(rsvd_diagnostics$oversample)[1L]
  } else {
    oversample
  }
  effective_power <- if (!is.null(rsvd_diagnostics$power)) {
    as.integer(rsvd_diagnostics$power)[1L]
  } else {
    power
  }
  executed_estimator <- as.character(internal$pls_method)[1L]
  prediction_backend <- as.character(internal$predict_backend)[1L]
  classifier_train_backend <- if (classifier == "lda" &&
      isTRUE(internal$gpu_resident)) {
    "cuda_resident_lda"
  } else if (classifier == "lda") {
    as.character(fit$lda$train_backend)[1L]
  } else {
    NA_character_
  }
  model_gpu_resident <- isTRUE(internal$gpu_resident)
  algorithm_variant <- if (is.null(fit$diagnostics$algorithm_variant)) {
    NA_character_
  } else {
    as.character(fit$diagnostics$algorithm_variant)[1L]
  }
  expected_estimator <- if (method == "kernelpls") "simpls" else method
  if (!identical(executed_estimator, expected_estimator)) {
    stop(
      "Requested ", method, " (expected ", expected_estimator,
      ") but executed estimator was ",
      executed_estimator
    )
  }
  expected_prediction_backend <- "cuda_resident"
  if (!identical(prediction_backend, expected_prediction_backend)) {
    stop(
      "Expected ", expected_prediction_backend,
      " prediction backend but observed ",
      prediction_backend
    )
  }

  # The fitted classifier no longer needs the million-row training matrix or
  # training scores for held-out prediction. Releasing both keeps the measured
  # prediction stage within the same bounded-memory contract as the package.
  rm(Xtrain)
  fit$Ttrain <- NULL
  fit$Yfit <- NULL
  fit$Ypred <- NULL
  fit$metrics <- NULL
  fit$accuracy <- NULL
  gc(FALSE)
  saveRDS(
    list(
      package_version = loaded_package_version,
      classifier = classifier,
      precision = precision,
      ncomp = ncomp_grid,
      seed = seed,
      fit_time_sec = fit_time,
      fit = fit
    ),
    paste0(output_csv, ".fit.rds"),
    compress = FALSE
  )

  stamp("Computing top-5 ", toupper(classifier), " predictions")
  top5_time <- unname(system.time({
    pred <- predict(
      fit,
      Xtest,
      Ytest = task$Ytest,
      top = 5L,
      backend = "cuda"
    )
  })[["elapsed"]])
  rss_after_top5 <- rss_mb()
  gpu_after_top5 <- gpu_used_mb()
  process_peak_rss <- peak_rss_mb()
  gpu_observations <- c(gpu_before_fit, gpu_after_fit, gpu_after_top5)
  gpu_peak <- if (any(is.finite(gpu_observations))) {
    max(gpu_observations, na.rm = TRUE)
  } else {
    NA_real_
  }

  effective <- as.integer(fit$effective_ncomp)
  if (!length(effective)) {
    effective <- as.integer(internal$ncomp)
  }
  if (length(effective) != length(ncomp_grid)) {
    stop(
      "The fitted effective-component path is not aligned with the requested ",
      "ImageNet component grid"
    )
  }
  if (any(!is.finite(effective)) || any(effective < 1L) ||
      any(effective > ncomp_grid)) {
    stop("The fitted effective-component path is invalid")
  }
  for (i in seq_along(ncomp_grid)) {
    k <- ncomp_grid[[i]]
    effective_k <- effective[[i]]
    predicted <- component_value(
      pred$Ypred, k, i, effective_k, length(ncomp_grid)
    )
    top_labels <- component_value(
      pred$Ypred_top, k, i, effective_k, length(ncomp_grid)
    )
    metrics <- api_classification_metrics(pred, i)
    audit_api_metrics(task$Ytest, predicted, top_labels, metrics)
    rows[[i]]$ncomp_effective <- effective_k
    rows[[i]]$control_profile <- control_profile
    rows[[i]]$effective_oversample <- effective_oversample
    rows[[i]]$effective_power <- effective_power
    rows[[i]]$fit_time_sec <- fit_time
    rows[[i]]$fit_predict_time_sec <- fit_time
    rows[[i]]$top5_prediction_time_sec <- top5_time
    rows[[i]]$total_time_sec <- fit_time + top5_time
    rows[[i]]$top1_accuracy <- metrics[["top1_accuracy"]]
    rows[[i]]$top5_accuracy <- metrics[["top5_accuracy"]]
    rows[[i]]$balanced_accuracy <- metrics[["balanced_accuracy"]]
    rows[[i]]$macro_f1 <- metrics[["macro_f1"]]
    rows[[i]]$rss_after_fit_mb <- rss_after_fit
    rows[[i]]$gpu_after_fit_mb <- gpu_after_fit
    rows[[i]]$rss_before_fit_mb <- rss_before_fit
    rows[[i]]$gpu_before_fit_mb <- gpu_before_fit
    rows[[i]]$rss_after_top5_mb <- rss_after_top5
    rows[[i]]$gpu_after_top5_mb <- gpu_after_top5
    rows[[i]]$gpu_peak_mb <- gpu_peak
    rows[[i]]$gpu_incremental_peak_mb <- gpu_peak - gpu_before_fit
    rows[[i]]$process_peak_rss_mb <- process_peak_rss
    rows[[i]]$incremental_peak_rss_mb <-
      process_peak_rss - rows[[i]]$rss_before_data_mb
    rows[[i]]$executed_estimator <- executed_estimator
    rows[[i]]$prediction_backend <- prediction_backend
    rows[[i]]$classifier_train_backend <- classifier_train_backend
    rows[[i]]$model_gpu_resident <- model_gpu_resident
    rows[[i]]$algorithm_variant <- algorithm_variant
    rows[[i]]$fit_residency <- if (!is.null(internal$execution_route)) {
      as.character(internal$execution_route)[1L]
    } else {
      "resident CUDA"
    }
    rows[[i]]$prediction_residency <- expected_prediction_backend
    rows[[i]]$status <- "success"
  }
}, error = function(e) {
  for (i in seq_along(rows)) {
    rows[[i]]$status <<- "failed"
    rows[[i]]$error <<- conditionMessage(e)
  }
})

result <- do.call(rbind, rows)
write.csv(result, output_csv, row.names = FALSE, na = "")
print(result)
if (!all(result$status == "success")) quit(save = "no", status = 1L)
