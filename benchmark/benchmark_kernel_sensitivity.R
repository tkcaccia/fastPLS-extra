#!/usr/bin/env Rscript

script_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
script_file <- if (length(script_arg)) sub("^--file=", "", script_arg[[1L]]) else file.path(getwd(), "benchmark_kernel_sensitivity.R")
script_dir <- dirname(normalizePath(script_file, winslash = "/", mustWork = FALSE))
source(file.path(script_dir, "helpers_dataset_memory_compare.R"))

timestamp <- function() format(Sys.time(), "%Y-%m-%d %H:%M:%S")
log_msg <- function(...) cat("[", timestamp(), "] ", sprintf(...), "\n", sep = "")

args <- parse_kv_args()
mode <- arg_value(args, "mode", default = "tune_one")
lib_loc <- normalizePath(
  arg_value(args, "lib_loc", default = Sys.getenv("FASTPLS_BENCH_LIB", .libPaths()[[1L]])),
  winslash = "/", mustWork = FALSE
)
if (dir.exists(lib_loc)) .libPaths(c(lib_loc, .libPaths()))

split_ints <- function(x) {
  out <- suppressWarnings(as.integer(trimws(strsplit(x, ",", fixed = TRUE)[[1L]])))
  unique(out[is.finite(out) & out > 0L])
}

read_number <- function(x, default = NA_real_) {
  out <- suppressWarnings(as.numeric(x))
  if (!length(out) || !is.finite(out[[1L]])) default else out[[1L]]
}

read_integer <- function(x, default = NA_integer_) {
  out <- suppressWarnings(as.integer(x))
  if (!length(out) || !is.finite(out[[1L]])) default else out[[1L]]
}

rbind_fill <- function(parts) {
  parts <- Filter(function(x) is.data.frame(x) && nrow(x), parts)
  if (!length(parts)) return(data.frame())
  all_names <- unique(unlist(lapply(parts, names), use.names = FALSE))
  parts <- lapply(parts, function(x) {
    missing <- setdiff(all_names, names(x))
    for (nm in missing) x[[nm]] <- NA
    x[all_names]
  })
  do.call(rbind, parts)
}

task_q <- function(task) {
  if (identical(task$task_type, "classification")) {
    nlevels(factor(task$Ytrain))
  } else {
    as.integer(task$n_classes %||% dim(task$Ytrain)[[2L]])
  }
}

base_gamma_rbf <- function(X, seed = 123L, sample_n = 512L) {
  dims <- dim(X)
  n <- as.integer(dims[[1L]])
  p <- as.integer(dims[[2L]])
  set.seed(as.integer(seed))
  take <- sort(sample.int(n, min(as.integer(sample_n), n)))
  Xsample <- as_double_matrix(X[take, , drop = FALSE])
  distances <- as.numeric(stats::dist(Xsample))
  d2 <- distances[is.finite(distances) & distances > 0]^2
  if (!length(d2)) return(1 / max(1L, p))
  med <- stats::median(d2)
  if (!is.finite(med) || med <= 0) 1 / max(1L, p) else 1 / med
}

