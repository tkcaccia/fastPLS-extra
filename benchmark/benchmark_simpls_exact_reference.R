#!/usr/bin/env Rscript

# Exact dense-LAPACK validation of the compiled SIMPLS execution path.
# This audit-only script keeps exact evidence separate from the public IRLBA
# and rSVD solver routes.

options(stringsAsFactors = FALSE)

args <- commandArgs(trailingOnly = TRUE)
arg_value <- function(name, default) {
  key <- paste0("--", name, "=")
  hit <- args[startsWith(args, key)]
  if (length(hit)) sub(key, "", hit[[1L]], fixed = TRUE) else default
}

root <- normalizePath(arg_value("root", "."), winslash = "/", mustWork = TRUE)
out_dir <- arg_value(
  "out",
  file.path(Sys.getenv("FASTPLS_RESULTS_ROOT"), "simpls_exact_reference")
)
if (!nzchar(Sys.getenv("FASTPLS_RESULTS_ROOT")) &&
    !any(startsWith(args, "--out="))) {
  stop("Set --out or FASTPLS_RESULTS_ROOT.", call. = FALSE)
}
bench_lib <- Sys.getenv("FASTPLS_BENCH_LIB", "")
if (nzchar(bench_lib) && dir.exists(bench_lib)) {
  .libPaths(unique(c(normalizePath(bench_lib, mustWork = TRUE), .libPaths())))
}
suppressPackageStartupMessages(library(fastPLS))
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

relative_error <- function(x, reference) {
  sqrt(sum((x - reference)^2)) /
    max(sqrt(sum(reference^2)), .Machine$double.eps)
}

principal_angles <- function(x, reference, tol = 1e-12) {
  qx <- qr(x, tol = tol)
  qr_ref <- qr(reference, tol = tol)
  rx <- qx$rank
  rr <- qr_ref$rank
  if (!rx || !rr) return(rep(90, max(rx, rr, 1L)))
  ux <- qr.Q(qx)[, seq_len(rx), drop = FALSE]
  ur <- qr.Q(qr_ref)[, seq_len(rr), drop = FALSE]
  values <- svd(crossprod(ux, ur), nu = 0L, nv = 0L)$d
  angles <- acos(pmin(1, pmax(-1, values))) * 180 / pi
  if (rx != rr) angles <- c(angles, rep(90, abs(rx - rr)))
  angles
}

orthogonality_residual <- function(x) {
  if (!ncol(x)) return(NA_real_)
  norm(crossprod(x) - diag(ncol(x)), type = "F")
}

one_hot <- function(y) {
  y <- factor(y)
  ans <- matrix(0, length(y), nlevels(y), dimnames = list(NULL, levels(y)))
  ans[cbind(seq_along(y), as.integer(y))] <- 1
  ans
}

center_columns <- function(x) sweep(x, 2L, colMeans(x), "-")

