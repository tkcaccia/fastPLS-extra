#!/usr/bin/env Rscript

# Prespecified numerical validation of accelerated fastPLS SIMPLS against
# pls::simpls.fit (de Jong SIMPLS). Deterministic IRLBA evidence and approximate
# rSVD evidence are written to separate result tables.

benchmark_lib <- Sys.getenv("FASTPLS_BENCH_LIB", "")
if (nzchar(benchmark_lib)) {
  .libPaths(unique(c(benchmark_lib, .libPaths())))
}

suppressPackageStartupMessages({
  library(fastPLS)
  library(pls)
})

args <- commandArgs(trailingOnly = TRUE)
get_arg <- function(name, default) {
  key <- paste0("--", name, "=")
  hit <- args[startsWith(args, key)]
  if (!length(hit)) return(default)
  sub(key, "", hit[[1L]], fixed = TRUE)
}

root <- normalizePath(get_arg("root", "."), mustWork = TRUE)
source(file.path(root, "benchmark", "nmr_protocol_helpers.R"))
out_dir <- get_arg(
  "out",
  file.path(Sys.getenv("FASTPLS_RESULTS_ROOT"), "simpls_estimator_preservation")
)
if (!nzchar(Sys.getenv("FASTPLS_RESULTS_ROOT")) &&
    !any(startsWith(args, "--out="))) {
  stop("Set --out or FASTPLS_RESULTS_ROOT.", call. = FALSE)
}
nmr_path <- get_arg(
  "nmr",
  Sys.getenv("FASTPLS_NMR_INPUT")
)
quick <- identical(get_arg("quick", "false"), "true")
rsvd_oversample <- as.integer(get_arg("rsvd-oversample", "32"))
rsvd_power <- as.integer(get_arg("rsvd-power", "5"))
rsvd_seeds <- as.integer(strsplit(
  get_arg("rsvd-seeds", "1,7,19,43,123"), ",", fixed = TRUE
)[[1L]])
rsvd_seeds <- unique(rsvd_seeds[is.finite(rsvd_seeds) & rsvd_seeds >= 0L])
if (!is.finite(rsvd_oversample) || rsvd_oversample < 0L) {
  stop("--rsvd-oversample must be a non-negative integer")
}
if (!is.finite(rsvd_power) || rsvd_power < 0L) {
  stop("--rsvd-power must be a non-negative integer")
}
if (!length(rsvd_seeds)) {
  stop("--rsvd-seeds must contain at least one non-negative integer")
}
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

tolerance <- list(
  prediction_relative_error = 1e-4,
  coefficient_relative_error = 1e-3,
  subspace_angle_degrees = 0.1,
  classification_label_agreement = 0.995,
  regression_metric_absolute_difference = 1e-4,
  classification_accuracy_absolute_difference = 0.005,
  rsvd_prediction_relative_error = 0.01,
  rsvd_prediction_correlation = 0.995,
  rsvd_subspace_angle_degrees = 0.1,
  rsvd_classification_label_agreement = 0.995,
  rsvd_metric_absolute_difference = 0.005
)

with_validation_env <- function(code) {
  keys <- c(
    "FASTPLS_FAST_OPTIMIZED",
    "FASTPLS_FAST_DEFLCACHE",
    "FASTPLS_RETURN_TTRAIN"
  )
  old <- Sys.getenv(keys, unset = NA_character_)
  on.exit({
    for (i in seq_along(keys)) {
      if (is.na(old[[i]])) {
        Sys.unsetenv(keys[[i]])
      } else {
        do.call(Sys.setenv, setNames(list(old[[i]]), keys[[i]]))
      }
    }
  }, add = TRUE)
  Sys.setenv(
    FASTPLS_FAST_OPTIMIZED = "1",
    FASTPLS_FAST_DEFLCACHE = "1",
    FASTPLS_RETURN_TTRAIN = "1"
  )
  force(code)
}

one_hot <- function(labels) {
  labels <- factor(labels)
  out <- matrix(
    0,
    nrow = length(labels),
    ncol = nlevels(labels),
    dimnames = list(NULL, levels(labels))
  )
  out[cbind(seq_along(labels), as.integer(labels))] <- 1
  out
}

safe_rank <- function(x, tol = 1e-10) {
  qr(as.matrix(x), tol = tol)$rank
}

principal_angles_degrees <- function(a, b, tol = 1e-10) {
  a <- as.matrix(a)
  b <- as.matrix(b)
  qa_fit <- qr(a, tol = tol)
  qb_fit <- qr(b, tol = tol)
  rank_a <- qa_fit$rank
  rank_b <- qb_fit$rank
  if (!rank_a || !rank_b) {
    return(list(angles = 90, rank_a = rank_a, rank_b = rank_b))
  }
  qa <- qr.Q(qa_fit)[, seq_len(rank_a), drop = FALSE]
  qb <- qr.Q(qb_fit)[, seq_len(rank_b), drop = FALSE]
  singular <- svd(crossprod(qa, qb), nu = 0L, nv = 0L)$d
  angles <- acos(pmin(1, pmax(-1, singular))) * 180 / pi
  if (rank_a != rank_b) angles <- c(angles, rep(90, abs(rank_a - rank_b)))
  list(angles = angles, rank_a = rank_a, rank_b = rank_b)
}