cv_metrics_for_family <- function(task, kernel, ncomp_grid, kfold, seed) {
  selection_metric <- if (identical(task$task_type, "classification")) "accuracy" else "rmsd"
  p <- as.integer(task$p %||% ncol(task$Xtrain))
  gamma_base <- if (identical(kernel, "rbf")) {
    base_gamma_rbf(task$Xtrain, seed = seed)
  } else if (identical(kernel, "poly")) {
    1 / max(1L, p)
  } else {
    NA_real_
  }
  gamma_grid <- if (identical(kernel, "linear")) NULL else gamma_base * c(0.25, 1, 4)

  call_args <- list(
    Xdata = task$Xtrain,
    Ydata = task$Ytrain,
    ncomp = as.integer(ncomp_grid),
    kfold = as.integer(kfold),
    scaling = "centering",
    method = "kernelpls",
    backend = "cpu",
    svd.method = "rsvd",
    kernel = kernel,
    classifier = "argmax",
    fit = FALSE,
    seed = as.integer(seed),
    selection_metric = selection_metric
  )
  if (!is.null(gamma_grid)) call_args$gamma <- gamma_grid
  if (identical(kernel, "poly")) {
    call_args$degree <- c(2L, 3L)
    call_args$coef0 <- c(0, 1)
  }

  started <- proc.time()[["elapsed"]]
  cv <- tryCatch(do.call(fastPLS::pls.single.cv, call_args), error = function(e) e)
  elapsed <- as.numeric(proc.time()[["elapsed"]] - started)
  if (inherits(cv, "error")) {
    return(data.frame(
      kernel = kernel, gamma = NA_real_, gamma_base = gamma_base,
      gamma_multiplier = NA_real_, degree = NA_integer_, coef0 = NA_real_,
      ncomp = NA_integer_, metric_name = selection_metric,
      metric_value = NA_real_, tuning_time_sec = elapsed,
      status = "error", msg = conditionMessage(cv), stringsAsFactors = FALSE
    ))
  }

  if (is.data.frame(cv$tuning_metrics) && nrow(cv$tuning_metrics)) {
    out <- cv$tuning_metrics
  } else {
    sm <- cv$selection_metrics
    out <- data.frame(
      kernel = kernel,
      gamma = if (identical(kernel, "linear")) NA_real_ else gamma_grid[[1L]],
      degree = if (identical(kernel, "poly")) 3L else 3L,
      coef0 = if (identical(kernel, "poly")) 1 else 1,
      ncomp = as.integer(cv$ncomp),
      metric_name = as.character(sm$metric_name),
      metric_value = as.numeric(sm$metric_value),
      stringsAsFactors = FALSE
    )
  }
  keep <- intersect(
    c("kernel", "gamma", "degree", "coef0", "ncomp", "metric_name", "metric_value"),
    names(out)
  )
  out <- out[keep]
  for (nm in setdiff(c("kernel", "gamma", "degree", "coef0", "ncomp", "metric_name", "metric_value"), names(out))) {
    out[[nm]] <- NA
  }
  out$kernel <- as.character(out$kernel)
  out$gamma <- suppressWarnings(as.numeric(out$gamma))
  out$degree <- suppressWarnings(as.integer(out$degree))
  out$coef0 <- suppressWarnings(as.numeric(out$coef0))
  out$ncomp <- suppressWarnings(as.integer(out$ncomp))
  out$metric_name <- as.character(out$metric_name)
  out$metric_value <- suppressWarnings(as.numeric(out$metric_value))
  out$gamma_base <- gamma_base
  out$gamma_multiplier <- if (identical(kernel, "linear")) NA_real_ else out$gamma / gamma_base
  out$tuning_time_sec <- elapsed
  out$status <- ifelse(is.finite(out$metric_value), "ok", "error")
  out$msg <- ifelse(out$status == "ok", "", "Non-finite cross-validated metric")
  out
}

select_best_by_kernel <- function(tuning) {
  ok <- tuning[tuning$status == "ok" & is.finite(tuning$metric_value), , drop = FALSE]
  if (!nrow(ok)) return(data.frame())
  selected <- lapply(split(ok, ok$kernel), function(d) {
    loss <- tolower(d$metric_name) %in% c("rmsd", "rmse", "mae", "mse")
    primary <- ifelse(loss, d$metric_value, -d$metric_value)
    ord <- order(primary, d$ncomp, d$degree, d$coef0, d$gamma, na.last = TRUE)
    d[ord[[1L]], , drop = FALSE]
  })
  do.call(rbind, selected)
}

base_result_row <- function(task, kernel, gamma, degree, coef0, ncomp, backend, replicate) {
  data.frame(
    dataset = as.character(task$dataset),
    task_type = as.character(task$task_type),
    kernel = as.character(kernel),
    gamma = as.numeric(gamma),
    degree = as.integer(degree),
    coef0 = as.numeric(coef0),
    selected_ncomp = as.integer(ncomp),
    backend = as.character(backend),
    svd_method = "rsvd",
    classifier = if (identical(task$task_type, "classification")) "argmax" else "regression",
    replicate = as.integer(replicate),
    n_train = as.integer(task$n_train %||% dim(task$Xtrain)[[1L]]),
    n_test = as.integer(task$n_test %||% dim(task$Xtest)[[1L]]),
    p = as.integer(task$p %||% dim(task$Xtrain)[[2L]]),
    q = as.integer(task_q(task)),
    input_precision = as.character(task$precision %||% benchmark_matrix_precision(task$Xtrain)),
    execution_precision = NA_character_,
    kernel_engine = NA_character_,
    fit_time_sec = NA_real_,
    predict_time_sec = NA_real_,
    total_time_sec = NA_real_,
    metric_name = if (identical(task$task_type, "classification")) "accuracy" else "rmsd",
    metric_value = NA_real_,
    top5_accuracy = NA_real_,
    balanced_accuracy = NA_real_,
    macro_f1 = NA_real_,
    peak_host_rss_mb = NA_real_,
    peak_gpu_mem_mb = NA_real_,
    rss_before_fit_mb = NA_real_,
    rss_after_fit_mb = NA_real_,
    rss_after_predict_mb = NA_real_,
    status = "error",
    msg = "",
    stringsAsFactors = FALSE
  )
}

