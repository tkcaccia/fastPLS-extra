#!/usr/bin/env Rscript

# Independent estimator validation for fastPLS OPLS and nonlinear kernel PLS.
# The reference code below does not call fastPLS filtering or kernel helpers.
# Predictive PLS fits use pls::simpls.fit (de Jong SIMPLS).

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
out_dir <- get_arg(
  "out",
  file.path(Sys.getenv("FASTPLS_RESULTS_ROOT"),
            "opls_kernel_estimator_validation")
)
if (!nzchar(Sys.getenv("FASTPLS_RESULTS_ROOT")) &&
    !any(startsWith(args, "--out="))) {
  stop("Set --out or FASTPLS_RESULTS_ROOT.", call. = FALSE)
}
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

seed <- 123L
set.seed(seed)

one_hot <- function(y, levels = levels(factor(y))) {
  y <- factor(y, levels = levels)
  ans <- matrix(0, nrow = length(y), ncol = length(levels))
  ans[cbind(seq_along(y), as.integer(y))] <- 1
  colnames(ans) <- levels
  ans
}

relative_error <- function(x, reference) {
  sqrt(sum((x - reference)^2)) /
    max(sqrt(sum(reference^2)), .Machine$double.eps)
}

safe_cor <- function(x, y) {
  x <- as.vector(x)
  y <- as.vector(y)
  if (length(x) < 2L || sd(x) == 0 || sd(y) == 0) return(NA_real_)
  cor(x, y)
}

principal_angles <- function(x, y, tol = 1e-10) {
  x <- as.matrix(x)
  y <- as.matrix(y)
  qx <- qr(x, tol = tol)
  qy <- qr(y, tol = tol)
  rx <- qx$rank
  ry <- qy$rank
  if (!rx || !ry) return(c(90, rep(NA_real_, max(rx, ry) - 1L)))
  ux <- qr.Q(qx)[, seq_len(rx), drop = FALSE]
  uy <- qr.Q(qy)[, seq_len(ry), drop = FALSE]
  d <- svd(crossprod(ux, uy), nu = 0L, nv = 0L)$d
  angle <- acos(pmin(1, pmax(-1, d))) * 180 / pi
  if (rx != ry) angle <- c(angle, rep(90, abs(rx - ry)))
  angle
}

matrix_from_compact <- function(x) {
  if (is.null(x)) return(NULL)
  if (length(dim(x)) == 3L) return(x[, , dim(x)[3L], drop = FALSE][, , 1L])
  as.matrix(x)
}

raw_prediction_from_inner <- function(inner, model_x) {
  coefficient <- matrix_from_compact(inner$B)
  sweep(model_x %*% coefficient, 2L, as.numeric(inner$mY), "+")
}

final_prediction <- function(fit) {
  pred <- fit$Ypred
  if (is.list(pred) && !is.data.frame(pred)) return(as.matrix(pred[[length(pred)]]))
  if (length(dim(pred)) == 3L) {
    return(pred[, , dim(pred)[3L], drop = FALSE][, , 1L])
  }
  as.matrix(pred)
}

prepare_xy <- function(case) {
  if (identical(case$task, "classification")) {
    lev <- levels(factor(case$y_train))
    list(
      y_train_matrix = one_hot(case$y_train, lev),
      y_test_matrix = one_hot(case$y_test, lev),
      levels = lev
    )
  } else {
    list(
      y_train_matrix = as.matrix(case$y_train),
      y_test_matrix = as.matrix(case$y_test),
      levels = NULL
    )
  }
}

preprocess_reference <- function(xtrain, xtest, scaling) {
  if (identical(scaling, "none")) {
    center <- rep(0, ncol(xtrain))
    scale <- rep(1, ncol(xtrain))
  } else {
    center <- colMeans(xtrain)
    scale <- if (identical(scaling, "autoscaling")) {
      apply(xtrain, 2L, sd)
    } else {
      rep(1, ncol(xtrain))
    }
    scale[!is.finite(scale) | scale == 0] <- 1
  }
  list(
    train = sweep(sweep(xtrain, 2L, center, "-"), 2L, scale, "/"),
    test = sweep(sweep(xtest, 2L, center, "-"), 2L, scale, "/"),
    center = center,
    scale = scale
  )
}