relative_error <- function(estimate, reference) {
  sqrt(sum((estimate - reference)^2)) /
    max(sqrt(sum(reference^2)), .Machine$double.eps)
}

within_tolerance <- function(value, limit) {
  is.finite(value) &&
    value <= limit + sqrt(.Machine$double.eps) * max(1, abs(limit))
}

safe_correlation <- function(a, b) {
  a <- as.vector(a)
  b <- as.vector(b)
  if (stats::sd(a) == 0 || stats::sd(b) == 0) return(NA_real_)
  stats::cor(a, b)
}

slice_cube <- function(x, index) {
  x[, , index, drop = FALSE][, , 1L]
}

fast_prediction <- function(fit, index, component) {
  value <- fit$Ypred
  if (is.list(value) && !is.data.frame(value)) {
    named <- value[[paste0("ncomp=", component)]]
    if (!is.null(named)) return(as.matrix(named))
    return(as.matrix(value[[index]]))
  }
  if (length(dim(value)) == 3L) return(slice_cube(value, index))
  as.matrix(value)
}

fast_coefficient <- function(fit, index) {
  if (is.null(fit$B)) return(NULL)
  if (length(dim(fit$B)) == 3L) return(slice_cube(fit$B, index))
  as.matrix(fit$B)
}

reference_prediction <- function(fit, x, component) {
  coefficient <- slice_cube(fit$coefficients, component)
  centered <- sweep(x, 2L, fit$Xmeans, "-")
  sweep(centered %*% coefficient, 2L, fit$Ymeans, "+")
}

prediction_metric <- function(task_type, prediction, truth, labels = NULL) {
  if (identical(task_type, "classification")) {
    decoded <- max.col(prediction, ties.method = "first")
    return(mean(decoded == as.integer(labels)))
  }
  sqrt(mean((prediction - truth)^2))
}

standardize_train_test <- function(xtrain, xtest) {
  center <- colMeans(xtrain)
  scale <- apply(xtrain, 2L, stats::sd)
  scale[!is.finite(scale) | scale == 0] <- 1
  list(
    train = sweep(sweep(xtrain, 2L, center, "-"), 2L, scale, "/"),
    test = sweep(sweep(xtest, 2L, center, "-"), 2L, scale, "/")
  )
}

make_synthetic_regression <- function(
  name,
  seed,
  n_train,
  n_test,
  p,
  q,
  latent_rank,
  ill_conditioned = FALSE,
  rank_deficient = FALSE
) {
  set.seed(seed)
  n <- n_train + n_test
  latent <- matrix(rnorm(n * latent_rank), n, latent_rank)
  x_loading <- matrix(rnorm(p * latent_rank), p, latent_rank)
  y_loading <- matrix(rnorm(q * latent_rank), q, latent_rank)
  if (ill_conditioned && p >= 6L) {
    x_loading[, 2L] <- x_loading[, 1L] + rnorm(p, sd = 1e-7)
    x_loading[, 3L] <- x_loading[, 1L] - x_loading[, 2L] +
      rnorm(p, sd = 1e-7)
  }
  x <- latent %*% t(x_loading) + matrix(rnorm(n * p, sd = 0.05), n, p)
  if (rank_deficient && p >= 20L) {
    x[, (p - 9L):p] <- x[, 1:10, drop = FALSE]
  }
  y <- latent %*% t(y_loading) + matrix(rnorm(n * q, sd = 0.05), n, q)
  max_component <- min(10L, n_train - 2L, p)
  list(
    dataset = name,
    source = "synthetic",
    task_type = "regression",
    condition = if (ill_conditioned) "ill_conditioned" else if (rank_deficient) "rank_deficient" else "well_conditioned",
    Xtrain = x[seq_len(n_train), , drop = FALSE],
    Ytrain = y[seq_len(n_train), , drop = FALSE],
    Xtest = x[n_train + seq_len(n_test), , drop = FALSE],
    Ytest = y[n_train + seq_len(n_test), , drop = FALSE],
    labels_train = NULL,
    labels_test = NULL,
    ncomp_grid = unique(pmax(1L, round(seq(2L, max_component, length.out = min(4L, max_component))))),
    seed = seed
  )
}