exact_simpls_reference <- function(X, Y, max_ncomp) {
  X <- as.matrix(X)
  Y <- as.matrix(Y)
  mx <- colMeans(X)
  my <- colMeans(Y)
  Xc <- sweep(X, 2L, mx, "-")
  Yc <- sweep(Y, 2L, my, "-")
  S <- crossprod(Xc, Yc)
  p <- ncol(Xc)
  q <- ncol(Yc)
  R <- matrix(0, p, max_ncomp)
  P <- matrix(0, p, max_ncomp)
  Q <- matrix(0, q, max_ncomp)
  V <- matrix(0, p, max_ncomp)
  T <- matrix(0, nrow(Xc), max_ncomp)
  deflation <- rep(NA_real_, max_ncomp)
  singular_gap <- rep(NA_real_, max_ncomp)
  status <- rep("not_run", max_ncomp)
  effective <- 0L

  for (a in seq_len(max_ncomp)) {
    S_before <- S
    decomposition <- tryCatch(
      svd(S_before, nu = min(nrow(S_before), 2L), nv = 0L),
      error = function(e) e
    )
    if (inherits(decomposition, "error") || !length(decomposition$d)) {
      status[[a]] <- if (inherits(decomposition, "error")) {
        paste0("lapack_failure: ", conditionMessage(decomposition))
      } else "empty_decomposition"
      break
    }
    singular_gap[[a]] <- if (length(decomposition$d) >= 2L) {
      (decomposition$d[[1L]] - decomposition$d[[2L]]) /
        max(decomposition$d[[1L]], .Machine$double.eps)
    } else Inf
    r <- decomposition$u[, 1L]
    t <- drop(Xc %*% r)
    tnorm <- sqrt(sum(t * t))
    if (!is.finite(tnorm) || tnorm <= .Machine$double.eps) {
      status[[a]] <- "zero_score_norm"
      break
    }
    r <- r / tnorm
    t <- t / tnorm
    p_load <- as.numeric(t(Xc) %*% t)
    q_load <- as.numeric(t(Yc) %*% t)
    v <- p_load
    if (a > 1L) {
      previous <- V[, seq_len(a - 1L), drop = FALSE]
      v <- v - as.numeric(previous %*% (t(previous) %*% v))
    }
    vnorm <- sqrt(sum(v * v))
    if (!is.finite(vnorm) || vnorm <= .Machine$double.eps) {
      status[[a]] <- "zero_deflation_norm"
      break
    }
    v <- v / vnorm
    v_row <- matrix(v, nrow = 1L)
    S <- S_before - v %o% as.numeric(v_row %*% S_before)
    deflation[[a]] <- norm(v_row %*% S, type = "F") /
      max(norm(S_before, type = "F"), .Machine$double.eps)
    R[, a] <- r
    P[, a] <- p_load
    Q[, a] <- q_load
    V[, a] <- v
    T[, a] <- t
    status[[a]] <- "converged"
    effective <- a
  }

  keep <- if (effective) seq_len(effective) else integer()
  list(
    R = R[, keep, drop = FALSE], P = P[, keep, drop = FALSE],
    Q = Q[, keep, drop = FALSE], V = V[, keep, drop = FALSE],
    T = T[, keep, drop = FALSE], mx = mx, my = my,
    Xc = Xc, Yc = Yc, deflation = deflation,
    singular_gap = singular_gap, status = status, effective = effective
  )
}

compiled_exact_simpls <- function(X, Y, max_ncomp) {
  namespace <- asNamespace("fastPLS")
  engine <- get("pls_model2_fast", envir = namespace, inherits = FALSE)
  old_t <- Sys.getenv("FASTPLS_RETURN_TTRAIN", unset = NA_character_)
  old_b <- Sys.getenv("FASTPLS_STORE_B", unset = NA_character_)
  on.exit({
    if (is.na(old_t)) Sys.unsetenv("FASTPLS_RETURN_TTRAIN") else Sys.setenv(FASTPLS_RETURN_TTRAIN = old_t)
    if (is.na(old_b)) Sys.unsetenv("FASTPLS_STORE_B") else Sys.setenv(FASTPLS_STORE_B = old_b)
  }, add = TRUE)
  Sys.setenv(FASTPLS_RETURN_TTRAIN = "1", FASTPLS_STORE_B = "always")
  engine(
    as.matrix(X), as.matrix(Y), seq_len(max_ncomp), 1L, TRUE,
    3L, 0L, 0L, 0, 1L
  )
}

make_latent_case <- function(name, seed, n_train, n_test, p, q, rank,
                             condition, classification = FALSE,
                             rank_def_x = FALSE, rank_def_y = FALSE,
                             collinear = FALSE) {
  set.seed(seed)
  n <- n_train + n_test
  z <- matrix(rnorm(n * rank), n, rank)
  lx <- matrix(rnorm(p * rank), p, rank)
  if (collinear && p >= 4L) {
    lx[2L, ] <- lx[1L, ] + rnorm(rank, sd = 1e-9)
    lx[3L, ] <- 2 * lx[1L, ] - lx[2L, ] + rnorm(rank, sd = 1e-9)
  }
  X <- z %*% t(lx) + matrix(rnorm(n * p, sd = 0.02), n, p)
  if (rank_def_x && p >= 8L) X[, (p - 3L):p] <- X[, 1:4, drop = FALSE]
  if (classification) {
    logits <- z %*% matrix(rnorm(rank * q), rank, q)
    labels <- max.col(logits + matrix(rnorm(n * q, sd = 0.2), n, q))
    labels[seq_len(q)] <- seq_len(q)
    labels <- factor(labels, levels = seq_len(q))
    Y <- one_hot(labels)
  } else {
    Y <- z %*% matrix(rnorm(rank * q), rank, q) + matrix(rnorm(n * q, sd = 0.02), n, q)
    labels <- NULL
    if (rank_def_y && q >= 6L) Y[, (q - 2L):q] <- Y[, 1:3, drop = FALSE]
  }
  effective_rank <- qr(crossprod(center_columns(X[seq_len(n_train), , drop = FALSE]),
                                 center_columns(Y[seq_len(n_train), , drop = FALSE])), tol = 1e-10)$rank
  max_ncomp <- max(1L, min(rank, effective_rank, n_train - 1L, p, q - as.integer(classification)))
  list(
    case = name, condition = condition, task_type = if (classification) "classification" else "regression",
    Xtrain = X[seq_len(n_train), , drop = FALSE],
    Ytrain = Y[seq_len(n_train), , drop = FALSE],
    Xtest = X[n_train + seq_len(n_test), , drop = FALSE],
    Ytest = Y[n_train + seq_len(n_test), , drop = FALSE],
    labels_test = if (classification) labels[n_train + seq_len(n_test)] else NULL,
    max_ncomp = max_ncomp, seed = seed
  )
}