# Equation-level OPLS filter following the orthogonal signal correction update.
reference_opls_filter <- function(xtrain, xtest, ytrain, north, scaling) {
  prep <- preprocess_reference(xtrain, xtest, scaling)
  xf <- prep$train
  xt <- prep$test
  yc <- sweep(ytrain, 2L, colMeans(ytrain), "-")
  w_orth <- matrix(0, ncol(xf), north)
  p_orth <- matrix(0, ncol(xf), north)
  t_orth <- matrix(0, nrow(xf), north)
  used <- 0L

  for (component in seq_len(north)) {
    s <- crossprod(xf, yc)
    direction <- svd(s, nu = 1L, nv = 0L)$u[, 1L]
    direction <- direction / sqrt(sum(direction^2))
    score <- drop(xf %*% direction)
    loading <- drop(crossprod(xf, score)) / sum(score^2)
    orth_weight <- loading -
      direction * sum(direction * loading) / sum(direction^2)
    orth_weight <- orth_weight / sqrt(sum(orth_weight^2))
    orth_score <- drop(xf %*% orth_weight)
    orth_loading <- drop(crossprod(xf, orth_score)) / sum(orth_score^2)
    xf <- xf - tcrossprod(orth_score, orth_loading)
    xt_score <- drop(xt %*% orth_weight)
    xt <- xt - tcrossprod(xt_score, orth_loading)
    used <- used + 1L
    w_orth[, used] <- orth_weight
    p_orth[, used] <- orth_loading
    t_orth[, used] <- orth_score
  }

  keep <- if (used) seq_len(used) else integer()
  list(
    train = xf,
    test = xt,
    W = w_orth[, keep, drop = FALSE],
    P = p_orth[, keep, drop = FALSE],
    T = t_orth[, keep, drop = FALSE],
    center = prep$center,
    scale = prep$scale
  )
}

filter_operator <- function(w, p) {
  ans <- diag(nrow(w))
  if (!ncol(w)) return(ans)
  for (j in seq_len(ncol(w))) {
    ans <- ans %*% (diag(nrow(w)) - tcrossprod(w[, j], p[, j]))
  }
  ans
}

reference_simpls <- function(xtrain, xtest, ytrain, ncomp) {
  ymean <- colMeans(ytrain)
  yc <- sweep(ytrain, 2L, ymean, "-")
  fit <- pls::simpls.fit(
    xtrain,
    yc,
    ncomp = ncomp,
    center = FALSE,
    orthScores = TRUE
  )
  coefficient <- fit$coefficients[, , ncomp, drop = FALSE][, , 1L]
  prediction <- sweep(xtest %*% coefficient, 2L, ymean, "+")
  list(
    fit = fit,
    coefficient = coefficient,
    prediction = prediction,
    scores = fit$scores[, seq_len(ncomp), drop = FALSE]
  )
}

kernel_matrix_reference <- function(x1, x2, kernel, gamma, degree, coef0) {
  dots <- x1 %*% t(x2)
  if (identical(kernel, "poly")) return((gamma * dots + coef0)^degree)
  n1 <- rowSums(x1^2)
  n2 <- rowSums(x2^2)
  distance <- outer(n1, n2, "+") - 2 * dots
  distance[distance < 0 & distance > -1e-10] <- 0
  exp(-gamma * distance)
}

center_kernel_reference <- function(ktrain, ktest) {
  train_col_mean <- colMeans(ktrain)
  train_row_mean <- rowMeans(ktrain)
  grand_mean <- mean(ktrain)
  train_centered <- sweep(ktrain, 2L, train_col_mean, "-")
  train_centered <- sweep(train_centered, 1L, train_row_mean, "-")
  train_centered <- train_centered + grand_mean
  test_centered <- sweep(ktest, 2L, train_col_mean, "-")
  test_centered <- sweep(test_centered, 1L, rowMeans(ktest), "-")
  test_centered <- test_centered + grand_mean
  list(
    train = train_centered,
    test = test_centered,
    col_mean = train_col_mean,
    grand_mean = grand_mean
  )
}

