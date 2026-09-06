#!/usr/bin/env Rscript

benchmark_lib <- Sys.getenv("FASTPLS_BENCH_LIB", "")
if (nzchar(benchmark_lib)) {
  .libPaths(unique(c(benchmark_lib, .libPaths())))
}

suppressPackageStartupMessages({
  library(fastPLS)
})

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 2L) {
  stop("Usage: metal_worker.R CONFIG_RDS RESULT_RDS")
}

config_path <- args[[1L]]
result_path <- args[[2L]]
cfg <- readRDS(config_path)

rss_mb <- function() {
  if (requireNamespace("ps", quietly = TRUE)) {
    info <- tryCatch(ps::ps_memory_info(ps::ps_handle()), error = function(e) NULL)
    if (!is.null(info) && is.finite(info[["rss"]])) {
      return(as.numeric(info[["rss"]]) / 1024^2)
    }
  }
  NA_real_
}

as_numeric_matrix <- function(x) {
  if (inherits(x, "float32")) {
    return(float::dbl(x))
  }
  as.matrix(x)
}

make_task <- function(cfg) {
  subset_response <- function(y, rows) {
    if (is.factor(y) || is.vector(y)) y[rows] else y[rows, , drop = FALSE]
  }
  if (!is.null(cfg$task_path) && nzchar(cfg$task_path)) {
    task <- readRDS(cfg$task_path)
  } else {
    set.seed(cfg$data_seed)
    n_train <- cfg$n_train
    n_test <- cfg$n_test
    n <- n_train + n_test
    X <- matrix(rnorm(n * cfg$p), nrow = n, ncol = cfg$p)
    latent_rank <- min(cfg$latent_rank, cfg$p)
    latent <- X[, seq_len(latent_rank), drop = FALSE]
    if (identical(cfg$task_type, "classification")) {
      class_weights <- matrix(
        rnorm(latent_rank * cfg$q),
        nrow = latent_rank,
        ncol = cfg$q
      )
      score <- latent %*% class_weights +
        matrix(rnorm(n * cfg$q, sd = cfg$noise), nrow = n)
      class_index <- max.col(score)
      class_index[seq_len(min(cfg$q, n_train))] <-
        seq_len(min(cfg$q, n_train))
      y <- factor(class_index, levels = seq_len(cfg$q))
    } else {
      response_weights <- matrix(
        rnorm(latent_rank * cfg$q),
        nrow = latent_rank,
        ncol = cfg$q
      )
      y <- latent %*% response_weights +
        matrix(rnorm(n * cfg$q, sd = cfg$noise), nrow = n)
    }
    task <- list(
      dataset = cfg$dataset,
      task_type = cfg$task_type,
      Xtrain = X[seq_len(n_train), , drop = FALSE],
      Ytrain = subset_response(y, seq_len(n_train)),
      Xtest = X[n_train + seq_len(n_test), , drop = FALSE],
      Ytest = subset_response(y, n_train + seq_len(n_test))
    )
  }

  if (!is.null(cfg$train_n) && is.finite(cfg$train_n) &&
      nrow(task$Xtrain) > cfg$train_n) {
    set.seed(cfg$data_seed)
    keep <- sort(sample(seq_len(nrow(task$Xtrain)), cfg$train_n))
    task$Xtrain <- task$Xtrain[keep, , drop = FALSE]
    task$Ytrain <- subset_response(task$Ytrain, keep)
  }
  if (!is.null(cfg$test_n) && is.finite(cfg$test_n) &&
      nrow(task$Xtest) > cfg$test_n) {
    set.seed(cfg$data_seed + 1L)
    keep <- sort(sample(seq_len(nrow(task$Xtest)), cfg$test_n))
    task$Xtest <- task$Xtest[keep, , drop = FALSE]
    task$Ytest <- subset_response(task$Ytest, keep)
  }
  if (!is.null(cfg$p_limit) && is.finite(cfg$p_limit) &&
      ncol(task$Xtrain) > cfg$p_limit) {
    keep <- seq_len(cfg$p_limit)
    task$Xtrain <- task$Xtrain[, keep, drop = FALSE]
    task$Xtest <- task$Xtest[, keep, drop = FALSE]
  }
  if (!identical(task$task_type, "classification") &&
      !is.null(cfg$q_limit) && is.finite(cfg$q_limit) &&
      ncol(task$Ytrain) > cfg$q_limit) {
    keep <- seq_len(cfg$q_limit)
    task$Ytrain <- task$Ytrain[, keep, drop = FALSE]
    task$Ytest <- task$Ytest[, keep, drop = FALSE]
  }
  task
}