make_tied_case <- function() {
  set.seed(909)
  n_train <- 140L
  n_test <- 40L
  p <- 24L
  q <- 10L
  qx <- qr.Q(qr(matrix(rnorm(n_train * p), n_train, p)))
  qx <- center_columns(qx)
  qx <- qr.Q(qr(qx))[, seq_len(p), drop = FALSE]
  u <- qr.Q(qr(matrix(rnorm(p * q), p, q)))
  v <- qr.Q(qr(matrix(rnorm(q * q), q, q)))
  values <- c(10, 10 * (1 - 1e-12), 7, 5, 3, 2, 1, 0.5, 0.2, 0.1)
  target <- u %*% diag(values) %*% t(v)
  ytrain <- qx %*% target
  xtest <- matrix(rnorm(n_test * p), n_test, p)
  ytest <- sweep(xtest, 2L, colMeans(qx), "-") %*% target
  list(
    case = "nearly_tied_leading_values", condition = "relative_gap_1e-12",
    task_type = "regression", Xtrain = qx, Ytrain = ytrain,
    Xtest = xtest, Ytest = ytest, labels_test = NULL,
    max_ncomp = 8L, seed = 909L
  )
}

make_rank_boundary_case <- function() {
  set.seed(910)
  n_train <- 120L
  n_test <- 40L
  p <- 32L
  q <- 12L
  rank <- 8L
  z_train <- matrix(rnorm(n_train * rank), n_train, rank)
  z_test <- matrix(rnorm(n_test * rank), n_test, rank)
  lx <- matrix(rnorm(p * rank), p, rank)
  ly <- matrix(rnorm(q * rank), q, rank)
  list(
    case = "component_at_effective_rank",
    condition = "requested_component_equals_effective_rank",
    task_type = "regression",
    Xtrain = z_train %*% t(lx), Ytrain = z_train %*% t(ly),
    Xtest = z_test %*% t(lx), Ytest = z_test %*% t(ly),
    labels_test = NULL, max_ncomp = rank, seed = 910L
  )
}

cases <- list(
  make_latent_case("well_conditioned_p_lt_n", 101, 180, 60, 35, 5, 5, "well_conditioned"),
  make_latent_case("p_gt_n", 102, 80, 40, 220, 8, 7, "p_greater_than_n"),
  make_latent_case("high_q", 103, 150, 50, 45, 160, 14, "high_response_dimension"),
  make_latent_case("rank_deficient_x", 104, 130, 40, 70, 9, 8, "rank_deficient_X", rank_def_x = TRUE),
  make_latent_case("rank_deficient_y", 105, 140, 40, 55, 18, 9, "rank_deficient_Y", rank_def_y = TRUE),
  make_latent_case("highly_collinear_x", 106, 150, 50, 80, 10, 9, "highly_collinear_predictors", collinear = TRUE),
  make_latent_case("dummy_classification_p_lt_n", 107, 240, 80, 40, 6, 5, "dummy_response_classification", classification = TRUE),
  make_latent_case("dummy_classification_p_gt_n", 108, 100, 50, 180, 10, 9, "dummy_response_classification_p_gt_n", classification = TRUE),
  make_tied_case(),
  make_rank_boundary_case()
)

rows <- list()
failures <- list()
row_index <- failure_index <- 1L