task_metrics <- function(task, fast_prediction, reference_prediction, truth, levels) {
  if (identical(task, "classification")) {
    fast_label <- factor(levels[max.col(fast_prediction)], levels = levels)
    ref_label <- factor(levels[max.col(reference_prediction)], levels = levels)
    truth <- factor(truth, levels = levels)
    return(list(
      fast_metric = mean(fast_label == truth),
      reference_metric = mean(ref_label == truth),
      label_agreement = mean(fast_label == ref_label)
    ))
  }
  list(
    fast_metric = sqrt(mean((fast_prediction - truth)^2)),
    reference_metric = sqrt(mean((reference_prediction - truth)^2)),
    label_agreement = NA_real_
  )
}

make_cases <- function() {
  set.seed(seed)
  latent_case <- function(name, ntrain, ntest, p, q, task, ill = FALSE) {
    rank <- min(6L, p, q)
    z <- matrix(rnorm((ntrain + ntest) * rank), ntrain + ntest, rank)
    load_x <- matrix(rnorm(rank * p), rank, p)
    if (ill) {
      ill_columns <- seq(2L, p, by = 7L)
      load_x[, ill_columns] <-
        matrix(load_x[, 1L], rank, length(ill_columns)) +
        matrix(rnorm(rank * length(ill_columns), sd = 1e-6), rank)
    }
    x <- z %*% load_x + matrix(rnorm((ntrain + ntest) * p, sd = 0.2),
                              ntrain + ntest, p)
    if (identical(task, "classification")) {
      logits <- z %*% matrix(rnorm(rank * q), rank, q)
      label <- factor(max.col(logits), levels = seq_len(q))
      ytrain <- label[seq_len(ntrain)]
      ytest <- label[ntrain + seq_len(ntest)]
    } else {
      response <- z %*% matrix(rnorm(rank * q), rank, q) +
        matrix(rnorm((ntrain + ntest) * q, sd = 0.15), ntrain + ntest, q)
      ytrain <- response[seq_len(ntrain), , drop = FALSE]
      ytest <- response[ntrain + seq_len(ntest), , drop = FALSE]
    }
    list(
      name = name,
      source = "synthetic",
      task = task,
      x_train = x[seq_len(ntrain), , drop = FALSE],
      x_test = x[ntrain + seq_len(ntest), , drop = FALSE],
      y_train = ytrain,
      y_test = ytest,
      ncomp = min(5L, q, ntrain - 2L),
      north = 2L,
      tune = TRUE
    )
  }

  cases <- list(
    latent_case("synthetic_regression_p_lt_n", 140, 60, 30, 8, "regression"),
    latent_case("synthetic_regression_p_gt_n_ill_conditioned", 80, 40, 300, 8,
                "regression", ill = TRUE),
    latent_case("synthetic_classification_p_lt_n", 180, 80, 35, 6,
                "classification"),
    latent_case("synthetic_classification_p_gt_n", 90, 45, 250, 6,
                "classification")
  )

  data(gasoline, package = "pls", envir = environment())
  cases[[length(cases) + 1L]] <- list(
    name = "gasoline_real_regression",
    source = "real",
    task = "regression",
    x_train = as.matrix(gasoline$NIR[1:42, ]),
    x_test = as.matrix(gasoline$NIR[43:60, ]),
    y_train = matrix(gasoline$octane[1:42], ncol = 1L),
    y_test = matrix(gasoline$octane[43:60], ncol = 1L),
    ncomp = 5L,
    north = 1L,
    tune = TRUE
  )

  data(breast, package = "fastPLS", envir = environment())
  cases[[length(cases) + 1L]] <- list(
    name = "breast_real_classification",
    source = "real",
    task = "classification",
    x_train = as.matrix(breast$X_train),
    x_test = as.matrix(breast$X_test),
    y_train = breast$y_train,
    y_test = breast$y_test,
    ncomp = 3L,
    north = 1L,
    tune = TRUE
  )
  cases
}

