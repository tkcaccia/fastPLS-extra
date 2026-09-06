#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 2L) {
  stop("Usage: component_selection_worker.R CONFIG_RDS RESULT_RDS", call. = FALSE)
}

benchmark_lib <- Sys.getenv("FASTPLS_BENCH_LIB", "")
if (nzchar(benchmark_lib)) {
  .libPaths(unique(c(benchmark_lib, .libPaths())))
}
suppressPackageStartupMessages(library(fastPLS))

`%||%` <- function(left, right) {
  if (is.null(left) || !length(left)) right else left
}

config <- readRDS(args[[1L]])
result_path <- args[[2L]]

as_double_matrix <- function(value) {
  if (inherits(value, "float32")) {
    return(float::dbl(value))
  }
  as.matrix(value)
}

task <- readRDS(config$task_path)
X <- as_double_matrix(task$Xtrain)
Y <- task$Ytrain
classification <- is.factor(Y) || is.character(Y)
if (!classification) {
  Y <- as_double_matrix(Y)
}

package_version <- as.character(packageVersion("fastPLS"))
row <- data.frame(
  package_version = package_version,
  dataset = config$dataset,
  family = config$family,
  task_type = if (classification) "classification" else "regression",
  selection_metric = config$selection_metric,
  selected_ncomp = NA_integer_,
  selected_metric = NA_real_,
  grid_min = min(config$grid),
  grid_max = max(config$grid),
  intrinsic_limit = config$intrinsic_limit,
  selection_status = "failed",
  kfold = config$kfold,
  seed = config$seed,
  control_profile = NA_character_,
  oversample = NA_integer_,
  power = NA_integer_,
  elapsed_sec = NA_real_,
  n_train = nrow(X),
  p = ncol(X),
  q = if (classification) nlevels(factor(Y)) else ncol(Y),
  status = "failed",
  error = "",
  stringsAsFactors = FALSE
)

tryCatch({
  model_config <- list(
    scaling = "centering",
    method = config$family,
    backend = "cpu",
    svd.method = "rsvd",
    north = 1L,
    kernel = "linear",
    gamma = NULL,
    degree = 3L,
    coef0 = 1,
    classifier = "argmax",
    xprod = NULL,
    svd_dots = list()
  )
  context <- fastPLS:::.single_cv_context(
    X,
    Y,
    constrain = NULL,
    config = model_config,
    seed = config$seed,
    selection_metric = config$selection_metric
  )
  engine_arguments <- fastPLS:::.single_cv_engine_arguments(
    context,
    ncomp = config$grid,
    kfold = config$kfold
  )
  engine_arguments$backend <- context$backend_compiled
  engine_arguments$store_predictions <- FALSE
  engine_arguments$return_scores <- FALSE

  elapsed <- system.time({
    cv <- do.call(fastPLS:::.pls_cv_compiled, engine_arguments)
  })[["elapsed"]]
  metrics <- cv$metrics
  if (!is.data.frame(metrics) || nrow(metrics) != length(config$grid)) {
    stop("The compiled CV engine returned an incomplete metric path.")
  }
  values <- as.numeric(metrics$metric_value)
  if (any(!is.finite(values))) {
    stop("The compiled CV engine returned non-finite selection metrics.")
  }
  selected_index <- if (identical(config$selection_metric, "rmsd")) {
    which.min(values)
  } else {
    which.max(values)
  }
  selected_ncomp <- config$grid[[selected_index]]
  at_upper <- identical(selected_ncomp, max(config$grid))
  at_lower <- identical(selected_ncomp, min(config$grid))
  status <- if (at_upper && max(config$grid) >= config$intrinsic_limit) {
    "rank_limited"
  } else if (at_upper) {
    "upper_grid_boundary"
  } else if (at_lower) {
    "lower_grid_boundary"
  } else {
    "interior"
  }

  row$selected_ncomp <- selected_ncomp
  row$selected_metric <- values[[selected_index]]
  row$selection_status <- status
  row$control_profile <- context$control$rsvd_profile %||%
    context$control$control_profile %||% "default"
  row$oversample <- context$control$rsvd_oversample
  row$power <- context$control$rsvd_power
  row$elapsed_sec <- unname(elapsed)
  row$status <- "success"

  path <- data.frame(
    package_version = package_version,
    dataset = config$dataset,
    family = config$family,
    task_type = row$task_type,
    selection_metric = config$selection_metric,
    ncomp = config$grid,
    metric_value = values,
    kfold = config$kfold,
    seed = config$seed,
    control_profile = row$control_profile,
    oversample = row$oversample,
    power = row$power,
    stringsAsFactors = FALSE
  )
  saveRDS(path, sub("[.]rds$", "_path.rds", result_path))
}, error = function(error) {
  row$error <<- conditionMessage(error)
})

dir.create(dirname(result_path), recursive = TRUE, showWarnings = FALSE)
saveRDS(row, result_path)
write.csv(row, sub("[.]rds$", ".csv", result_path), row.names = FALSE)