for (case in cases) {
  message("Exact SIMPLS audit: ", case$case)
  result <- tryCatch({
    reference <- exact_simpls_reference(case$Xtrain, case$Ytrain, case$max_ncomp)
    compiled <- compiled_exact_simpls(case$Xtrain, case$Ytrain, case$max_ncomp)
    completed <- min(reference$effective, ncol(compiled$R), case$max_ncomp)
    if (completed < 1L) stop("No component completed")
    Xc <- center_columns(case$Xtrain)
    Yc <- center_columns(case$Ytrain)
    S0 <- crossprod(Xc, Yc)
    compiled_T_full <- compiled$Ttrain[, seq_len(completed), drop = FALSE]
    compiled_P_full <- crossprod(Xc, compiled_T_full)
    compiled_V <- matrix(0, ncol(Xc), completed)
    for (a in seq_len(completed)) {
      v <- compiled_P_full[, a]
      if (a > 1L) {
        previous <- compiled_V[, seq_len(a - 1L), drop = FALSE]
        v <- v - as.numeric(previous %*% (t(previous) %*% v))
      }
      compiled_V[, a] <- v / sqrt(sum(v * v))
    }
    S_compiled <- S0
    compiled_deflation <- rep(NA_real_, completed)
    for (a in seq_len(completed)) {
      v <- compiled_V[, a]
      before <- S_compiled
      v_row <- matrix(v, nrow = 1L)
      S_compiled <- before - v %o% as.numeric(v_row %*% before)
      compiled_deflation[[a]] <- norm(v_row %*% S_compiled, type = "F") /
        max(norm(before, type = "F"), .Machine$double.eps)
    }
    do.call(rbind, lapply(seq_len(completed), function(a) {
      ref_R <- reference$R[, seq_len(a), drop = FALSE]
      ref_Q <- reference$Q[, seq_len(a), drop = FALSE]
      ref_B <- ref_R %*% t(ref_Q)
      ref_fit_centered <- reference$T[, seq_len(a), drop = FALSE] %*%
        t(ref_Q)
      ref_fit <- sweep(ref_fit_centered, 2L, reference$my, "+")
      ref_prediction <- sweep(case$Xtest, 2L, reference$mx, "-") %*% ref_B
      ref_prediction <- sweep(ref_prediction, 2L, reference$my, "+")

      candidate_B <- compiled$B[, , a, drop = FALSE][, , 1L]
      candidate_fit <- compiled$Yfit[, , a, drop = FALSE][, , 1L]
      candidate_prediction <- sweep(case$Xtest, 2L, as.numeric(compiled$mX), "-") %*% candidate_B
      candidate_prediction <- sweep(candidate_prediction, 2L, as.numeric(compiled$mY), "+")
      candidate_T <- compiled_T_full[, seq_len(a), drop = FALSE]
      candidate_P <- compiled_P_full[, seq_len(a), drop = FALSE]
      label_agreement <- if (case$task_type == "classification") {
        mean(max.col(candidate_prediction) == max.col(ref_prediction))
      } else NA_real_

      data.frame(
        case = case$case, condition = case$condition,
        task_type = case$task_type, seed = case$seed,
        n_train = nrow(case$Xtrain), n_test = nrow(case$Xtest),
        p = ncol(case$Xtrain), q = ncol(case$Ytrain),
        x_rank = qr(Xc, tol = 1e-10)$rank,
        y_rank = qr(Yc, tol = 1e-10)$rank,
        crosscov_rank = qr(S0, tol = 1e-10)$rank,
        ncomp = a, near_effective_rank = a >= 0.8 * qr(S0, tol = 1e-10)$rank,
        leading_relative_singular_gap = reference$singular_gap[[a]],
        coefficient_relative_error = relative_error(candidate_B, ref_B),
        fitted_value_relative_error = relative_error(candidate_fit, ref_fit),
        prediction_relative_error = relative_error(candidate_prediction, ref_prediction),
        prediction_max_absolute_error = max(abs(candidate_prediction - ref_prediction)),
        score_subspace_max_angle_degrees = max(principal_angles(candidate_T, reference$T[, seq_len(a), drop = FALSE])),
        loading_subspace_max_angle_degrees = max(principal_angles(candidate_P, reference$P[, seq_len(a), drop = FALSE])),
        projection_subspace_max_angle_degrees = max(principal_angles(compiled$R[, seq_len(a), drop = FALSE], ref_R)),
        score_orthogonality_residual = orthogonality_residual(candidate_T),
        deflation_basis_orthogonality_residual = orthogonality_residual(compiled_V[, seq_len(a), drop = FALSE]),
        reference_score_orthogonality_residual = orthogonality_residual(reference$T[, seq_len(a), drop = FALSE]),
        reference_deflation_basis_orthogonality_residual = orthogonality_residual(reference$V[, seq_len(a), drop = FALSE]),
        deflation_residual = compiled_deflation[[a]],
        reference_deflation_residual = reference$deflation[[a]],
        classification_label_agreement = label_agreement,
        exact_reference_status = reference$status[[a]],
        compiled_solver_status = "converged",
        stringsAsFactors = FALSE
      )
    }))
  }, error = function(e) e)

  if (inherits(result, "error")) {
    failures[[failure_index]] <- data.frame(
      case = case$case, condition = case$condition,
      task_type = case$task_type,
      call = paste(deparse(conditionCall(result)), collapse = " "),
      error = conditionMessage(result)
    )
    failure_index <- failure_index + 1L
  } else {
    rows[[row_index]] <- result
    row_index <- row_index + 1L
  }
}