make_synthetic_classification <- function(
  name,
  seed,
  n_train,
  n_test,
  p,
  classes,
  latent_rank,
  ill_conditioned = FALSE
) {
  set.seed(seed)
  n <- n_train + n_test
  labels <- factor(rep(seq_len(classes), length.out = n))
  labels <- factor(sample(labels), levels = levels(labels))
  prototypes <- matrix(rnorm(classes * latent_rank), classes, latent_rank)
  latent <- prototypes[as.integer(labels), , drop = FALSE] +
    matrix(rnorm(n * latent_rank, sd = 0.45), n, latent_rank)
  loading <- matrix(rnorm(p * latent_rank), p, latent_rank)
  if (ill_conditioned && p >= 6L) {
    loading[, 2L] <- loading[, 1L] + rnorm(p, sd = 1e-7)
    loading[, 3L] <- loading[, 1L] - loading[, 2L] +
      rnorm(p, sd = 1e-7)
  }
  x <- latent %*% t(loading) + matrix(rnorm(n * p, sd = 0.08), n, p)
  y <- one_hot(labels)
  max_component <- min(10L, classes - 1L, n_train - 2L, p)
  list(
    dataset = name,
    source = "synthetic",
    task_type = "classification",
    condition = if (ill_conditioned) "ill_conditioned" else "well_conditioned",
    Xtrain = x[seq_len(n_train), , drop = FALSE],
    Ytrain = y[seq_len(n_train), , drop = FALSE],
    Xtest = x[n_train + seq_len(n_test), , drop = FALSE],
    Ytest = y[n_train + seq_len(n_test), , drop = FALSE],
    labels_train = labels[seq_len(n_train)],
    labels_test = labels[n_train + seq_len(n_test)],
    ncomp_grid = unique(pmax(1L, round(seq(1L, max_component, length.out = min(5L, max_component))))),
    seed = seed
  )
}

prepare_breast <- function() {
  env <- new.env(parent = emptyenv())
  load(file.path(root, "data", "breast.rda"), envir = env)
  data <- env$breast
  labels <- factor(c(data$y_train, data$y_test))
  list(
    dataset = "Breast",
    source = "real",
    task_type = "classification",
    condition = "p_greater_than_n",
    Xtrain = as.matrix(data$X_train),
    Ytrain = one_hot(labels)[seq_along(data$y_train), , drop = FALSE],
    Xtest = as.matrix(data$X_test),
    Ytest = one_hot(labels)[length(data$y_train) + seq_along(data$y_test), , drop = FALSE],
    labels_train = factor(data$y_train, levels = levels(labels)),
    labels_test = factor(data$y_test, levels = levels(labels)),
    ncomp_grid = c(1L, 2L, 3L, 5L, 8L),
    seed = 123L
  )
}

prepare_colon <- function() {
  env <- new.env(parent = emptyenv())
  load(file.path(root, "data", "colon.rda"), envir = env)
  data <- env$colon
  x <- log2(as.matrix(data$X) + 1)
  labels <- factor(data$y)
  set.seed(123L)
  test <- unlist(
    lapply(split(seq_len(nrow(x)), labels), function(index) {
      sample(index, max(2L, floor(length(index) * 0.25)))
    }),
    use.names = FALSE
  )
  train <- setdiff(seq_len(nrow(x)), test)
  scaled <- standardize_train_test(x[train, , drop = FALSE], x[test, , drop = FALSE])
  encoded <- one_hot(labels)
  list(
    dataset = "Colon",
    source = "real",
    task_type = "classification",
    condition = "p_much_greater_than_n",
    Xtrain = scaled$train,
    Ytrain = encoded[train, , drop = FALSE],
    Xtest = scaled$test,
    Ytest = encoded[test, , drop = FALSE],
    labels_train = labels[train],
    labels_test = labels[test],
    ncomp_grid = c(1L, 2L, 3L, 5L, 8L),
    seed = 123L
  )
}

prepare_metref <- function() {
  if (!requireNamespace("KODAMA", quietly = TRUE)) return(NULL)
  data("MetRef", package = "KODAMA", envir = environment())
  x <- MetRef$data
  x <- x[, colSums(x) != 0, drop = FALSE]
  x <- KODAMA::normalization(x)$newXtrain
  x <- KODAMA::scaling(x)$newXtrain
  labels <- factor(MetRef$donor)
  set.seed(123L)
  test <- sample(seq_len(nrow(x)), min(100L, floor(nrow(x) / 5L)))
  train <- setdiff(seq_len(nrow(x)), test)
  encoded <- one_hot(labels)
  list(
    dataset = "MetRef",
    source = "real",
    task_type = "classification",
    condition = "p_less_than_n_multiclass",
    Xtrain = as.matrix(x[train, , drop = FALSE]),
    Ytrain = encoded[train, , drop = FALSE],
    Xtest = as.matrix(x[test, , drop = FALSE]),
    Ytest = encoded[test, , drop = FALSE],
    labels_train = labels[train],
    labels_test = labels[test],
    ncomp_grid = c(2L, 5L, 10L, 18L),
    seed = 123L
  )
}

prepare_nmr_subset <- function() {
  if (!file.exists(nmr_path)) return(NULL)
  protocol <- fastpls_nmr_protocol(nmr_path)
  xtrain <- protocol$Xtrain
  ytrain <- protocol$Ytrain
  xtest <- protocol$Xtest
  ytest <- protocol$Ytest

  # Retain the canonical zeroed water-region columns when subsampling predictors.
  x_index <- unique(round(seq(1L, ncol(xtrain), length.out = 300L)))
  y_index <- unique(round(seq(1L, ncol(ytrain), length.out = 120L)))
  train_index <- seq_len(min(600L, nrow(xtrain)))
  test_index <- seq_len(min(150L, nrow(xtest)))
  list(
    dataset = "NMR_spectral_subset",
    source = "real",
    task_type = "regression",
    condition = "p_less_than_n_high_rank_response",
    Xtrain = xtrain[train_index, x_index, drop = FALSE],
    Ytrain = ytrain[train_index, y_index, drop = FALSE],
    Xtest = xtest[test_index, x_index, drop = FALSE],
    Ytest = ytest[test_index, y_index, drop = FALSE],
    labels_train = NULL,
    labels_test = NULL,
    ncomp_grid = c(2L, 5L, 10L, 15L),
    seed = 123L
  )
}

