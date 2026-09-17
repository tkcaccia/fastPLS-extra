#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 4L) {
  stop("Usage: worker.R CONFIG_RDS RESULT_RDS PID_FILE MEASUREMENT_DONE", call. = FALSE)
}

cfg <- readRDS(args[[1L]])
result_path <- args[[2L]]
pid_file <- args[[3L]]
measurement_done <- args[[4L]]
dir.create(dirname(result_path), recursive = TRUE, showWarnings = FALSE)
writeLines(as.character(Sys.getpid()), pid_file)

benchmark_library <- Sys.getenv("FASTPLS_SCALING_LIB", unset = "")
if (nzchar(benchmark_library)) {
  .libPaths(unique(c(benchmark_library, .libPaths())))
}
suppressPackageStartupMessages(library(fastPLS))
expected_version <- Sys.getenv(
  "FASTPLS_SCALING_EXPECTED_VERSION", unset = "0.99.39"
)
actual_version <- as.character(utils::packageVersion("fastPLS"))
if (!identical(actual_version, expected_version)) {
  stop(
    "Controlled-scaling worker expected fastPLS ", expected_version,
    " but loaded ", actual_version, ".",
    call. = FALSE
  )
}

loaded_blas_library <- function() {
  maps <- "/proc/self/maps"
  if (file.exists(maps)) {
    paths <- unique(sub(".*[[:space:]](/[^[:space:]]+)$", "\\1", readLines(maps, warn = FALSE)))
    paths <- paths[grepl("(openblas|libblas|accelerate|veclib)", paths, ignore.case = TRUE)]
    if (length(paths)) return(paste(paths, collapse = " | "))
  }
  unname(extSoftVersion()["BLAS"])
}

reported_blas_threads <- if (requireNamespace("RhpcBLASctl", quietly = TRUE)) {
  suppressWarnings(as.integer(RhpcBLASctl::blas_get_num_procs()))
} else NA_integer_

rss_mb <- function() {
  if (!requireNamespace("ps", quietly = TRUE)) return(NA_real_)
  info <- tryCatch(ps::ps_memory_info(ps::ps_handle()), error = function(e) NULL)
  if (is.null(info)) return(NA_real_)
  as.numeric(info[["rss"]]) / 1024^2
}

make_task <- function(cfg) {
  set.seed(cfg$data_seed)
  n <- cfg$n_train + cfg$n_test
  X <- matrix(rnorm(n * cfg$p), nrow = n, ncol = cfg$p)
  rank <- min(cfg$latent_rank, cfg$p, max(1L, cfg$q))
  U <- matrix(rnorm(cfg$p * rank), cfg$p, rank) / sqrt(cfg$p)
  Z <- X %*% U
  if (identical(cfg$task_type, "classification")) {
    W <- matrix(rnorm(rank * cfg$class_count), rank, cfg$class_count) / sqrt(rank)
    score <- Z %*% W + matrix(rnorm(n * cfg$class_count, sd = cfg$noise), n)
    y <- max.col(score, ties.method = "first")
    y[seq_len(cfg$class_count)] <- seq_len(cfg$class_count)
    Y <- factor(y, levels = seq_len(cfg$class_count))
  } else {
    V <- matrix(rnorm(rank * cfg$q), rank, cfg$q) / sqrt(rank)
    Y <- Z %*% V + matrix(rnorm(n * cfg$q, sd = cfg$noise), nrow = n)
  }
  train <- seq_len(cfg$n_train)
  test <- cfg$n_train + seq_len(cfg$n_test)
  list(
    Xtrain = X[train, , drop = FALSE],
    Ytrain = if (is.factor(Y)) Y[train] else Y[train, , drop = FALSE],
    Xtest = X[test, , drop = FALSE],
    Ytest = if (is.factor(Y)) Y[test] else Y[test, , drop = FALSE]
  )
}

last_component <- function(x, ncomp) {
  if (is.list(x) && !is.data.frame(x)) return(x[[length(x)]])
  if (is.data.frame(x)) return(x[[ncol(x)]])
  if (is.array(x) && length(dim(x)) == 3L) return(x[, , dim(x)[3L], drop = TRUE])
  x
}

