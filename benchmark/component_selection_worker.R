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

coerce_input_matrix <- function(value, precision) {
  if (identical(precision, "native")) return(value)
  if (identical(precision, "float32")) {
    if (inherits(value, "float32")) return(value)
    return(float::fl(as.matrix(value)))
  }
  as_double_matrix(value)
}

task <- readRDS(config$task_path)
if (identical(config$dataset, "tabula")) {
  labels <- c(as.character(task$Ytrain), as.character(task$Ytest))
  expected_counts <- c(
    droplet_Bladder = 2500L, droplet_Heart_and_Aorta = 624L,
    droplet_Kidney = 2777L, droplet_Limb_Muscle = 4536L,
    droplet_Liver = 1845L, droplet_Lung = 5449L,
    droplet_Mammary_Gland = 4478L, droplet_Marrow = 3651L,
    droplet_Spleen = 9552L, droplet_Thymus = 1429L,
    droplet_Tongue = 7537L, droplet_Trachea = 11269L,
    facs_Aorta = 406L, facs_Bladder = 1355L,
    facs_Brain_Myeloid = 4455L, `facs_Brain_Non-Myeloid` = 3372L,
    facs_Diaphragm = 870L, facs_Fat = 4955L, facs_Heart = 4364L,
    facs_Kidney = 519L, facs_Large_Intestine = 3708L,
    facs_Limb_Muscle = 1090L, facs_Liver = 585L, facs_Lung = 1716L,
    facs_Mammary_Gland = 2402L, facs_Marrow = 5021L,
    facs_Pancreas = 1536L, facs_Skin = 2303L, facs_Spleen = 1697L,
    facs_Thymus = 1349L, facs_Tongue = 1402L, facs_Trachea = 1350L
  )
  observed_counts <- table(labels)
  tabula_valid <- length(labels) == 100102L && task$p == 50L &&
    length(unique(labels)) == 32L && !anyNA(labels) &&
    !any(!nzchar(trimws(labels))) && identical(
      as.integer(observed_counts[names(expected_counts)]),
      unname(expected_counts)
    )
  if (!tabula_valid) {
    stop(
      paste(
        "Tabula Muris component selection requires the verified",
        "100,102-cell, 32-class PCA50 task."
      ),
      call. = FALSE
    )
  }
}
precision <- config$precision %||% "native"
X <- coerce_input_matrix(task$Xtrain, precision)
Y <- task$Ytrain
classification <- is.factor(Y) || is.character(Y)
if (!classification) {
  Y <- coerce_input_matrix(Y, precision)
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
  precision = if (inherits(X, "float32")) "float32" else "float64",
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