validate_opls <- function(case) {
  xy <- prepare_xy(case)
  ref_filter <- reference_opls_filter(
    case$x_train, case$x_test, xy$y_train_matrix,
    north = case$north, scaling = "autoscaling"
  )
  ref_fit <- reference_simpls(
    ref_filter$train, ref_filter$test, xy$y_train_matrix, case$ncomp
  )
  fast <- fastPLS::pls(
    case$x_train,
    case$y_train,
    case$x_test,
    case$y_test,
    ncomp = case$ncomp,
    method = "opls",
    north = case$north,
    scaling = "autoscaling",
    backend = "cpu",
    svd.method = "irlba",
    fit = TRUE,
    proj = TRUE,
    return_variance = FALSE,
    seed = seed
  )
  fast_test <- sweep(
    sweep(case$x_test, 2L, as.numeric(fast$mX), "-"),
    2L, as.numeric(fast$vX), "/"
  )
  if (ncol(fast$W_orth)) {
    for (j in seq_len(ncol(fast$W_orth))) {
      fast_test <- fast_test -
        tcrossprod(drop(fast_test %*% fast$W_orth[, j]), fast$P_orth[, j])
    }
  }
  fast_prediction <- raw_prediction_from_inner(fast$inner_model, fast_test)
  metric <- task_metrics(
    case$task, fast_prediction, ref_fit$prediction, case$y_test, xy$levels
  )
  fast_filter_operator <- filter_operator(fast$W_orth, fast$P_orth)
  reference_filter_operator <- filter_operator(ref_filter$W, ref_filter$P)
  orth_angle <- principal_angles(
    apply(case$x_train, 2L, function(x) (x - mean(x)) / sd(x)) %*% fast$W_orth,
    ref_filter$T
  )
  predictive_angle <- principal_angles(
    fast$inner_model$Ttrain[, seq_len(case$ncomp), drop = FALSE],
    ref_fit$scores
  )
  fast_coefficient <- matrix_from_compact(fast$inner_model$B)
  list(
    row = data.frame(
      family = "OPLS",
      case = case$name,
      source = case$source,
      task = case$task,
      n_train = nrow(case$x_train),
      n_test = nrow(case$x_test),
      p = ncol(case$x_train),
      q = ncol(xy$y_train_matrix),
      ncomp = case$ncomp,
      north = case$north,
      kernel = NA_character_,
      solver = if (min(ncol(case$x_train), ncol(xy$y_train_matrix)) < 6L)
        "exact_small_dimension_fallback" else "deterministic_irlba",
      operator_relative_error = relative_error(
        fast_filter_operator, reference_filter_operator
      ),
      prediction_relative_error = relative_error(
        fast_prediction, ref_fit$prediction
      ),
      prediction_correlation = safe_cor(fast_prediction, ref_fit$prediction),
      coefficient_relative_error = relative_error(
        fast_coefficient, ref_fit$coefficient
      ),
      max_predictive_score_angle_deg = max(predictive_angle, na.rm = TRUE),
      max_orthogonal_score_angle_deg = max(orth_angle, na.rm = TRUE),
      label_agreement = metric$label_agreement,
      fast_metric = metric$fast_metric,
      reference_metric = metric$reference_metric,
      metric_absolute_difference = abs(metric$fast_metric - metric$reference_metric),
      status = "success",
      error = NA_character_
    ),
    fast = fast,
    reference = ref_fit
  )
}