if (identical(mode, "tune_one")) {
  suppressPackageStartupMessages(library("fastPLS", lib.loc = lib_loc, character.only = TRUE))
  task_path <- arg_value(args, "task_rds", required = TRUE)
  out_dir <- arg_value(args, "out_dir", required = TRUE)
  ncomp_grid <- split_ints(arg_value(args, "ncomp_grid", required = TRUE))
  kfold <- read_integer(arg_value(args, "kfold", default = "5"), 5L)
  seed <- read_integer(arg_value(args, "seed", default = "123"), 123L)
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  task <- readRDS(task_path)
  task$dataset <- tolower(as.character(task$dataset))
  n_train <- as.integer(task$n_train %||% dim(task$Xtrain)[[1L]])
  p <- as.integer(task$p %||% dim(task$Xtrain)[[2L]])
  ncomp_grid <- ncomp_grid[ncomp_grid < n_train & ncomp_grid <= max(p, n_train - 1L)]
  if (!length(ncomp_grid)) stop("No valid component count remains for ", task$dataset)
  log_msg("Kernel tuning dataset=%s folds=%s ncomp=%s", task$dataset, kfold, paste(ncomp_grid, collapse = ","))
  tuning <- rbind_fill(lapply(c("linear", "rbf", "poly"), function(kernel) {
    log_msg("TUNE dataset=%s kernel=%s", task$dataset, kernel)
    cv_metrics_for_family(task, kernel, ncomp_grid, kfold, seed)
  }))
  tuning$dataset <- task$dataset
  tuning$task_type <- task$task_type
  tuning$n_train <- task$n_train
  tuning$n_test <- task$n_test
  tuning$p <- task$p
  tuning$q <- task_q(task)
  tuning$kfold <- kfold
  tuning$seed <- seed
  tuning <- tuning[c(
    "dataset", "task_type", "n_train", "n_test", "p", "q", "kfold", "seed",
    "kernel", "gamma", "gamma_base", "gamma_multiplier", "degree", "coef0",
    "ncomp", "metric_name", "metric_value", "tuning_time_sec", "status", "msg"
  )]
  selected <- select_best_by_kernel(tuning)
  utils::write.csv(tuning, file.path(out_dir, paste0(task$dataset, "_kernel_tuning.csv")), row.names = FALSE, na = "")
  utils::write.csv(selected, file.path(out_dir, paste0(task$dataset, "_kernel_selected.csv")), row.names = FALSE, na = "")
  log_msg("Selected %s/%s kernel families for %s", nrow(selected), 3L, task$dataset)
  quit(save = "no", status = if (nrow(selected)) 0 else 2)
}