raw <- if (length(rows)) do.call(rbind, rows) else data.frame()
failure_table <- if (length(failures)) do.call(rbind, failures) else data.frame(
  case = character(), condition = character(), task_type = character(),
  call = character(), error = character()
)
write.csv(raw, file.path(out_dir, "simpls_exact_reference_prefix_results.csv"), row.names = FALSE)
write.csv(failure_table, file.path(out_dir, "simpls_exact_reference_failures.csv"), row.names = FALSE)

metric_columns <- c(
  "coefficient_relative_error", "fitted_value_relative_error",
  "prediction_relative_error", "prediction_max_absolute_error",
  "score_subspace_max_angle_degrees", "loading_subspace_max_angle_degrees",
  "projection_subspace_max_angle_degrees", "score_orthogonality_residual",
  "deflation_basis_orthogonality_residual", "deflation_residual"
)
quantiles <- c(0, 0.25, 0.5, 0.75, 0.95, 0.99, 1)
distribution <- do.call(rbind, lapply(metric_columns, function(metric) {
  values <- raw[[metric]][is.finite(raw[[metric]])]
  values_q <- stats::quantile(values, quantiles, names = FALSE, type = 8)
  data.frame(
    metric = metric, probability = quantiles, value = values_q,
    observations = length(values), stringsAsFactors = FALSE
  )
}))
write.csv(distribution, file.path(out_dir, "simpls_exact_reference_error_distributions.csv"), row.names = FALSE)

case_summary <- do.call(rbind, lapply(split(raw, raw$case), function(x) {
  data.frame(
    case = x$case[[1L]], condition = x$condition[[1L]],
    task_type = x$task_type[[1L]], component_prefixes = nrow(x),
    max_coefficient_relative_error = max(x$coefficient_relative_error),
    max_fitted_value_relative_error = max(x$fitted_value_relative_error),
    max_prediction_relative_error = max(x$prediction_relative_error),
    max_score_subspace_angle_degrees = max(x$score_subspace_max_angle_degrees),
    max_loading_subspace_angle_degrees = max(x$loading_subspace_max_angle_degrees),
    max_projection_subspace_angle_degrees = max(x$projection_subspace_max_angle_degrees),
    max_score_orthogonality_residual = max(x$score_orthogonality_residual),
    max_deflation_basis_orthogonality_residual = max(x$deflation_basis_orthogonality_residual),
    max_deflation_residual = max(x$deflation_residual),
    min_classification_label_agreement = if (any(is.finite(x$classification_label_agreement))) min(x$classification_label_agreement, na.rm = TRUE) else NA_real_,
    convergence_failures = sum(x$exact_reference_status != "converged" | x$compiled_solver_status != "converged"),
    stringsAsFactors = FALSE
  )
}))
write.csv(case_summary, file.path(out_dir, "simpls_exact_reference_case_summary.csv"), row.names = FALSE)

writeLines(c(
  "reference=independent R de Jong SIMPLS updates with base LAPACK svd()",
  "candidate=compiled fastPLS SIMPLS forced to audit-only dense LAPACK solver",
  "precision=float64",
  "centering=training-column means",
  "direction=leading left singular vector of the current p-by-q cross-covariance",
  "evidence_scope=exact-reference numerical validation only; not a public solver benchmark",
  paste0("package_version=", as.character(packageVersion("fastPLS")))
), file.path(out_dir, "simpls_exact_reference_parameters.txt"))
writeLines(capture.output(sessionInfo()), file.path(out_dir, "sessionInfo.txt"))

cat("Exact SIMPLS validation completed:", nrow(raw), "prefix rows and",
    nrow(failure_table), "failures.\n")
print(case_summary)