validate_kernel <- function(case, kernel) {
  xy <- prepare_xy(case)
  prep <- preprocess_reference(case$x_train, case$x_test, "autoscaling")
  gamma <- 1 / ncol(case$x_train)
  degree <- 3L
  coef0 <- 1
  ktrain <- kernel_matrix_reference(
    prep$train, prep$train, kernel, gamma, degree, coef0
  )
  ktest <- kernel_matrix_reference(
    prep$test, prep$train, kernel, gamma, degree, coef0
  )
  centered <- center_kernel_reference(ktrain, ktest)
  ref_fit <- reference_simpls(
    centered$train, centered$test, xy$y_train_matrix, case$ncomp
  )
  fast <- fastPLS::pls(
    case$x_train,
    case$y_train,
    case$x_test,
    case$y_test,
    ncomp = case$ncomp,
    method = "kernelpls",
    kernel = kernel,
    gamma = gamma,
    degree = degree,
    coef0 = coef0,
    scaling = "autoscaling",
    backend = "cpu",
    svd.method = "irlba",
    fit = TRUE,
    proj = TRUE,
    return_variance = FALSE,
    seed = seed
  )
  fast_test_preprocessed <- sweep(
    sweep(case$x_test, 2L, as.numeric(fast$mX), "-"),
    2L, as.numeric(fast$vX), "/"
  )
  fast_train_kernel_raw <- fastPLS:::kernel_matrix_cpp(
    fast$Xref,
    fast$Xref,
    fast$kernel_id,
    fast$gamma,
    fast$degree,
    fast$coef0
  )
  fast_train_centered <- fastPLS:::center_kernel_train_cpp(
    fast_train_kernel_raw
  )$K
  fast_test_kernel_raw <- fastPLS:::kernel_matrix_cpp(
    fast_test_preprocessed,
    fast$Xref,
    fast$kernel_id,
    fast$gamma,
    fast$degree,
    fast$coef0
  )
  fast_test_centered <- fastPLS:::center_kernel_test_cpp(
    fast_test_kernel_raw,
    fast$kernel_center$col_means,
    fast$kernel_center$grand_mean
  )
  fast_prediction <- raw_prediction_from_inner(
    fast$inner_model, fast_test_centered
  )
  metric <- task_metrics(
    case$task, fast_prediction, ref_fit$prediction, case$y_test, xy$levels
  )
  fast_ktrain <- as.matrix(fast$inner_model$Ttrain)
  predictive_angle <- principal_angles(
    fast_ktrain[, seq_len(case$ncomp), drop = FALSE],
    ref_fit$scores
  )
  fast_coefficient <- matrix_from_compact(fast$inner_model$B)
  list(
    row = data.frame(
      family = paste0("kernelPLS_", kernel),
      case = case$name,
      source = case$source,
      task = case$task,
      n_train = nrow(case$x_train),
      n_test = nrow(case$x_test),
      p = ncol(case$x_train),
      q = ncol(xy$y_train_matrix),
      ncomp = case$ncomp,
      north = NA_integer_,
      kernel = kernel,
      solver = if (min(nrow(case$x_train), ncol(xy$y_train_matrix)) < 6L)
        "exact_small_dimension_fallback" else "deterministic_irlba",
      operator_relative_error = relative_error(
        fast_train_centered, centered$train
      ),
      prediction_relative_error = relative_error(
        fast_prediction, ref_fit$prediction
      ),
      prediction_correlation = safe_cor(fast_prediction, ref_fit$prediction),
      coefficient_relative_error = relative_error(
        fast_coefficient, ref_fit$coefficient
      ),
      max_predictive_score_angle_deg = max(predictive_angle, na.rm = TRUE),
      max_orthogonal_score_angle_deg = NA_real_,
      label_agreement = metric$label_agreement,
      fast_metric = metric$fast_metric,
      reference_metric = metric$reference_metric,
      metric_absolute_difference = abs(metric$fast_metric - metric$reference_metric),
      status = "success",
      error = NA_character_
    ),
    fast = fast,
    reference = ref_fit
  )
}

error_row <- function(family, case, message, kernel = NA_character_) {
  xy <- prepare_xy(case)
  data.frame(
    family = family,
    case = case$name,
    source = case$source,
    task = case$task,
    n_train = nrow(case$x_train),
    n_test = nrow(case$x_test),
    p = ncol(case$x_train),
    q = ncol(xy$y_train_matrix),
    ncomp = case$ncomp,
    north = if (identical(family, "OPLS")) case$north else NA_integer_,
    kernel = kernel,
    solver = NA_character_,
    operator_relative_error = NA_real_,
    prediction_relative_error = NA_real_,
    prediction_correlation = NA_real_,
    coefficient_relative_error = NA_real_,
    max_predictive_score_angle_deg = NA_real_,
    max_orthogonal_score_angle_deg = NA_real_,
    label_agreement = NA_real_,
    fast_metric = NA_real_,
    reference_metric = NA_real_,
    metric_absolute_difference = NA_real_,
    status = "failed",
    error = conditionMessage(message)
  )
}