coerce_precision <- function(task, precision) {
  if (identical(precision, "float32")) {
    if (!requireNamespace("float", quietly = TRUE)) {
      stop("The float package is required for float32 experiments")
    }
    task$Xtrain <- if (inherits(task$Xtrain, "float32")) {
      task$Xtrain
    } else {
      float::fl(as.matrix(task$Xtrain))
    }
    task$Xtest <- if (inherits(task$Xtest, "float32")) {
      task$Xtest
    } else {
      float::fl(as.matrix(task$Xtest))
    }
    if (!identical(task$task_type, "classification")) {
      task$Ytrain <- if (inherits(task$Ytrain, "float32")) {
        task$Ytrain
      } else {
        float::fl(as.matrix(task$Ytrain))
      }
      task$Ytest <- if (inherits(task$Ytest, "float32")) {
        task$Ytest
      } else {
        float::fl(as.matrix(task$Ytest))
      }
    }
  } else {
    task$Xtrain <- as_numeric_matrix(task$Xtrain)
    task$Xtest <- as_numeric_matrix(task$Xtest)
    if (!identical(task$task_type, "classification")) {
      task$Ytrain <- as_numeric_matrix(task$Ytrain)
      task$Ytest <- as_numeric_matrix(task$Ytest)
    }
  }
  task
}

prediction_vector <- function(object, task_type) {
  pred <- object$Ypred
  if (identical(task_type, "classification")) {
    if (is.data.frame(pred)) pred <- pred[[ncol(pred)]]
    if (is.list(pred)) pred <- pred[[length(pred)]]
    return(as.character(pred))
  }
  if (inherits(pred, "float32")) return(as.vector(float::dbl(pred)))
  if (is.list(pred)) pred <- pred[[length(pred)]]
  if (inherits(pred, "float32")) pred <- float::dbl(pred)
  if (length(dim(pred)) == 3L) {
    pred <- pred[, , dim(pred)[3L], drop = FALSE]
  }
  as.vector(pred)
}

metric_values <- function(object, task) {
  pred <- prediction_vector(object, task$task_type)
  if (identical(task$task_type, "classification")) {
    observed <- as.character(task$Ytest)
    return(list(
      metric_name = "accuracy",
      metric_value = mean(pred == observed, na.rm = TRUE),
      accuracy = mean(pred == observed, na.rm = TRUE),
      q2 = suppressWarnings(as.numeric(tail(object$Q2Y, 1L))),
      rmsd = NA_real_
    ))
  }
  observed <- as.vector(as_numeric_matrix(task$Ytest))
  train <- as_numeric_matrix(task$Ytrain)
  denominator <- sum(
    (as_numeric_matrix(task$Ytest) -
       matrix(colMeans(train), nrow = nrow(task$Ytest),
              ncol = ncol(task$Ytest), byrow = TRUE))^2
  )
  press <- sum((observed - pred)^2)
  list(
    metric_name = "rmsd",
    metric_value = sqrt(mean((observed - pred)^2)),
    accuracy = NA_real_,
    q2 = 1 - press / denominator,
    rmsd = sqrt(mean((observed - pred)^2))
  )
}