synthetic_seeds <- if (quick) 101L else c(101L, 202L, 303L)
tasks <- list()
for (seed in synthetic_seeds) {
  tasks <- c(tasks, list(
    make_synthetic_regression(
      "syn_reg_p_lt_n_low_q", seed, 240L, 80L, 40L, 5L, 3L
    ),
    make_synthetic_regression(
      "syn_reg_p_gt_n", seed, 80L, 40L, 300L, 6L, 4L
    ),
    make_synthetic_regression(
      "syn_reg_high_rank_y", seed, 180L, 60L, 90L, 40L, 20L
    ),
    make_synthetic_regression(
      "syn_reg_ill_conditioned", seed, 180L, 60L, 80L, 8L, 5L,
      ill_conditioned = TRUE
    ),
    make_synthetic_regression(
      "syn_reg_rank_deficient", seed, 150L, 50L, 100L, 8L, 5L,
      rank_deficient = TRUE
    ),
    make_synthetic_classification(
      "syn_cls_p_lt_n_low_rank", seed, 300L, 100L, 40L, 4L, 3L
    ),
    make_synthetic_classification(
      "syn_cls_p_gt_n_high_rank", seed, 120L, 60L, 300L, 12L, 11L
    ),
    make_synthetic_classification(
      "syn_cls_ill_conditioned", seed, 180L, 60L, 120L, 6L, 5L,
      ill_conditioned = TRUE
    )
  ))
}
real_tasks <- list(
  prepare_breast(),
  prepare_colon(),
  prepare_metref(),
  prepare_nmr_subset()
)
tasks <- c(tasks, Filter(Negate(is.null), real_tasks))

task_manifest <- do.call(rbind, lapply(tasks, function(task) {
  centered_y <- sweep(task$Ytrain, 2L, colMeans(task$Ytrain), "-")
  centered_x <- sweep(task$Xtrain, 2L, colMeans(task$Xtrain), "-")
  data.frame(
    dataset = task$dataset,
    source = task$source,
    task_type = task$task_type,
    condition = task$condition,
    seed = task$seed,
    n_train = nrow(task$Xtrain),
    n_test = nrow(task$Xtest),
    p = ncol(task$Xtrain),
    q = ncol(task$Ytrain),
    x_rank = safe_rank(centered_x),
    response_rank = safe_rank(centered_y),
    coefficient_identifiable = safe_rank(centered_x) == ncol(centered_x),
    ncomp_grid = paste(task$ncomp_grid, collapse = ";"),
    stringsAsFactors = FALSE
  )
}))

fit_pair <- function(task, solver, randomized_seed = task$seed) {
  grid <- sort(unique(as.integer(task$ncomp_grid)))
  max_component <- max(grid)
  fast_time <- system.time({
    fast <- with_validation_env(fastPLS::pls(
      Xtrain = task$Xtrain,
      Ytrain = task$Ytrain,
      Xtest = task$Xtest,
      Ytest = task$Ytest,
      ncomp = grid,
      method = "simpls",
      backend = "cpu",
      svd.method = solver,
      oversample = rsvd_oversample,
      power = rsvd_power,
      scaling = "centering",
      fit = TRUE,
      return_variance = FALSE,
      return_loadings = TRUE,
      seed = randomized_seed
    ))
  })[["elapsed"]]
  reference_time <- system.time({
    reference <- pls::simpls.fit(
      task$Xtrain,
      task$Ytrain,
      ncomp = max_component,
      center = TRUE
    )
  })[["elapsed"]]
  list(
    fast = fast,
    reference = reference,
    fast_time = fast_time,
    reference_time = reference_time
  )
}