make_folds <- function(case, kfold = 5L) {
  n <- nrow(case$x_train)
  folds <- integer(n)
  set.seed(seed)
  if (identical(case$task, "classification")) {
    for (level in levels(factor(case$y_train))) {
      index <- sample(which(case$y_train == level))
      folds[index] <- rep(seq_len(kfold), length.out = length(index))
    }
  } else {
    folds[sample(seq_len(n))] <- rep(seq_len(kfold), length.out = n)
  }
  folds
}

subset_case <- function(case, train_index, test_index, ncomp) {
  list(
    name = case$name,
    source = case$source,
    task = case$task,
    x_train = case$x_train[train_index, , drop = FALSE],
    x_test = case$x_train[test_index, , drop = FALSE],
    y_train = if (is.matrix(case$y_train)) {
      case$y_train[train_index, , drop = FALSE]
    } else {
      factor(case$y_train[train_index], levels = levels(factor(case$y_train)))
    },
    y_test = if (is.matrix(case$y_train)) {
      case$y_train[test_index, , drop = FALSE]
    } else {
      factor(case$y_train[test_index], levels = levels(factor(case$y_train)))
    },
    ncomp = ncomp,
    north = case$north,
    tune = FALSE
  )
}

component_selection_agreement <- function(case, family, kernel = NA_character_) {
  folds <- make_folds(case)
  grid <- seq_len(case$ncomp)
  path <- list()
  row_index <- 0L
  for (component in grid) {
    fold_rows <- list()
    for (fold in sort(unique(folds))) {
      test_index <- which(folds == fold)
      train_index <- which(folds != fold)
      fold_case <- subset_case(case, train_index, test_index, component)
      result <- tryCatch(
        if (identical(family, "OPLS")) {
          validate_opls(fold_case)
        } else {
          validate_kernel(fold_case, kernel)
        },
        error = identity
      )
      if (inherits(result, "error")) {
        row_index <- row_index + 1L
        path[[row_index]] <- data.frame(
          family = family,
          case = case$name,
          component = component,
          fold = fold,
          fast_metric = NA_real_,
          reference_metric = NA_real_,
          status = "failed",
          error = conditionMessage(result)
        )
      } else {
        row_index <- row_index + 1L
        path[[row_index]] <- data.frame(
          family = family,
          case = case$name,
          component = component,
          fold = fold,
          fast_metric = result$row$fast_metric,
          reference_metric = result$row$reference_metric,
          status = "success",
          error = NA_character_
        )
      }
    }
  }
  path <- do.call(rbind, path)
  successful <- path[path$status == "success", , drop = FALSE]
  aggregate_path <- aggregate(
    cbind(fast_metric, reference_metric) ~ component,
    successful,
    mean
  )
  choose <- if (identical(case$task, "classification")) {
    function(x) aggregate_path$component[which.max(x)]
  } else {
    function(x) aggregate_path$component[which.min(x)]
  }
  selected <- data.frame(
    family = family,
    case = case$name,
    task = case$task,
    grid = paste(grid, collapse = ";"),
    fast_selected_ncomp = choose(aggregate_path$fast_metric),
    reference_selected_ncomp = choose(aggregate_path$reference_metric),
    selected_component_agreement =
      choose(aggregate_path$fast_metric) == choose(aggregate_path$reference_metric),
    failed_folds = sum(path$status != "success")
  )
  list(raw = path, aggregate = aggregate_path, selected = selected)
}

cases <- make_cases()
rows <- list()
index <- 0L