prediction_artifact <- function(pred, task_type, ncomp) {
  if (identical(task_type, "classification")) {
    labels <- as.character(last_component(pred$Ypred, ncomp))
    scores <- if (!is.null(pred$Yscore)) last_component(pred$Yscore, ncomp) else NULL
    return(list(labels = labels, scores = scores))
  }
  list(prediction = as.matrix(last_component(pred$Ypred, ncomp)))
}

regression_metrics <- function(observed, predicted, ytrain) {
  observed <- as.matrix(observed)
  predicted <- as.matrix(predicted)
  baseline <- matrix(colMeans(ytrain), nrow(observed), ncol(observed), byrow = TRUE)
  press <- sum((observed - predicted)^2)
  list(rmsd = sqrt(mean((observed - predicted)^2)), q2 = 1 - press / sum((observed - baseline)^2))
}

numeric_agreement <- function(candidate, reference) {
  a <- as.numeric(candidate)
  b <- as.numeric(reference)
  denom <- sqrt(sum(b * b))
  list(
    relative_error = sqrt(sum((a - b)^2)) / max(denom, .Machine$double.eps),
    correlation = if (length(a) > 1L && stats::sd(a) > 0 && stats::sd(b) > 0) stats::cor(a, b) else NA_real_
  )
}

row <- data.frame(
  run_id = cfg$run_id,
  package_version = actual_version,
  source_archive_sha256 = Sys.getenv(
    "FASTPLS_SOURCE_ARCHIVE_SHA256",
    unset = NA_character_
  ),
  cpu_profile = Sys.getenv("FASTPLS_SCALING_CPU_PROFILE", unset = "reference_1"),
  requested_blas_threads = as.integer(Sys.getenv("FASTPLS_SCALING_THREADS", unset = "1")),
  reported_blas_threads = reported_blas_threads,
  loaded_blas_library = loaded_blas_library(),
  scenario_id = cfg$scenario_id,
  design_partition = if (is.null(cfg$design_partition)) "one_factor" else cfg$design_partition,
  factor_name = cfg$factor_name,
  factor_value = cfg$factor_value,
  factor_label = cfg$factor_label,
  task_type = cfg$task_type,
  method = "simpls",
  route = cfg$route,
  backend = cfg$backend,
  svd_method = cfg$svd_method,
  xprod_requested = cfg$xprod,
  xprod_used = NA_character_,
  precision = "float64",
  n_train = cfg$n_train,
  n_test = cfg$n_test,
  p = cfg$p,
  q = cfg$q,
  class_count = cfg$class_count,
  latent_rank = cfg$latent_rank,
  max_ncomp = max(cfg$ncomp),
  requested_prefixes = cfg$requested_prefixes,
  crosscov_mb = cfg$p * cfg$q * 8 / 1024^2,
  replicate = cfg$replicate,
  data_seed = cfg$data_seed,
  fit_seed = cfg$fit_seed,
  oversample = cfg$oversample,
  power = cfg$power,
  rsvd_control_profile = NA_character_,
  rsvd_case_audit_available = NA,
  rsvd_case_audit_certified = NA,
  rsvd_deterministic_fallbacks = NA_integer_,
  rsvd_audit_max_attempts = NA_integer_,
  rsvd_effective_oversample = NA_integer_,
  rsvd_effective_power = NA_integer_,
  rsvd_max_triplet_residual = NA_real_,
  rsvd_max_omitted_direction_ratio = NA_real_,
  direction_rule = NA_character_,
  directions_per_solve = NA_integer_,
  candidate_block_refresh = NA,
  fresh_start = NA,
  refresh_width = NA_integer_,
  refresh_iterations = NA_integer_,
  baseline_rss_mb = NA_real_,
  rss_after_fit_mb = NA_real_,
  rss_after_prediction_mb = NA_real_,
  process_peak_rss_mb = NA_real_,
  incremental_peak_rss_mb = NA_real_,
  gpu_process_peak_mb = NA_real_,
  gpu_total_baseline_mb = NA_real_,
  gpu_total_peak_mb = NA_real_,
  gpu_total_incremental_mb = NA_real_,
  fit_sec = NA_real_,
  prediction_sec = NA_real_,
  total_sec = NA_real_,
  model_size_mb = NA_real_,
  input_size_mb = NA_real_,
  rmsd = NA_real_,
  q2 = NA_real_,
  accuracy = NA_real_,
  prediction_relative_error = NA_real_,
  prediction_correlation = NA_real_,
  label_agreement = NA_real_,
  score_relative_error = NA_real_,
  score_correlation = NA_real_,
  metric_absolute_difference = NA_real_,
  numerical_status = NA_character_,
  status = "failed",
  warnings = "",
  error = "",
  stringsAsFactors = FALSE
)