evaluate_pair <- function(task, pair, solver, randomized_seed = NA_integer_) {
  grid <- sort(unique(as.integer(task$ncomp_grid)))
  identifiable <- safe_rank(
    sweep(task$Xtrain, 2L, colMeans(task$Xtrain), "-")
  ) == ncol(task$Xtrain)
  rows <- vector("list", length(grid))
  for (i in seq_along(grid)) {
    component <- grid[[i]]
    fast_pred <- fast_prediction(pair$fast, i, component)
    ref_pred <- reference_prediction(pair$reference, task$Xtest, component)
    fast_b <- fast_coefficient(pair$fast, i)
    ref_b <- slice_cube(pair$reference$coefficients, component)
    score_angle <- principal_angles_degrees(
      pair$fast$Ttrain[, seq_len(component), drop = FALSE],
      pair$reference$scores[, seq_len(component), drop = FALSE]
    )
    projection_angle <- principal_angles_degrees(
      pair$fast$R[, seq_len(component), drop = FALSE],
      pair$reference$projection[, seq_len(component), drop = FALSE]
    )
    loading_angle <- principal_angles_degrees(
      pair$fast$P[, seq_len(component), drop = FALSE],
      pair$reference$loadings[, seq_len(component), drop = FALSE]
    )
    fast_metric <- prediction_metric(
      task$task_type,
      fast_pred,
      task$Ytest,
      task$labels_test
    )
    reference_metric <- prediction_metric(
      task$task_type,
      ref_pred,
      task$Ytest,
      task$labels_test
    )
    label_agreement <- NA_real_
    if (identical(task$task_type, "classification")) {
      label_agreement <- mean(
        max.col(fast_pred, ties.method = "first") ==
          max.col(ref_pred, ties.method = "first")
      )
    }
    pred_error <- relative_error(fast_pred, ref_pred)
    coef_error <- if (is.null(fast_b)) NA_real_ else relative_error(fast_b, ref_b)
    metric_difference <- abs(fast_metric - reference_metric)
    endpoint_pass <- within_tolerance(pred_error, tolerance$prediction_relative_error) &&
      (!identifiable || is.na(coef_error) ||
        within_tolerance(coef_error, tolerance$coefficient_relative_error)) &&
      within_tolerance(max(score_angle$angles), tolerance$subspace_angle_degrees) &&
      within_tolerance(max(projection_angle$angles), tolerance$subspace_angle_degrees) &&
      within_tolerance(max(loading_angle$angles), tolerance$subspace_angle_degrees) &&
      if (identical(task$task_type, "classification")) {
        label_agreement >= tolerance$classification_label_agreement &&
          within_tolerance(
            metric_difference,
            tolerance$classification_accuracy_absolute_difference
          )
      } else {
        within_tolerance(
          metric_difference,
          tolerance$regression_metric_absolute_difference
        )
      }
    approximation_pass <- within_tolerance(
        pred_error,
        tolerance$rsvd_prediction_relative_error
      ) &&
      safe_correlation(fast_pred, ref_pred) >= tolerance$rsvd_prediction_correlation &&
      within_tolerance(
        max(score_angle$angles),
        tolerance$rsvd_subspace_angle_degrees
      ) &&
      within_tolerance(
        max(projection_angle$angles),
        tolerance$rsvd_subspace_angle_degrees
      ) &&
      within_tolerance(
        max(loading_angle$angles),
        tolerance$rsvd_subspace_angle_degrees
      ) &&
      within_tolerance(metric_difference, tolerance$rsvd_metric_absolute_difference) &&
      if (identical(task$task_type, "classification")) {
        label_agreement >= tolerance$rsvd_classification_label_agreement
      } else {
        TRUE
      }
    row_status <- if (identical(solver, "rsvd") && !approximation_pass) {
      "failed_approximation_criteria"
    } else {
      "ok"
    }
    rows[[i]] <- data.frame(
      dataset = task$dataset,
      source = task$source,
      task_type = task$task_type,
      condition = task$condition,
      seed = task$seed,
      solver = solver,
      randomized_seed = if (identical(solver, "rsvd")) randomized_seed else NA_integer_,
      rsvd_oversample = if (identical(solver, "rsvd")) rsvd_oversample else NA_integer_,
      rsvd_power = if (identical(solver, "rsvd")) rsvd_power else NA_integer_,
      n_train = nrow(task$Xtrain),
      n_test = nrow(task$Xtest),
      p = ncol(task$Xtrain),
      q = ncol(task$Ytrain),
      response_rank = safe_rank(sweep(task$Ytrain, 2L, colMeans(task$Ytrain), "-")),
      ncomp = component,
      coefficient_identifiable = identifiable,
      fastpls_elapsed_sec = pair$fast_time,
      reference_elapsed_sec = pair$reference_time,
      prediction_correlation = safe_correlation(fast_pred, ref_pred),
      prediction_relative_error = pred_error,
      prediction_max_absolute_error = max(abs(fast_pred - ref_pred)),
      coefficient_relative_error = coef_error,
      score_subspace_max_angle_degrees = max(score_angle$angles),
      projection_subspace_max_angle_degrees = max(projection_angle$angles),
      loading_subspace_max_angle_degrees = max(loading_angle$angles),
      fastpls_metric = fast_metric,
      reference_metric = reference_metric,
      metric_absolute_difference = metric_difference,
      classification_label_agreement = label_agreement,
      deterministic_tolerance_pass = if (identical(solver, "irlba")) endpoint_pass else NA,
      approximation_tolerance_pass = if (identical(solver, "rsvd")) approximation_pass else NA,
      status = row_status,
      error_message = "",
      stringsAsFactors = FALSE
    )
  }
  do.call(rbind, rows)
}

make_folds <- function(task, folds = 5L) {
  set.seed(task$seed + 9000L)
  n <- nrow(task$Xtrain)
  assignment <- integer(n)
  if (identical(task$task_type, "classification")) {
    for (level in levels(task$labels_train)) {
      index <- sample(which(task$labels_train == level))
      assignment[index] <- rep(seq_len(folds), length.out = length(index))
    }
  } else {
    index <- sample(seq_len(n))
    assignment[index] <- rep(seq_len(folds), length.out = n)
  }
  assignment
}