for (case in cases) {
  message(sprintf("[%s] OPLS: %s", format(Sys.time()), case$name))
  result <- tryCatch(validate_opls(case), error = identity)
  index <- index + 1L
  rows[[index]] <- if (inherits(result, "error")) {
    error_row("OPLS", case, result)
  } else {
    result$row
  }

  for (kernel in c("rbf", "poly")) {
    message(sprintf("[%s] kernelPLS/%s: %s", format(Sys.time()), kernel, case$name))
    result <- tryCatch(validate_kernel(case, kernel), error = identity)
    index <- index + 1L
    rows[[index]] <- if (inherits(result, "error")) {
      error_row(paste0("kernelPLS_", kernel), case, result, kernel)
    } else {
      result$row
    }
  }
}

raw <- do.call(rbind, rows)
rownames(raw) <- NULL

selection_raw <- list()
selection_path <- list()
selection_summary <- list()
selection_index <- 0L
for (case in cases) {
  for (family in c("OPLS", "kernelPLS_rbf", "kernelPLS_poly")) {
    message(sprintf(
      "[%s] fixed-fold component selection: %s / %s",
      format(Sys.time()), family, case$name
    ))
    kernel <- if (startsWith(family, "kernelPLS_")) {
      sub("^kernelPLS_", "", family)
    } else {
      NA_character_
    }
    result <- component_selection_agreement(case, family, kernel)
    selection_index <- selection_index + 1L
    selection_raw[[selection_index]] <- result$raw
    aggregate_part <- result$aggregate
    aggregate_part$family <- family
    aggregate_part$case <- case$name
    selection_path[[selection_index]] <- aggregate_part
    selection_summary[[selection_index]] <- result$selected
  }
}
selection_raw <- do.call(rbind, selection_raw)
selection_path <- do.call(rbind, selection_path)
selection_summary <- do.call(rbind, selection_summary)
rownames(selection_raw) <- NULL
rownames(selection_path) <- NULL
rownames(selection_summary) <- NULL

tolerance <- data.frame(
  diagnostic = c(
    "operator_relative_error",
    "prediction_relative_error",
    "coefficient_relative_error",
    "max_predictive_score_angle_deg",
    "max_orthogonal_score_angle_deg",
    "classification_label_disagreement",
    "metric_absolute_difference"
  ),
  threshold = c(1e-10, 1e-4, 1e-3, 0.1, 0.1, 0.005, 0.005)
)

raw$passes_operator <- raw$operator_relative_error <= 1e-10
raw$passes_prediction <- raw$prediction_relative_error <= 1e-4
raw$passes_coefficient <- raw$coefficient_relative_error <= 1e-3
raw$passes_predictive_subspace <- raw$max_predictive_score_angle_deg <= 0.1
raw$passes_orthogonal_subspace <- is.na(raw$max_orthogonal_score_angle_deg) |
  raw$max_orthogonal_score_angle_deg <= 0.1
raw$passes_labels <- is.na(raw$label_agreement) | raw$label_agreement >= 0.995
raw$passes_metric <- raw$metric_absolute_difference <= 0.005
raw$passes_all <- with(
  raw,
  status == "success" & passes_operator & passes_prediction &
    passes_coefficient & passes_predictive_subspace &
    passes_orthogonal_subspace & passes_labels & passes_metric
)

summary <- do.call(
  rbind,
  lapply(split(raw, raw$family), function(x) {
    ok <- x$status == "success"
    data.frame(
      family = x$family[1L],
      runs = nrow(x),
      successes = sum(ok),
      failures = sum(!ok),
      passes_all = sum(x$passes_all, na.rm = TRUE),
      max_operator_relative_error = max(x$operator_relative_error[ok], na.rm = TRUE),
      max_prediction_relative_error = max(x$prediction_relative_error[ok], na.rm = TRUE),
      min_prediction_correlation = min(x$prediction_correlation[ok], na.rm = TRUE),
      max_coefficient_relative_error = max(x$coefficient_relative_error[ok], na.rm = TRUE),
      max_predictive_score_angle_deg = max(
        x$max_predictive_score_angle_deg[ok], na.rm = TRUE
      ),
      max_orthogonal_score_angle_deg = if (all(is.na(x$max_orthogonal_score_angle_deg))) {
        NA_real_
      } else {
        max(x$max_orthogonal_score_angle_deg[ok], na.rm = TRUE)
      },
      min_label_agreement = if (all(is.na(x$label_agreement))) {
        NA_real_
      } else {
        min(x$label_agreement[ok], na.rm = TRUE)
      },
      max_metric_absolute_difference = max(
        x$metric_absolute_difference[ok], na.rm = TRUE
      )
    )
  })
)
rownames(summary) <- NULL

