#!/usr/bin/env Rscript

# Compare the compiled CV engine with an explicit R-level fold loop. Both
# routes fit the same fastPLS estimator on the same fixed folds and controls.

options(stringsAsFactors = FALSE)

parse_args <- function(x = commandArgs(trailingOnly = TRUE)) {
  out <- list()
  for (item in x) {
    if (!startsWith(item, "--")) next
    fields <- strsplit(substring(item, 3L), "=", fixed = TRUE)[[1L]]
    out[[gsub("-", "_", fields[[1L]])]] <- if (length(fields) > 1L) {
      paste(fields[-1L], collapse = "=")
    } else {
      "TRUE"
    }
  }
  out
}

args <- parse_args()
arg <- function(name, default = NULL) {
  value <- args[[name]]
  if (is.null(value) || !nzchar(value)) default else value
}
`%||%` <- function(left, right) {
  if (is.null(left) || !length(left)) right else left
}

benchmark_lib <- Sys.getenv("FASTPLS_BENCH_LIB", "")
if (nzchar(benchmark_lib)) {
  .libPaths(unique(c(benchmark_lib, .libPaths())))
}
suppressPackageStartupMessages(library(fastPLS))

task_path <- normalizePath(arg("task"), mustWork = TRUE)
output_path <- arg("output", "cv_compiled_vs_r_loop.csv")
dataset <- arg("dataset", sub("_task[.]rds$", "", basename(task_path)))
method <- match.arg(
  arg("method", "simpls"),
  c("plssvd", "simpls", "opls", "kernelpls")
)
backend <- match.arg(arg("backend", "cpu"), c("cpu", "cuda", "metal"))
svd_method <- match.arg(arg("svd_method", "rsvd"), c("rsvd", "irlba"))
classifier <- match.arg(arg("classifier", "argmax"), c("argmax", "lda"))
ncomp <- as.integer(arg("ncomp", "10"))
kfold <- as.integer(arg("kfold", "10"))
replicate_id <- as.integer(arg("replicate", "1"))
seed <- as.integer(arg("seed", "123"))

if (!is.finite(ncomp) || ncomp < 1L) stop("ncomp must be positive.")
if (!is.finite(kfold) || kfold < 2L) stop("kfold must be at least two.")
if (backend != "cpu" && svd_method == "irlba") {
  stop("IRLBA is available only with backend='cpu'.")
}
fastPLS:::.fastpls_require_backend_available(
  backend,
  "Compiled-versus-R-loop CV benchmark"
)

as_double_matrix <- function(value) {
  if (inherits(value, "float32")) return(float::dbl(value))
  as.matrix(value)
}

task <- readRDS(task_path)
X <- rbind(
  as_double_matrix(task$Xtrain),
  as_double_matrix(task$Xtest)
)
classification <- is.factor(task$Ytrain) || is.character(task$Ytrain)
if (classification) {
  levels_ <- levels(factor(task$Ytrain))
  Y <- factor(
    c(as.character(task$Ytrain), as.character(task$Ytest)),
    levels = levels_
  )
} else {
  Y <- rbind(
    as_double_matrix(task$Ytrain),
    as_double_matrix(task$Ytest)
  )
}

fold_groups <- fastPLS:::.make_single_cv_folds(
  Ydata = if (classification) Y else Y[, 1L],
  constrain = seq_len(nrow(X)),
  kfold = kfold,
  seed = seed
)

control <- fastPLS:::.resolve_svd_control(
  svd.method = svd_method,
  dots = list(),
  context = "compiled-versus-R-loop CV benchmark"
)
control <- fastPLS:::.apply_backend_rsvd_controls(
  control,
  backend,
  "compiled-versus-R-loop CV benchmark",
  pls_family = method,
  classification = classification
)
control <- fastPLS:::.apply_fast_simpls_shape_controls(
  control,
  method,
  X,
  Y
)

common_arguments <- list(
  Xdata = X,
  Ydata = Y,
  constrain = fold_groups,
  ncomp = ncomp,
  kfold = kfold,
  scaling = "centering",
  method = method,
  svd.method = control$svd.method,
  rsvd_oversample = control$rsvd_oversample,
  rsvd_power = control$rsvd_power,
  svds_tol = control$svds_tol,
  irlba_work = control$irlba_work,
  irlba_maxit = control$irlba_maxit,
  irlba_tol = control$irlba_tol,
  irlba_eps = control$irlba_eps,
  irlba_svtol = control$irlba_svtol,
  seed = seed,
  classifier = classifier,
  return_scores = TRUE,
  store_predictions = TRUE,
  selection_metric = if (classification) "accuracy" else "rmsd"
)