result_template <- function(cfg) {
  data.frame(
    run_id = cfg$run_id,
    experiment = cfg$experiment,
    dataset = cfg$dataset,
    task_type = cfg$task_type,
    method = cfg$method,
    backend_requested = cfg$backend,
    backend_reported = NA_character_,
    execution_route = NA_character_,
    host_assisted_components = NA,
    implicit_crosscovariance = NA,
    prediction_backend = NA_character_,
    svd_method = cfg$svd_method,
    classifier = cfg$classifier,
    precision = cfg$precision,
    ncomp = cfg$ncomp,
    n_train = NA_integer_,
    n_test = NA_integer_,
    p = NA_integer_,
    q = NA_integer_,
    seed = cfg$seed,
    replicate = cfg$replicate,
    requested_oversample = cfg$oversample,
    requested_power = cfg$power,
    control_profile = NA_character_,
    oversample = NA_integer_,
    power = NA_integer_,
    direction_rule = NA_character_,
    directions_per_solve = NA_integer_,
    refresh_width = NA_integer_,
    refresh_iterations = NA_integer_,
    fresh_start = NA,
    kernel = cfg$kernel,
    north = cfg$north,
    fit_sec = NA_real_,
    prediction_sec = NA_real_,
    total_sec = NA_real_,
    baseline_rss_mb = NA_real_,
    rss_after_fit_mb = NA_real_,
    rss_after_prediction_mb = NA_real_,
    peak_rss_mb = NA_real_,
    incremental_peak_rss_mb = NA_real_,
    metric_name = NA_character_,
    metric_value = NA_real_,
    accuracy = NA_real_,
    q2 = NA_real_,
    rmsd = NA_real_,
    prediction_checksum = NA_real_,
    prediction_length = NA_integer_,
    status = "failed",
    warnings = "",
    error = "",
    stringsAsFactors = FALSE
  )
}

out <- result_template(cfg)
warnings_seen <- character()