write.csv(raw, file.path(out_dir, "opls_kernel_estimator_validation_raw.csv"),
          row.names = FALSE)
write.csv(summary, file.path(out_dir, "opls_kernel_estimator_validation_summary.csv"),
          row.names = FALSE)
write.csv(tolerance, file.path(out_dir, "opls_kernel_estimator_validation_tolerances.csv"),
          row.names = FALSE)
write.csv(raw[raw$status != "success" | !raw$passes_all, , drop = FALSE],
          file.path(out_dir, "opls_kernel_estimator_validation_failures.csv"),
          row.names = FALSE)
write.csv(
  selection_raw,
  file.path(out_dir, "opls_kernel_component_selection_fold_raw.csv"),
  row.names = FALSE
)
write.csv(
  selection_path,
  file.path(out_dir, "opls_kernel_component_selection_paths.csv"),
  row.names = FALSE
)
write.csv(
  selection_summary,
  file.path(out_dir, "opls_kernel_component_selection_summary.csv"),
  row.names = FALSE
)

ropls_status <- if (requireNamespace("ropls", quietly = TRUE)) {
  "available; retained only as a secondary formulation comparator"
} else {
  paste(
    "unavailable in this environment; Bioconductor installation failed because",
    "the configured repository index could not be reached. Equation-level OPLS",
    "plus pls::simpls.fit is the prespecified independent reference."
  )
}

report <- c(
  "# Independent OPLS and nonlinear kernel-PLS estimator validation",
  "",
  sprintf("- fastPLS version: %s", as.character(packageVersion("fastPLS"))),
  sprintf("- pls version: %s", as.character(packageVersion("pls"))),
  sprintf("- seed: %d", seed),
  sprintf("- ropls status: %s", ropls_status),
  "",
  "## Design",
  "",
  paste(
    "OPLS was compared with an independent equation-level orthogonal filter",
    "followed by `pls::simpls.fit`. Nonlinear kernel PLS was compared with",
    "independently constructed and centered RBF/polynomial Gram matrices followed",
    "by `pls::simpls.fit`. Deterministic IRLBA was requested; documented exact",
    "fallbacks occur only when the smaller cross-covariance dimension is below six."
  ),
  "",
  "## Summary",
  "",
  paste(capture.output(print(summary, row.names = FALSE)), collapse = "\n"),
  "",
  "## Fixed-fold component selection",
  "",
  paste(capture.output(print(selection_summary, row.names = FALSE)), collapse = "\n"),
  "",
  "## Interpretation",
  "",
  sprintf(
    "%d of %d runs passed all prespecified numerical tolerances; %d runs failed to execute.",
    sum(raw$passes_all, na.rm = TRUE), nrow(raw), sum(raw$status != "success")
  ),
  sprintf(
    "Selected component count agreed in %d of %d family-case comparisons.",
    sum(selection_summary$selected_component_agreement),
    nrow(selection_summary)
  ),
  "",
  "Approximate rSVD is intentionally excluded from estimator-preservation claims and",
  "must be reported separately as an approximate workflow comparison."
)
writeLines(report, file.path(out_dir, "IMPLEMENTATION_VALIDATION_REPORT.md"))
writeLines(capture.output(sessionInfo()), file.path(out_dir, "session_info.txt"))

print(summary)
cat(sprintf("\nResults written to %s\n", normalizePath(out_dir)))
if (any(raw$status != "success")) quit(status = 2L)