engine_call <- function(engine) {
  arguments <- common_arguments
  if (identical(engine, "compiled")) {
    arguments$backend <- if (backend == "cpu") "cpp" else backend
    return(do.call(fastPLS:::.pls_cv_compiled, arguments))
  }
  arguments$backend <- backend
  do.call(fastPLS:::.pls_cv_via_pls, arguments)
}

extract_prediction <- function(result) {
  prediction <- result$pred
  if (is.list(prediction) && !is.data.frame(prediction)) {
    prediction <- prediction[[length(prediction)]]
  }
  if (classification) as.character(prediction) else as.matrix(prediction)
}

extract_metric <- function(result) {
  metrics <- result$metrics
  if (!is.data.frame(metrics) || !nrow(metrics)) {
    stop("CV engine returned no metric table.")
  }
  tail(metrics, 1L)
}

coassignment_equal <- function(left, right) {
  if (length(left) != length(right)) return(FALSE)
  cross <- table(as.integer(left), as.integer(right))
  all(rowSums(cross > 0L) == 1L) && all(colSums(cross > 0L) == 1L)
}

order <- if (replicate_id %% 2L) {
  c("compiled", "r_loop")
} else {
  c("r_loop", "compiled")
}
results <- list()
elapsed <- setNames(rep(NA_real_, 2L), c("compiled", "r_loop"))
errors <- character()
for (engine in order) {
  gc(full = TRUE)
  timing <- system.time({
    results[[engine]] <- tryCatch(
      engine_call(engine),
      error = function(error) {
        errors[[engine]] <<- conditionMessage(error)
        NULL
      }
    )
  })
  elapsed[[engine]] <- unname(timing[["elapsed"]])
}

base_row <- data.frame(
  package_version = as.character(packageVersion("fastPLS")),
  dataset = dataset,
  task_type = if (classification) "classification" else "regression",
  n = nrow(X),
  p = ncol(X),
  q = if (classification) nlevels(Y) else ncol(Y),
  method = method,
  backend = backend,
  svd_method = svd_method,
  classifier = classifier,
  ncomp = ncomp,
  kfold = kfold,
  replicate = replicate_id,
  control_profile = control$rsvd_profile %||% if (svd_method == "rsvd") {
    "explicit"
  } else {
    "not_applicable"
  },
  oversample = if (svd_method == "rsvd") control$rsvd_oversample else NA,
  power = if (svd_method == "rsvd") control$rsvd_power else NA,
  seed = seed,
  compiled_sec = elapsed[["compiled"]],
  r_loop_sec = elapsed[["r_loop"]],
  stringsAsFactors = FALSE
)

if (is.null(results$compiled) || is.null(results$r_loop)) {
  row <- transform(
    base_row,
    r_loop_over_compiled = NA_real_,
    metric_name = NA_character_,
    compiled_metric = NA_real_,
    r_loop_metric = NA_real_,
    metric_abs_diff = NA_real_,
    prediction_agreement = NA_real_,
    prediction_correlation = NA_real_,
    prediction_relative_error = NA_real_,
    identical_fold_partition = NA,
    status = "failed",
    error = paste(unname(errors), collapse = " | ")
  )
} else {
  compiled_prediction <- extract_prediction(results$compiled)
  r_loop_prediction <- extract_prediction(results$r_loop)
  compiled_metric <- extract_metric(results$compiled)
  r_loop_metric <- extract_metric(results$r_loop)
  if (classification) {
    agreement <- mean(compiled_prediction == r_loop_prediction, na.rm = TRUE)
    correlation <- NA_real_
    relative_error <- NA_real_
  } else {
    keep <- is.finite(compiled_prediction) & is.finite(r_loop_prediction)
    agreement <- NA_real_
    correlation <- if (sum(keep) > 1L) {
      cor(compiled_prediction[keep], r_loop_prediction[keep])
    } else {
      NA_real_
    }
    relative_error <- sqrt(sum(
      (compiled_prediction[keep] - r_loop_prediction[keep])^2
    )) / max(sqrt(sum(r_loop_prediction[keep]^2)), .Machine$double.eps)
  }
  row <- base_row
  row$r_loop_over_compiled <- row$r_loop_sec / row$compiled_sec
  row$metric_name <- as.character(compiled_metric$metric_name[[1L]])
  row$compiled_metric <- as.numeric(compiled_metric$metric_value[[1L]])
  row$r_loop_metric <- as.numeric(r_loop_metric$metric_value[[1L]])
  row$metric_abs_diff <- abs(row$compiled_metric - row$r_loop_metric)
  row$prediction_agreement <- agreement
  row$prediction_correlation <- correlation
  row$prediction_relative_error <- relative_error
  row$identical_fold_partition <- coassignment_equal(
    results$compiled$fold,
    results$r_loop$fold
  )
  row$status <- "success"
  row$error <- ""
}

dir.create(dirname(output_path), recursive = TRUE, showWarnings = FALSE)
write.csv(row, output_path, row.names = FALSE)
print(row)
