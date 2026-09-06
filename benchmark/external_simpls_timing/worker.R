#!/usr/bin/env Rscript

options(stringsAsFactors = FALSE)

bench_lib <- Sys.getenv("FASTPLS_BENCH_LIB", "")
if (nzchar(bench_lib) && dir.exists(bench_lib)) {
  .libPaths(unique(c(normalizePath(bench_lib, winslash = "/", mustWork = TRUE), .libPaths())))
}

parse_args <- function(x = commandArgs(trailingOnly = TRUE)) {
  out <- list()
  for (item in x) {
    if (!startsWith(item, "--")) next
    bits <- strsplit(substring(item, 3L), "=", fixed = TRUE)[[1L]]
    out[[gsub("-", "_", bits[[1L]], fixed = TRUE)]] <-
      if (length(bits) > 1L) paste(bits[-1L], collapse = "=") else "TRUE"
  }
  out
}

args <- parse_args()
arg <- function(name, default = NULL) {
  value <- args[[name]]
  if (is.null(value) || !nzchar(value)) default else value
}

script_file <- grep("^--file=", commandArgs(FALSE), value = TRUE)
script_file <- if (length(script_file)) sub("^--file=", "", script_file[[1L]]) else "worker.R"
repo_root <- normalizePath(file.path(dirname(script_file), "..", ".."), winslash = "/", mustWork = TRUE)
source(file.path(repo_root, "benchmark", "helpers_dataset_memory_compare.R"))

dataset_id <- tolower(arg("dataset"))
implementation <- match.arg(arg("implementation"), c("fastpls", "pls"))
profile <- match.arg(arg("profile"), c("estimator_kernel", "complete_workflow"))
timing_mode <- match.arg(
  arg("timing_mode", "cold_process"),
  c("cold_process", "steady_process_batch")
)
measurement_scope <- match.arg(arg("measurement_scope", "primary"), c("primary", "phase_decomposition"))
phase_timing_enabled <- identical(tolower(arg("phase_timing", "false")), "true")
batch_iterations <- as.integer(arg(
  "iterations",
  if (identical(timing_mode, "steady_process_batch")) "20" else "1"
))
if (!is.finite(batch_iterations) || batch_iterations < 1L) batch_iterations <- 1L
if (identical(timing_mode, "cold_process")) batch_iterations <- 1L
ncomp <- as.integer(arg("ncomp"))
requested_ncomp <- ncomp
replicate_id <- as.integer(arg("replicate", "1"))
split_seed <- as.integer(arg("seed", "123"))
row_out <- arg("row_out")
timeout_sec <- as.numeric(arg("timeout_sec", "10000"))
cpu_profile <- arg("cpu_profile", "reference_1")
requested_threads <- as.integer(arg("threads", "1"))

if (!nzchar(dataset_id) || is.na(ncomp) || ncomp < 1L || !nzchar(row_out)) {
  stop("dataset, ncomp, and row-out are required.")
}

# Namespace and shared-library loading are deliberately outside the timed fit.
if (!requireNamespace("fastPLS", quietly = TRUE)) stop("fastPLS is not installed.")
if (!requireNamespace("pls", quietly = TRUE)) stop("pls is not installed.")

task <- as_task(find_dataset_rdata(dataset_id), dataset_id = dataset_id, split_seed = split_seed)
Xtrain <- if (is_float32_matrix(task$Xtrain)) float::dbl(task$Xtrain) else as.matrix(task$Xtrain)
Xtest <- if (is_float32_matrix(task$Xtest)) float::dbl(task$Xtest) else as.matrix(task$Xtest)
Ytrain <- task$Ytrain
Ytest <- task$Ytest

if (!identical(task$task_type, "classification")) {
  stop("The publication external SIMPLS timing comparison is classification-only.")
}
Ytrain <- droplevels(as.factor(Ytrain))
Ytest <- factor(Ytest, levels = levels(Ytrain))
keep <- !is.na(Ytest)
Xtest <- Xtest[keep, , drop = FALSE]
Ytest <- droplevels(Ytest[keep])
class_levels <- levels(Ytrain)
Ydummy <- stats::model.matrix(~ Ytrain - 1)
colnames(Ydummy) <- class_levels
ncomp <- min(ncomp, ncol(Xtrain), nrow(Xtrain) - 1L)
if (ncomp < 1L) stop("No positive component count remains for SIMPLS fitting.")

elapsed <- function(expr) {
  start <- Sys.time()
  value <- force(expr)
  list(value = value, seconds = as.numeric(difftime(Sys.time(), start, units = "secs")))
}