if (identical(mode, "run_one") || identical(mode, "write_failure")) {
  task <- readRDS(arg_value(args, "task_rds", required = TRUE))
  kernel <- arg_value(args, "kernel", required = TRUE)
  gamma <- read_number(arg_value(args, "gamma", default = "NA"), NA_real_)
  degree <- read_integer(arg_value(args, "degree", default = "3"), 3L)
  coef0 <- read_number(arg_value(args, "coef0", default = "1"), 1)
  ncomp <- read_integer(arg_value(args, "ncomp", required = TRUE))
  backend <- arg_value(args, "backend", required = TRUE)
  replicate <- read_integer(arg_value(args, "replicate", default = "1"), 1L)
  row_out <- arg_value(args, "row_out", required = TRUE)
  pid_file <- arg_value(args, "pid_file", default = "")
  if (nzchar(pid_file)) writeLines(as.character(Sys.getpid()), pid_file)
  row <- base_result_row(task, kernel, gamma, degree, coef0, ncomp, backend, replicate)

  if (identical(mode, "write_failure")) {
    row$status <- arg_value(args, "status", default = "error")
    row$msg <- arg_value(args, "msg", default = "Benchmark process failed before writing a result")
    write_one_row_csv(row, row_out)
    quit(save = "no", status = 0)
  }

  result <- tryCatch({
    suppressPackageStartupMessages(library("fastPLS", lib.loc = lib_loc, character.only = TRUE))
    if (identical(backend, "cuda") && !isTRUE(fastPLS::has_cuda())) stop("CUDA backend is unavailable")
    if (identical(backend, "metal") && !isTRUE(fastPLS::has_metal())) stop("Metal backend is unavailable")
    rss_before <- current_process_rss_mb()
    fit_time <- system.time({
      fit <- fastPLS::pls(
        Xtrain = task$Xtrain,
        Ytrain = task$Ytrain,
        ncomp = as.integer(ncomp),
        method = "kernelpls",
        backend = backend,
        svd.method = "rsvd",
        kernel = kernel,
        gamma = if (is.finite(gamma)) gamma else NULL,
        degree = as.integer(degree),
        coef0 = coef0,
        classifier = "argmax",
        fit = FALSE,
        return_variance = FALSE,
        seed = 123L + as.integer(replicate)
      )
    })[["elapsed"]]
    rss_fit <- current_process_rss_mb()
    predict_time <- system.time({
      pred <- predict(
        fit,
        task$Xtest,
        top5 = identical(task$task_type, "classification"),
        backend = backend
      )
    })[["elapsed"]]
    rss_predict <- current_process_rss_mb()
    metric <- metric_from_pred(task$Ytest, pred, y_train = task$Ytrain)
    row$execution_precision <- benchmark_execution_precision(fit, row$input_precision)
    row$kernel_engine <- as.character(fit$kernel_engine %||% "unknown")
    row$fit_time_sec <- as.numeric(fit_time)
    row$predict_time_sec <- as.numeric(predict_time)
    row$total_time_sec <- as.numeric(fit_time + predict_time)
    row$metric_name <- metric$metric_name
    row$metric_value <- as.numeric(metric$metric_value)
    row$top5_accuracy <- as.numeric(metric$top5_accuracy %||% NA_real_)
    row$balanced_accuracy <- as.numeric(metric$balanced_accuracy %||% NA_real_)
    row$macro_f1 <- as.numeric(metric$macro_f1 %||% NA_real_)
    row$rss_before_fit_mb <- rss_before
    row$rss_after_fit_mb <- rss_fit
    row$rss_after_predict_mb <- rss_predict
    row$status <- "ok"
    row$msg <- ""
    row
  }, error = function(e) {
    row$status <- "error"
    row$msg <- conditionMessage(e)
    row
  })
  write_one_row_csv(result, row_out)
  quit(save = "no", status = 0)
}

if (identical(mode, "annotate_row")) {
  row_path <- arg_value(args, "row_out", required = TRUE)
  row <- utils::read.csv(row_path, stringsAsFactors = FALSE, check.names = FALSE)
  row$peak_host_rss_mb <- read_number(arg_value(args, "peak_host_rss_mb", default = "NA"), NA_real_)
  row$peak_gpu_mem_mb <- read_number(arg_value(args, "peak_gpu_mem_mb", default = "NA"), NA_real_)
  utils::write.csv(row, row_path, row.names = FALSE, na = "")
  quit(save = "no", status = 0)
}