cv_selection <- function(task, solver, randomized_seed = task$seed, folds = 5L) {
  grid <- sort(unique(as.integer(task$ncomp_grid)))
  fold_id <- make_folds(task, folds)
  fast_values <- matrix(NA_real_, folds, length(grid))
  ref_values <- matrix(NA_real_, folds, length(grid))
  for (fold in seq_len(folds)) {
    validation <- which(fold_id == fold)
    training <- which(fold_id != fold)
    fold_task <- task
    fold_task$Xtrain <- task$Xtrain[training, , drop = FALSE]
    fold_task$Ytrain <- task$Ytrain[training, , drop = FALSE]
    fold_task$Xtest <- task$Xtrain[validation, , drop = FALSE]
    fold_task$Ytest <- task$Ytrain[validation, , drop = FALSE]
    if (identical(task$task_type, "classification")) {
      fold_task$labels_train <- droplevels(task$labels_train[training])
      fold_task$labels_test <- factor(
        task$labels_train[validation],
        levels = levels(task$labels_train)
      )
    }
    pair <- fit_pair(fold_task, solver, randomized_seed)
    for (i in seq_along(grid)) {
      component <- grid[[i]]
      fast_pred <- fast_prediction(pair$fast, i, component)
      ref_pred <- reference_prediction(pair$reference, fold_task$Xtest, component)
      fast_values[fold, i] <- prediction_metric(
        task$task_type,
        fast_pred,
        fold_task$Ytest,
        fold_task$labels_test
      )
      ref_values[fold, i] <- prediction_metric(
        task$task_type,
        ref_pred,
        fold_task$Ytest,
        fold_task$labels_test
      )
    }
  }
  fast_curve <- colMeans(fast_values)
  ref_curve <- colMeans(ref_values)
  choose <- if (identical(task$task_type, "classification")) {
    function(x) which.max(x)
  } else {
    function(x) which.min(x)
  }
  fast_index <- choose(fast_curve)
  ref_index <- choose(ref_curve)
  list(
    summary = data.frame(
      dataset = task$dataset,
      source = task$source,
      task_type = task$task_type,
      condition = task$condition,
      seed = task$seed,
      solver = solver,
      randomized_seed = if (identical(solver, "rsvd")) randomized_seed else NA_integer_,
      rsvd_oversample = if (identical(solver, "rsvd")) rsvd_oversample else NA_integer_,
      rsvd_power = if (identical(solver, "rsvd")) rsvd_power else NA_integer_,
      folds = folds,
      fastpls_selected_ncomp = grid[[fast_index]],
      reference_selected_ncomp = grid[[ref_index]],
      selected_component_agreement = grid[[fast_index]] == grid[[ref_index]],
      maximum_cv_curve_absolute_difference = max(abs(fast_curve - ref_curve)),
      fastpls_selected_metric = fast_curve[[fast_index]],
      reference_selected_metric = ref_curve[[ref_index]],
      status = "ok",
      error_message = "",
      stringsAsFactors = FALSE
    ),
    curve = data.frame(
      dataset = task$dataset,
      source = task$source,
      task_type = task$task_type,
      condition = task$condition,
      seed = task$seed,
      solver = solver,
      randomized_seed = if (identical(solver, "rsvd")) randomized_seed else NA_integer_,
      rsvd_oversample = if (identical(solver, "rsvd")) rsvd_oversample else NA_integer_,
      rsvd_power = if (identical(solver, "rsvd")) rsvd_power else NA_integer_,
      ncomp = grid,
      fastpls_cv_metric = fast_curve,
      reference_cv_metric = ref_curve,
      stringsAsFactors = FALSE
    )
  )
}

endpoint_rows <- list()
failure_rows <- list()
cv_rows <- list()
cv_curve_rows <- list()
endpoint_index <- failure_index <- cv_index <- cv_curve_index <- 1L
solver_runs <- c(
  list(list(solver = "irlba", randomized_seed = NA_integer_)),
  lapply(rsvd_seeds, function(value) {
    list(solver = "rsvd", randomized_seed = value)
  })
)

for (task in tasks) {
  run_cv <- identical(task$source, "real") ||
    identical(task$seed, synthetic_seeds[[1L]])
  for (solver_run in solver_runs) {
    solver <- solver_run$solver
    randomized_seed <- solver_run$randomized_seed
    message(
      sprintf(
        "[%s] dataset=%s solver=%s randomized_seed=%s n=%d p=%d q=%d",
        format(Sys.time(), "%Y-%m-%d %H:%M:%S"),
        task$dataset,
        solver,
        if (is.na(randomized_seed)) "NA" else randomized_seed,
        nrow(task$Xtrain),
        ncol(task$Xtrain),
        ncol(task$Ytrain)
      )
    )
    endpoint <- tryCatch({
      pair <- fit_pair(task, solver, randomized_seed)
      evaluate_pair(task, pair, solver, randomized_seed)
    }, error = function(error) error)
    if (inherits(endpoint, "error")) {
      failure_rows[[failure_index]] <- data.frame(
        stage = "endpoint",
        dataset = task$dataset,
        source = task$source,
        task_type = task$task_type,
        condition = task$condition,
        seed = task$seed,
        solver = solver,
        randomized_seed = randomized_seed,
        error_message = conditionMessage(endpoint),
        stringsAsFactors = FALSE
      )
      failure_index <- failure_index + 1L
    } else {
      endpoint_rows[[endpoint_index]] <- endpoint
      endpoint_index <- endpoint_index + 1L
    }
    if (run_cv) {
      cv <- tryCatch(
        cv_selection(task, solver, randomized_seed),
        error = function(error) error
      )
      if (inherits(cv, "error")) {
        failure_rows[[failure_index]] <- data.frame(
          stage = "cross_validation",
          dataset = task$dataset,
          source = task$source,
          task_type = task$task_type,
          condition = task$condition,
          seed = task$seed,
          solver = solver,
          randomized_seed = randomized_seed,
          error_message = conditionMessage(cv),
          stringsAsFactors = FALSE
        )
        failure_index <- failure_index + 1L
      } else {
        cv_rows[[cv_index]] <- cv$summary
        cv_index <- cv_index + 1L
        cv_curve_rows[[cv_curve_index]] <- cv$curve
        cv_curve_index <- cv_curve_index + 1L
      }
    }
  }
}