size_mb <- function(x) as.numeric(utils::object.size(x)) / 1024^2

current_rss_mb <- function() {
  status_file <- "/proc/self/status"
  if (file.exists(status_file)) {
    line <- grep("^VmRSS:", readLines(status_file, warn = FALSE), value = TRUE)
    if (length(line)) {
      value_kb <- suppressWarnings(as.numeric(sub("^VmRSS:[[:space:]]*([0-9]+).*", "\\1", line[[1L]])))
      if (is.finite(value_kb)) return(value_kb / 1024)
    }
  }
  value_kb <- suppressWarnings(as.numeric(system2(
    "ps", c("-o", "rss=", "-p", as.character(Sys.getpid())), stdout = TRUE, stderr = FALSE
  )))
  if (length(value_kb) && is.finite(value_kb[[1L]])) value_kb[[1L]] / 1024 else NA_real_
}

loaded_blas_library <- function() {
  maps <- "/proc/self/maps"
  if (file.exists(maps)) {
    paths <- unique(sub(".*[[:space:]](/[^[:space:]]+)$", "\\1", readLines(maps, warn = FALSE)))
    paths <- paths[grepl("(openblas|libblas|accelerate|veclib)", paths, ignore.case = TRUE)]
    if (length(paths)) return(paste(paths, collapse = " | "))
  }
  blas <- unname(extSoftVersion()["BLAS"])
  if (length(blas) && nzchar(blas)) blas else NA_character_
}

reported_blas_threads <- function() {
  if (!requireNamespace("RhpcBLASctl", quietly = TRUE)) return(NA_integer_)
  suppressWarnings(as.integer(RhpcBLASctl::blas_get_num_procs()))
}

blas_library <- loaded_blas_library()
blas_threads <- reported_blas_threads()
if (startsWith(cpu_profile, "optimized_")) {
  if (!grepl("openblas", blas_library, ignore.case = TRUE)) {
    stop("Optimized CPU profile requested, but OpenBLAS is not loaded.")
  }
  if (!is.finite(blas_threads) || blas_threads != requested_threads) {
    stop(
      "Optimized CPU profile requested ", requested_threads,
      " BLAS threads, but the runtime reports ", blas_threads, "."
    )
  }
}

dense_mb <- function(...) prod(as.double(c(...))) * 8 / 1024^2

named_size_mb <- function(x, candidates) {
  if (is.null(x)) return(0)
  total <- 0
  for (name in intersect(candidates, names(x))) {
    value <- x[[name]]
    if (length(value)) total <- total + size_mb(value)
  }
  total
}

decode <- function(scores) {
  scores <- as.matrix(scores)
  factor(class_levels[max.col(scores, ties.method = "first")], levels = class_levels)
}

fit_fastpls <- function() {
  old_store <- Sys.getenv("FASTPLS_STORE_B", unset = NA_character_)
  old_phase_timing <- Sys.getenv("FASTPLS_BENCH_PHASE_TIMING", unset = NA_character_)
  on.exit({
    if (is.na(old_store)) Sys.unsetenv("FASTPLS_STORE_B") else Sys.setenv(FASTPLS_STORE_B = old_store)
    if (is.na(old_phase_timing)) {
      Sys.unsetenv("FASTPLS_BENCH_PHASE_TIMING")
    } else {
      Sys.setenv(FASTPLS_BENCH_PHASE_TIMING = old_phase_timing)
    }
  }, add = TRUE)
  if (identical(profile, "estimator_kernel")) Sys.setenv(FASTPLS_STORE_B = "always")
  if (phase_timing_enabled) {
    Sys.setenv(FASTPLS_BENCH_PHASE_TIMING = "1")
  } else {
    Sys.unsetenv("FASTPLS_BENCH_PHASE_TIMING")
  }

  call <- list(
    Xtrain = Xtrain,
    Ytrain = Ytrain,
    ncomp = if (identical(profile, "estimator_kernel")) seq_len(ncomp) else ncomp,
    method = "simpls",
    backend = "cpu",
    svd.method = "irlba",
    scaling = "centering",
    seed = split_seed + replicate_id
  )
  if (identical(profile, "estimator_kernel")) {
    call$fit <- FALSE
    call$return_variance <- FALSE
    call$return_loadings <- FALSE
    call$proj <- FALSE
  }
  do.call(fastPLS::pls, call)
}

predict_fastpls <- function(fit) {
  ans <- stats::predict(fit, Xtest)
  pred <- ans$Ypred
  if (is.data.frame(pred)) pred <- pred[[ncol(pred)]]
  factor(pred, levels = class_levels)
}