warnings_seen <- character()
tryCatch({
  if (cfg$backend == "cuda" && !isTRUE(fastPLS::has_cuda())) stop("CUDA backend unavailable")
  if (cfg$backend == "metal" && !isTRUE(fastPLS::has_metal())) stop("Metal backend unavailable")

  task <- make_task(cfg)
  row$input_size_mb <- as.numeric(object.size(task)) / 1024^2
  gc()
  row$baseline_rss_mb <- rss_mb()

  if (cfg$xprod == "auto") {
    Sys.unsetenv(c("FASTPLS_ABLATION_MODE", "FASTPLS_ABLATION_XPROD"))
  } else {
    Sys.setenv(
      FASTPLS_ABLATION_MODE = "1",
      FASTPLS_ABLATION_XPROD = if (cfg$xprod == "implicit") "1" else "0"
    )
  }

  fit_arguments <- list(
    Xtrain = task$Xtrain,
    Ytrain = task$Ytrain,
    ncomp = cfg$ncomp,
    method = "simpls",
    backend = cfg$backend,
    svd.method = cfg$svd_method,
    classifier = "argmax",
    scaling = "centering",
    fit = FALSE,
    return_variance = FALSE,
    return_loadings = FALSE,
    seed = cfg$fit_seed
  )
  if (is.finite(cfg$oversample)) fit_arguments$oversample <- cfg$oversample
  if (is.finite(cfg$power)) fit_arguments$power <- cfg$power

  row$fit_sec <- system.time({
    fit <- withCallingHandlers(
      do.call(fastPLS::pls, fit_arguments),
      warning = function(w) {
        warnings_seen <<- c(warnings_seen, conditionMessage(w))
        invokeRestart("muffleWarning")
      }
    )
  })[["elapsed"]]
  row$rss_after_fit_mb <- rss_mb()
  row$model_size_mb <- as.numeric(object.size(fit)) / 1024^2
  rsvd_diagnostics <- fit$diagnostics$rsvd
  if (!is.null(rsvd_diagnostics)) {
    if (!is.null(rsvd_diagnostics$control_profile)) {
      row$rsvd_control_profile <- rsvd_diagnostics$control_profile
    }
    if (!is.null(rsvd_diagnostics$oversample)) {
      row$rsvd_effective_oversample <- rsvd_diagnostics$oversample
    }
    if (!is.null(rsvd_diagnostics$power)) {
      row$rsvd_effective_power <- rsvd_diagnostics$power
    }
  }
  audit <- rsvd_diagnostics$case_audit
  if (!is.null(audit)) {
    row$rsvd_case_audit_available <- audit$solves > 0L
    if (audit$solves > 0L) {
      row$rsvd_case_audit_certified <-
        audit$certified == audit$solves && audit$failures == 0L
      row$rsvd_deterministic_fallbacks <- audit$deterministic_fallbacks
      row$rsvd_audit_max_attempts <- audit$max_attempts
      if (!is.null(audit$max_effective_oversample)) {
        row$rsvd_effective_oversample <- audit$max_effective_oversample
      }
      if (!is.null(audit$max_effective_power)) {
        row$rsvd_effective_power <- audit$max_effective_power
      }
      row$rsvd_max_triplet_residual <- audit$max_triplet_residual
      row$rsvd_max_omitted_direction_ratio <-
        audit$max_omitted_direction_ratio
    }
  }
  direction <- fit$diagnostics$simpls_direction
  if (!is.null(direction)) {
    row$direction_rule <- direction$rule
    row$directions_per_solve <- direction$directions_per_solve
    row$candidate_block_refresh <- direction$candidate_block_refresh
    row$fresh_start <- direction$fresh_start
    row$refresh_width <- direction$refresh_width
    row$refresh_iterations <- direction$refresh_iterations
  }

  row$prediction_sec <- system.time({
    pred <- predict(
      fit, task$Xtest,
      raw_scores = identical(cfg$task_type, "classification"),
      backend = cfg$backend
    )
  })[["elapsed"]]
  row$rss_after_prediction_mb <- rss_mb()
  row$total_sec <- row$fit_sec + row$prediction_sec
  artifact <- prediction_artifact(pred, cfg$task_type, cfg$ncomp)

  internal <- attr(fit, "fastPLS_internal", exact = TRUE)
  if (is.null(internal)) internal <- list()
  xprod_used <- internal$xprod_mode
  if (is.null(xprod_used)) xprod_used <- internal$xprod_default
  if (!is.null(xprod_used) && length(xprod_used)) {
    row$xprod_used <- as.character(xprod_used[[1L]])
  }

  if (identical(cfg$task_type, "classification")) {
    row$accuracy <- mean(artifact$labels == as.character(task$Ytest))
  } else {
    metrics <- regression_metrics(task$Ytest, artifact$prediction, task$Ytrain)
    row$rmsd <- metrics$rmsd
    row$q2 <- metrics$q2
  }

  file.create(measurement_done)

  if (isTRUE(cfg$reference)) {
    saveRDS(list(artifact = artifact, rmsd = row$rmsd, q2 = row$q2, accuracy = row$accuracy), cfg$reference_file)
    row$prediction_relative_error <- 0
    row$prediction_correlation <- 1
    row$label_agreement <- if (identical(cfg$task_type, "classification")) 1 else NA_real_
    row$score_relative_error <- if (identical(cfg$task_type, "classification")) 0 else NA_real_
    row$score_correlation <- if (identical(cfg$task_type, "classification")) 1 else NA_real_
    row$metric_absolute_difference <- 0
    row$numerical_status <- "deterministic_reference"
  } else if (file.exists(cfg$reference_file)) {
    ref <- readRDS(cfg$reference_file)
    if (identical(cfg$task_type, "classification")) {
      row$label_agreement <- mean(artifact$labels == ref$artifact$labels)
      if (!is.null(artifact$scores) && !is.null(ref$artifact$scores)) {
        agree <- numeric_agreement(artifact$scores, ref$artifact$scores)
        row$score_relative_error <- agree$relative_error
        row$score_correlation <- agree$correlation
      }
      row$metric_absolute_difference <- abs(row$accuracy - ref$accuracy)
      score_ok <- !is.finite(row$score_relative_error) || (
        row$score_relative_error <= 0.01 &&
          is.finite(row$score_correlation) &&
          row$score_correlation >= 0.995
      )
      row$numerical_status <- if (
        is.finite(row$label_agreement) &&
          row$label_agreement >= 0.995 &&
          row$metric_absolute_difference <= 0.005 &&
          score_ok
      ) "within_tolerance" else "outside_tolerance"
    } else {
      agree <- numeric_agreement(artifact$prediction, ref$artifact$prediction)
      row$prediction_relative_error <- agree$relative_error
      row$prediction_correlation <- agree$correlation
      row$metric_absolute_difference <- abs(row$rmsd - ref$rmsd)
      row$numerical_status <- if (
        agree$relative_error <= 0.01 &&
          is.finite(agree$correlation) &&
          agree$correlation >= 0.995 &&
          row$metric_absolute_difference <= 0.005
      ) "within_tolerance" else "outside_tolerance"
    }
  } else {
    row$numerical_status <- "reference_missing"
  }

  row$status <- "success"
  row$warnings <- paste(unique(warnings_seen), collapse = " | ")
}, error = function(e) {
  file.create(measurement_done)
  row$error <<- conditionMessage(e)
  row$warnings <<- paste(unique(warnings_seen), collapse = " | ")
})

saveRDS(row, result_path)
write.csv(row, sub("[.]rds$", ".csv", result_path), row.names = FALSE)