if (identical(mode, "summarize")) {
  out_dir <- arg_value(args, "out_dir", required = TRUE)
  row_files <- Sys.glob(file.path(out_dir, "run_rows", "*.csv"))
  tuning_files <- Sys.glob(file.path(out_dir, "tuning", "*_kernel_tuning.csv"))
  selected_files <- Sys.glob(file.path(out_dir, "tuning", "*_kernel_selected.csv"))
  raw <- rbind_fill(lapply(row_files, function(path) utils::read.csv(path, stringsAsFactors = FALSE, check.names = FALSE)))
  tuning <- rbind_fill(lapply(tuning_files, function(path) utils::read.csv(path, stringsAsFactors = FALSE, check.names = FALSE)))
  selected <- rbind_fill(lapply(selected_files, function(path) utils::read.csv(path, stringsAsFactors = FALSE, check.names = FALSE)))
  utils::write.csv(raw, file.path(out_dir, "kernel_sensitivity_raw.csv"), row.names = FALSE, na = "")
  utils::write.csv(tuning, file.path(out_dir, "kernel_sensitivity_tuning.csv"), row.names = FALSE, na = "")
  utils::write.csv(selected, file.path(out_dir, "kernel_sensitivity_selected.csv"), row.names = FALSE, na = "")

  ok <- raw[raw$status == "ok" & is.finite(raw$metric_value), , drop = FALSE]
  summarize_group <- function(d) {
    qfun <- function(x, p) if (any(is.finite(x))) as.numeric(stats::quantile(x[is.finite(x)], p, names = FALSE)) else NA_real_
    data.frame(
      successful_reps = nrow(d),
      metric_median = stats::median(d$metric_value, na.rm = TRUE),
      metric_q25 = qfun(d$metric_value, 0.25), metric_q75 = qfun(d$metric_value, 0.75),
      fit_time_median_sec = stats::median(d$fit_time_sec, na.rm = TRUE),
      predict_time_median_sec = stats::median(d$predict_time_sec, na.rm = TRUE),
      total_time_median_sec = stats::median(d$total_time_sec, na.rm = TRUE),
      total_time_q25_sec = qfun(d$total_time_sec, 0.25), total_time_q75_sec = qfun(d$total_time_sec, 0.75),
      peak_host_rss_median_mb = stats::median(d$peak_host_rss_mb, na.rm = TRUE),
      peak_host_rss_q25_mb = qfun(d$peak_host_rss_mb, 0.25), peak_host_rss_q75_mb = qfun(d$peak_host_rss_mb, 0.75),
      peak_gpu_mem_median_mb = if (any(is.finite(d$peak_gpu_mem_mb))) stats::median(d$peak_gpu_mem_mb, na.rm = TRUE) else NA_real_,
      peak_gpu_mem_q25_mb = qfun(d$peak_gpu_mem_mb, 0.25), peak_gpu_mem_q75_mb = qfun(d$peak_gpu_mem_mb, 0.75),
      top5_accuracy_median = if (any(is.finite(d$top5_accuracy))) stats::median(d$top5_accuracy, na.rm = TRUE) else NA_real_,
      stringsAsFactors = FALSE
    )
  }
  if (nrow(ok)) {
    keys <- c("dataset", "task_type", "kernel", "gamma", "degree", "coef0", "selected_ncomp", "backend", "svd_method", "classifier", "n_train", "n_test", "p", "q", "input_precision", "execution_precision", "metric_name")
    group_key <- do.call(
      paste,
      c(lapply(ok[keys], function(x) {
        value <- as.character(x)
        value[is.na(value)] <- "<NA>"
        value
      }), sep = "\r")
    )
    groups <- split(ok, group_key, drop = TRUE)
    summary <- rbind_fill(lapply(groups, function(d) cbind(d[1L, keys, drop = FALSE], summarize_group(d))))
  } else {
    summary <- data.frame()
  }
  utils::write.csv(summary, file.path(out_dir, "kernel_sensitivity_summary.csv"), row.names = FALSE, na = "")
  failures <- rbind_fill(list(
    raw[raw$status != "ok", , drop = FALSE],
    tuning[tuning$status != "ok", , drop = FALSE]
  ))
  utils::write.csv(failures, file.path(out_dir, "kernel_sensitivity_failures.csv"), row.names = FALSE, na = "")

  report <- c(
    "# Supplementary kernel sensitivity benchmark",
    "",
    "Kernel and component settings were selected using five-fold cross-validation on the training set only. The selected configuration for each kernel family was then refitted on the complete training set and evaluated once on the unchanged held-out test set. CPU and CUDA final runs used the same selected settings.",
    "",
    sprintf("Successful final runs: %s", nrow(ok)),
    sprintf("Failed or skipped final/tuning rows: %s", nrow(failures)),
    "",
    "The RBF search used 0.25, 1, and 4 times a median-distance scale estimated from at most 512 training observations. The polynomial search used 0.25, 1, and 4 times 1/p, degrees 2 and 3, and intercepts 0 and 1. Classification used argmax decoding so the comparison isolates the kernel rather than the downstream classifier.",
    "",
    "Nonlinear kernel PLS stores an n x n Gram matrix. The benchmark therefore uses representative biomedical datasets rather than sample-rich image or single-cell tasks for which Gram storage would dominate the comparison."
  )
  writeLines(report, file.path(out_dir, "kernel_sensitivity_report.md"))
  capture.output(sessionInfo(), file = file.path(out_dir, "session_info.txt"))
  quit(save = "no", status = 0)
}

stop("Unknown --mode: ", mode)