empty_or_bind <- function(rows, prototype = NULL) {
  if (length(rows)) return(do.call(rbind, rows))
  if (is.null(prototype)) return(data.frame())
  prototype[FALSE, , drop = FALSE]
}

endpoints <- empty_or_bind(endpoint_rows)
failures <- empty_or_bind(failure_rows)
cv_results <- empty_or_bind(cv_rows)
cv_curves <- empty_or_bind(cv_curve_rows)
release_version <- as.character(utils::packageVersion("fastPLS"))
release_sha256 <- Sys.getenv("FASTPLS_SOURCE_ARCHIVE_SHA256", unset = NA_character_)
attach_release <- function(x) {
  x$package_version <- rep(release_version, nrow(x))
  x$source_archive_sha256 <- rep(release_sha256, nrow(x))
  x
}
task_manifest <- attach_release(task_manifest)
endpoints <- attach_release(endpoints)
failures <- attach_release(failures)
cv_results <- attach_release(cv_results)
cv_curves <- attach_release(cv_curves)
if (!nrow(failures)) {
  failures <- data.frame(
    stage = character(),
    dataset = character(),
    source = character(),
    task_type = character(),
    condition = character(),
    seed = integer(),
    solver = character(),
    randomized_seed = integer(),
    error_message = character(),
    package_version = character(),
    source_archive_sha256 = character(),
    stringsAsFactors = FALSE
  )
}

deterministic <- endpoints[endpoints$solver == "irlba", , drop = FALSE]
approximate <- endpoints[endpoints$solver == "rsvd", , drop = FALSE]

deterministic_summary <- if (nrow(deterministic)) {
  aggregate(
    cbind(
      prediction_relative_error,
      coefficient_relative_error,
      score_subspace_max_angle_degrees,
      projection_subspace_max_angle_degrees,
      loading_subspace_max_angle_degrees,
      metric_absolute_difference
    ) ~ source + task_type,
    data = deterministic,
    FUN = function(x) max(x, na.rm = TRUE)
  )
} else {
  data.frame()
}

validation_summary <- data.frame(
  package_version = release_version,
  source_archive_sha256 = release_sha256,
  endpoint_runs = length(tasks) * length(solver_runs),
  endpoint_failures = sum(failures$stage == "endpoint"),
  cv_runs = sum(vapply(tasks, function(task) {
    identical(task$source, "real") ||
      identical(task$seed, synthetic_seeds[[1L]])
  }, logical(1))) * length(solver_runs),
  cv_failures = sum(failures$stage == "cross_validation"),
  deterministic_endpoint_rows = nrow(deterministic),
  deterministic_endpoint_tolerance_passes = sum(
    deterministic$deterministic_tolerance_pass,
    na.rm = TRUE
  ),
  deterministic_endpoint_tolerance_failures = sum(
    !deterministic$deterministic_tolerance_pass,
    na.rm = TRUE
  ),
  rsvd_endpoint_rows = nrow(approximate),
  rsvd_approximation_passes = sum(
    approximate$approximation_tolerance_pass,
    na.rm = TRUE
  ),
  rsvd_approximation_failures = sum(
    !approximate$approximation_tolerance_pass,
    na.rm = TRUE
  ),
  deterministic_cv_selection_agreement = if (nrow(cv_results)) {
    mean(
      cv_results$selected_component_agreement[cv_results$solver == "irlba"],
      na.rm = TRUE
    )
  } else {
    NA_real_
  }
)

rsvd_seed_summary <- if (nrow(approximate)) {
  do.call(rbind, lapply(split(approximate, approximate$randomized_seed), function(x) {
    data.frame(
      randomized_seed = unique(x$randomized_seed)[1L],
      rows = nrow(x),
      passes = sum(x$approximation_tolerance_pass, na.rm = TRUE),
      failures = sum(!x$approximation_tolerance_pass, na.rm = TRUE),
      maximum_prediction_relative_error = max(x$prediction_relative_error, na.rm = TRUE),
      minimum_prediction_correlation = min(x$prediction_correlation, na.rm = TRUE),
      minimum_classification_label_agreement = if (all(is.na(x$classification_label_agreement))) {
        NA_real_
      } else {
        min(x$classification_label_agreement, na.rm = TRUE)
      },
      maximum_metric_absolute_difference = max(x$metric_absolute_difference, na.rm = TRUE),
      stringsAsFactors = FALSE
    )
  }))
} else {
  data.frame()
}