fit_pls <- function() {
  pls::simpls.fit(
    Xtrain,
    Ydummy,
    ncomp = ncomp,
    center = TRUE,
    stripped = identical(profile, "estimator_kernel")
  )
}

predict_pls <- function(fit) {
  coefficient <- fit$coefficients[, , ncomp, drop = TRUE]
  if (is.null(dim(coefficient))) coefficient <- matrix(coefficient, ncol = ncol(Ydummy))
  scores <- sweep(Xtest, 2L, fit$Xmeans, "-") %*% coefficient
  scores <- sweep(scores, 2L, fit$Ymeans, "+")
  decode(scores)
}

status <- rep("success", batch_iterations)
error_message <- rep("", batch_iterations)
warning_message <- character()
fit <- prediction <- NULL
fit_sec <- prediction_sec <- rep(NA_real_, batch_iterations)
phase_rows <- vector("list", batch_iterations)

if (identical(timing_mode, "steady_process_batch")) {
  # Initialize package dispatch, allocations, and accelerator/runtime state without
  # mixing that first-call cost into steady-state iteration timings.
  warm_fit <- if (identical(implementation, "fastpls")) fit_fastpls() else fit_pls()
  invisible(if (identical(implementation, "fastpls")) predict_fastpls(warm_fit) else predict_pls(warm_fit))
  rm(warm_fit)
  gc(FALSE)
}

gc(FALSE)
prefit_rss_mb <- current_rss_mb()
for (iteration in seq_len(batch_iterations)) {
  tryCatch(
    withCallingHandlers({
      fitted <- elapsed(if (identical(implementation, "fastpls")) fit_fastpls() else fit_pls())
      fit <- fitted$value
      fit_sec[[iteration]] <- fitted$seconds
      predicted <- elapsed(if (identical(implementation, "fastpls")) predict_fastpls(fit) else predict_pls(fit))
      prediction <- predicted$value
      prediction_sec[[iteration]] <- predicted$seconds
      internal_iteration <- if (identical(implementation, "fastpls")) {
        attr(fit, "fastPLS_internal", exact = TRUE)
      } else NULL
      phase_rows[iteration] <- list(internal_iteration$benchmark_phase_timing)
    }, warning = function(w) {
      warning_message <<- c(warning_message, conditionMessage(w))
      invokeRestart("muffleWarning")
    }),
    error = function(e) {
      status[[iteration]] <<- "failed"
      error_message[[iteration]] <<- conditionMessage(e)
    }
  )
}
final_rss_mb <- current_rss_mb()

internal <- if (identical(implementation, "fastpls") && !is.null(fit)) {
  attr(fit, "fastPLS_internal", exact = TRUE)
} else NULL
materialized <- if (identical(implementation, "fastpls")) c(fit, internal) else fit

coefficient_path_mb <- named_size_mb(materialized, c("B", "coefficients"))
score_mb <- named_size_mb(materialized, c("Ttrain", "scores", "TT", "U"))
loading_mb <- named_size_mb(materialized, c("P", "loadings", "loadingsX", "loading.weights"))
fitted_mb <- named_size_mb(materialized, c("Yfit", "fitted.values", "fitted"))
variance_mb <- named_size_mb(materialized, c("variance_explained", "Xvar", "Xtotvar", "explvar"))

accuracy <- if (any(status == "success") && !is.null(prediction)) {
  mean(as.character(prediction) == as.character(Ytest))
} else NA_real_

phase_value <- function(name) {
  vapply(phase_rows, function(x) {
    if (is.null(x) || is.null(x[[name]])) NA_real_ else as.numeric(x[[name]])
  }, numeric(1L))
}

theoretical_cross_covariance_mb <- dense_mb(ncol(Xtrain), ncol(Ydummy))
theoretical_final_coefficient_mb <- dense_mb(ncol(Xtrain), ncol(Ydummy))
theoretical_coefficient_path_mb <- dense_mb(ncol(Xtrain), ncol(Ydummy), ncomp)
theoretical_fitted_path_mb <- dense_mb(nrow(Xtrain), ncol(Ydummy), ncomp)
theoretical_residual_path_mb <- theoretical_fitted_path_mb
theoretical_train_scores_mb <- dense_mb(nrow(Xtrain), ncomp)
theoretical_test_scores_mb <- dense_mb(nrow(Xtest), ncol(Ydummy))
if (identical(profile, "estimator_kernel")) {
  largest_retained_name <- "coefficient path (p x q x A)"
  largest_retained_mb <- theoretical_coefficient_path_mb
} else if (identical(implementation, "pls")) {
  largest_retained_name <- "fitted/residual response path (n_train x q x A each)"
  largest_retained_mb <- theoretical_fitted_path_mb
} else {
  largest_retained_name <- "final coefficient matrix (p x q)"
  largest_retained_mb <- theoretical_final_coefficient_mb
}