tryCatch({
  task <- make_task(cfg)
  task <- coerce_precision(task, cfg$precision)
  gc()
  out$n_train <- nrow(task$Xtrain)
  out$n_test <- nrow(task$Xtest)
  out$p <- ncol(task$Xtrain)
  out$q <- if (identical(task$task_type, "classification")) {
    nlevels(factor(task$Ytrain))
  } else {
    ncol(task$Ytrain)
  }
  out$baseline_rss_mb <- rss_mb()

  fit_arguments <- list(
    Xtrain = task$Xtrain,
    Ytrain = task$Ytrain,
    ncomp = cfg$ncomp,
    scaling = cfg$scaling,
    method = cfg$method,
    svd.method = cfg$svd_method,
    classifier = cfg$classifier,
    backend = cfg$backend,
    north = cfg$north,
    kernel = cfg$kernel,
    gamma = cfg$gamma,
    degree = cfg$degree,
    coef0 = cfg$coef0,
    fit = FALSE,
    return_variance = FALSE,
    return_loadings = isTRUE(cfg$save_diagnostics),
    seed = cfg$seed
  )
  if (is.finite(cfg$oversample)) fit_arguments$oversample <- cfg$oversample
  if (is.finite(cfg$power)) fit_arguments$power <- cfg$power

  fit_elapsed <- system.time({
    fit <- withCallingHandlers(
      do.call(fastPLS::pls, fit_arguments),
      warning = function(w) {
        warnings_seen <<- c(warnings_seen, conditionMessage(w))
        invokeRestart("muffleWarning")
      }
    )
  })[["elapsed"]]
  rsvd_diagnostics <- fit$diagnostics$rsvd
  if (!is.null(rsvd_diagnostics)) {
    if (!is.null(rsvd_diagnostics$control_profile)) {
      out$control_profile <- rsvd_diagnostics$control_profile
    }
    if (!is.null(rsvd_diagnostics$oversample)) {
      out$oversample <- rsvd_diagnostics$oversample
    }
    if (!is.null(rsvd_diagnostics$power)) {
      out$power <- rsvd_diagnostics$power
    }
  }
  direction_diagnostics <- fit$diagnostics$simpls_direction
  if (!is.null(direction_diagnostics)) {
    out$direction_rule <- direction_diagnostics$rule %||% NA_character_
    out$directions_per_solve <-
      direction_diagnostics$directions_per_solve %||% NA_integer_
    out$refresh_width <- direction_diagnostics$refresh_width %||% NA_integer_
    out$refresh_iterations <-
      direction_diagnostics$refresh_iterations %||% NA_integer_
    out$fresh_start <- direction_diagnostics$fresh_start %||% NA
  }
  out$rss_after_fit_mb <- rss_mb()

  pred_elapsed <- system.time({
    pred <- withCallingHandlers(
      predict(
        fit,
        task$Xtest,
        Ytest = task$Ytest,
        backend = cfg$backend
      ),
      warning = function(w) {
        warnings_seen <<- c(warnings_seen, conditionMessage(w))
        invokeRestart("muffleWarning")
      }
    )
  })[["elapsed"]]
  out$rss_after_prediction_mb <- rss_mb()

  values <- metric_values(pred, task)
  pred_vec <- prediction_vector(pred, task$task_type)
  numeric_pred <- if (identical(task$task_type, "classification")) {
    as.numeric(factor(pred_vec, levels = levels(factor(task$Ytrain))))
  } else {
    as.numeric(pred_vec)
  }
  internal <- attr(fit, "fastPLS_internal")
  # A successful explicit request proves execution on this backend: public
  # dispatch errors when CUDA or Metal is unavailable and never changes it to
  # CPU. The model intentionally does not expose input settings as fields.
  out$backend_reported <- cfg$backend
  resident_controls <- internal$resident_controls
  if (!is.null(resident_controls)) {
    out$host_assisted_components <- isTRUE(
      resident_controls$host_assisted_components
    )
    out$implicit_crosscovariance <- isTRUE(
      resident_controls$implicit_crosscovariance
    )
  }
  out$execution_route <- if (!is.null(internal$execution_route)) {
    as.character(internal$execution_route)
  } else if (
    identical(cfg$backend, "metal") && isTRUE(out$host_assisted_components)
  ) {
    "host-assisted Metal"
  } else if (identical(cfg$backend, "metal")) {
    "hybrid Metal"
  } else if (identical(cfg$backend, "cuda")) {
    "CUDA"
  } else {
    "CPU"
  }
  out$prediction_backend <- if (!is.null(internal$predict_backend)) {
    as.character(internal$predict_backend)
  } else {
    NA_character_
  }
  out$fit_sec <- unname(fit_elapsed)
  out$prediction_sec <- unname(pred_elapsed)
  out$total_sec <- out$fit_sec + out$prediction_sec
  out$metric_name <- values$metric_name
  out$metric_value <- values$metric_value
  out$accuracy <- values$accuracy
  out$q2 <- values$q2
  out$rmsd <- values$rmsd
  out$prediction_checksum <- sum(
    numeric_pred * ((seq_along(numeric_pred) %% 1009L) + 1L),
    na.rm = TRUE
  )
  out$prediction_length <- length(numeric_pred)
  out$status <- "success"
  out$warnings <- paste(unique(warnings_seen), collapse = " | ")

  if (isTRUE(cfg$save_diagnostics) || isTRUE(cfg$save_prediction)) {
    diagnostic <- list(
      prediction = pred_vec,
      Ttrain = if (isTRUE(cfg$save_diagnostics) && !is.null(fit$Ttrain)) {
        as_numeric_matrix(fit$Ttrain)
      } else NULL,
      R = if (isTRUE(cfg$save_diagnostics) && !is.null(fit$R)) {
        as_numeric_matrix(fit$R)
      } else NULL,
      P = if (isTRUE(cfg$save_diagnostics) && !is.null(fit$P)) {
        as_numeric_matrix(fit$P)
      } else NULL,
      Q = if (isTRUE(cfg$save_diagnostics) && !is.null(fit$Q)) {
        as_numeric_matrix(fit$Q)
      } else NULL,
      B = if (isTRUE(cfg$save_diagnostics) && !is.null(fit$B) &&
              length(fit$B) < 5e6) fit$B else NULL
    )
    saveRDS(diagnostic, sub("\\.rds$", "_diagnostic.rds", result_path))
  }
}, error = function(e) {
  out$error <<- conditionMessage(e)
  out$warnings <<- paste(unique(warnings_seen), collapse = " | ")
})

dir.create(dirname(result_path), recursive = TRUE, showWarnings = FALSE)
saveRDS(out, result_path)
write.csv(out, sub("\\.rds$", ".csv", result_path), row.names = FALSE)