utils::write.csv(
  task_manifest,
  file.path(out_dir, "simpls_estimator_preservation_task_manifest.csv"),
  row.names = FALSE
)
utils::write.csv(
  endpoints,
  file.path(out_dir, "simpls_estimator_preservation_all_endpoints.csv"),
  row.names = FALSE
)
utils::write.csv(
  deterministic,
  file.path(out_dir, "simpls_estimator_preservation_irlba.csv"),
  row.names = FALSE
)
utils::write.csv(
  approximate,
  file.path(out_dir, "simpls_estimator_approximation_rsvd.csv"),
  row.names = FALSE
)
utils::write.csv(
  cv_results,
  file.path(out_dir, "simpls_estimator_preservation_cv_selection.csv"),
  row.names = FALSE
)
utils::write.csv(
  cv_curves,
  file.path(out_dir, "simpls_estimator_preservation_cv_curves.csv"),
  row.names = FALSE
)
utils::write.csv(
  failures,
  file.path(out_dir, "simpls_estimator_preservation_failures.csv"),
  row.names = FALSE
)
utils::write.csv(
  deterministic_summary,
  file.path(out_dir, "simpls_estimator_preservation_summary.csv"),
  row.names = FALSE
)
utils::write.csv(
  validation_summary,
  file.path(out_dir, "simpls_estimator_preservation_validation_summary.csv"),
  row.names = FALSE
)
utils::write.csv(
  rsvd_seed_summary,
  file.path(out_dir, "simpls_estimator_rsvd_seed_summary.csv"),
  row.names = FALSE
)

saveRDS(
  list(
    tolerance = tolerance,
    task_manifest = task_manifest,
    endpoints = endpoints,
    deterministic = deterministic,
    approximate = approximate,
    rsvd_seed_summary = rsvd_seed_summary,
    cv_results = cv_results,
    cv_curves = cv_curves,
    failures = failures,
    session = utils::sessionInfo()
  ),
  file.path(out_dir, "simpls_estimator_preservation_results.rds")
)

writeLines(
  c(
    "# SIMPLS estimator-preservation validation",
    "",
    "The deterministic IRLBA and approximate rSVD results are intentionally separated.",
    "",
    "## Prespecified deterministic tolerances",
    sprintf("- Relative prediction error <= %.1e", tolerance$prediction_relative_error),
    sprintf("- Relative coefficient error <= %.1e where X has full column rank", tolerance$coefficient_relative_error),
    sprintf("- Maximum score, projection, and loading subspace angle <= %.3f degrees", tolerance$subspace_angle_degrees),
    sprintf("- Classification label agreement >= %.3f", tolerance$classification_label_agreement),
    sprintf("- Classification accuracy difference <= %.3f", tolerance$classification_accuracy_absolute_difference),
    sprintf("- Regression RMSD difference <= %.1e", tolerance$regression_metric_absolute_difference),
    "- Cross-validation selected-component agreement is reported exactly.",
    "",
    "## Prespecified rSVD approximation criteria",
    sprintf("- Relative prediction error <= %.2f", tolerance$rsvd_prediction_relative_error),
    sprintf("- Prediction correlation >= %.2f", tolerance$rsvd_prediction_correlation),
    sprintf("- Maximum score, projection, and loading subspace angle <= %.1f degrees", tolerance$rsvd_subspace_angle_degrees),
    sprintf("- Classification label agreement >= %.2f", tolerance$rsvd_classification_label_agreement),
    sprintf("- Predictive-metric difference <= %.2f", tolerance$rsvd_metric_absolute_difference),
    "- An rSVD row that violates any criterion is labelled failed_approximation_criteria.",
    "",
    "## Aggregate results",
    paste(capture.output(print(validation_summary, row.names = FALSE)), collapse = "\n"),
    "",
    "## rSVD variability across prespecified seeds",
    paste(capture.output(print(rsvd_seed_summary, row.names = FALSE)), collapse = "\n"),
    "",
    "## Interpretation",
    "IRLBA rows test the estimator-preservation claim against pls::simpls.fit.",
    "rSVD rows characterize an explicitly approximate direction solver and are not used as equivalence evidence.",
    "IRLBA is preferred for confirmatory inference, ill-conditioned or rank-deficient data, slowly decaying singular spectra, and any task that fails the rSVD approximation criteria."
  ),
  file.path(out_dir, "SIMPLS_ESTIMATOR_PRESERVATION_REPORT.md")
)

capture.output(
  utils::sessionInfo(),
  file = file.path(out_dir, "session_info.txt")
)

print(validation_summary)
if (nrow(deterministic_summary)) print(deterministic_summary)
if (nrow(failures)) print(failures)
cat("Results: ", normalizePath(out_dir, winslash = "/", mustWork = FALSE), "\n", sep = "")