row <- data.frame(
  dataset = dataset_id,
  comparison_profile = profile,
  implementation = implementation,
  function_name = if (identical(implementation, "fastpls")) "fastPLS::pls" else "pls::simpls.fit",
  package_version = as.character(utils::packageVersion(if (identical(implementation, "fastpls")) "fastPLS" else "pls")),
  fastpls_source_archive_sha256 = Sys.getenv(
    "FASTPLS_SOURCE_ARCHIVE_SHA256",
    unset = NA_character_
  ),
  estimator = "deterministic SIMPLS",
  solver = if (identical(implementation, "fastpls")) "IRLBA" else "eigen",
  precision = "float64",
  cpu_profile = cpu_profile,
  requested_blas_threads = requested_threads,
  reported_blas_threads = blas_threads,
  loaded_blas_library = blas_library,
  output_contract = if (identical(profile, "estimator_kernel")) {
    "coefficient path plus final test predictions; scores/loadings/fitted arrays suppressed"
  } else {
    "ordinary public fit object plus final test predictions"
  },
  timing_mode = timing_mode,
  measurement_scope = measurement_scope,
  phase_timing_enabled = phase_timing_enabled,
  runtime_initialization_policy = if (identical(timing_mode, "steady_process_batch")) {
    "one untimed complete fit and prediction before measured iterations"
  } else {
    "none; every repetition starts in a fresh R process"
  },
  batch_iterations = batch_iterations,
  iteration = seq_len(batch_iterations),
  timeout_sec = timeout_sec,
  split_seed = split_seed,
  replicate = replicate_id,
  n_train = nrow(Xtrain),
  n_test = nrow(Xtest),
  p = ncol(Xtrain),
  q = ncol(Ydummy),
  ncomp = ncomp,
  requested_ncomp = requested_ncomp,
  effective_ncomp = ncomp,
  fit_sec = fit_sec,
  prediction_sec = prediction_sec,
  total_sec = fit_sec + prediction_sec,
  preprocess_crosscov_sec = phase_value("preprocess_crosscov_sec"),
  estimator_sec = phase_value("estimator_sec"),
  coefficient_path_sec = phase_value("coefficient_path_sec"),
  fitted_values_sec = phase_value("fitted_values_sec"),
  model_assembly_sec = phase_value("model_assembly_sec"),
  cpp_total_sec = phase_value("cpp_total_sec"),
  r_wrapper_fit_overhead_sec = pmax(0, fit_sec - phase_value("cpp_total_sec")),
  accuracy = accuracy,
  fit_object_mb = if (is.null(fit)) NA_real_ else size_mb(fit),
  prediction_object_mb = if (is.null(prediction)) NA_real_ else size_mb(prediction),
  coefficient_path_mb = coefficient_path_mb,
  score_outputs_mb = score_mb,
  loading_outputs_mb = loading_mb,
  fitted_outputs_mb = fitted_mb,
  variance_outputs_mb = variance_mb,
  prefit_process_rss_mb = prefit_rss_mb,
  final_process_rss_mb = final_rss_mb,
  theoretical_cross_covariance_mb = theoretical_cross_covariance_mb,
  theoretical_final_coefficient_mb = theoretical_final_coefficient_mb,
  theoretical_coefficient_path_mb = theoretical_coefficient_path_mb,
  theoretical_fitted_path_mb = theoretical_fitted_path_mb,
  theoretical_residual_path_mb = theoretical_residual_path_mb,
  theoretical_train_scores_mb = theoretical_train_scores_mb,
  theoretical_test_scores_mb = theoretical_test_scores_mb,
  theoretical_largest_retained_name = largest_retained_name,
  theoretical_largest_retained_mb = largest_retained_mb,
  status = status,
  warning_message = paste(unique(warning_message), collapse = " | "),
  error_message = error_message,
  stringsAsFactors = FALSE
)

dir.create(dirname(row_out), recursive = TRUE, showWarnings = FALSE)
utils::write.csv(row, row_out, row.names = FALSE, quote = TRUE, na = "")
print(row[, c("dataset", "comparison_profile", "implementation", "timing_mode", "replicate", "iteration", "total_sec", "accuracy", "status")])
