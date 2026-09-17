#!/usr/bin/env Rscript

# Execution ablation for compiled SIMPLS. IRLBA is deterministic and does not
# use the rSVD refresh workspace; the ablation therefore evaluates the rSVD
# route only, with identical data partitions and seeds in each configuration.

args <- commandArgs(trailingOnly = TRUE)
get_arg <- function(name, default) {
  key <- paste0("--", name, "=")
  hit <- args[startsWith(args, key)]
  if (!length(hit)) return(default)
  sub(key, "", hit[[1L]], fixed = TRUE)
}

out_dir <- get_arg("out", "")
if (!nzchar(out_dir)) {
  results_root <- Sys.getenv("FASTPLS_RESULTS_ROOT")
  if (!nzchar(results_root)) stop("Set --out or FASTPLS_RESULTS_ROOT.")
  out_dir <- file.path(results_root, "simpls_execution_ablation")
}
cifar_path <- get_arg("cifar", Sys.getenv("FASTPLS_CIFAR100_INPUT"))
if (!nzchar(cifar_path)) stop("Set --cifar or FASTPLS_CIFAR100_INPUT.")
reps <- as.integer(get_arg("reps", "3"))
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

benchmark_lib <- Sys.getenv("FASTPLS_BENCH_LIB", "")
if (nzchar(benchmark_lib)) {
  .libPaths(unique(c(benchmark_lib, .libPaths())))
}
suppressPackageStartupMessages(library(fastPLS))
if (!requireNamespace("KODAMA", quietly = TRUE)) stop("KODAMA is required for MetRef.", call. = FALSE)

with_env <- function(values, code) {
  old <- Sys.getenv(names(values), unset = NA_character_)
  on.exit({
    for (name in names(values)) {
      if (is.na(old[[name]])) Sys.unsetenv(name) else Sys.setenv(structure(old[[name]], names = name))
    }
  }, add = TRUE)
  do.call(Sys.setenv, as.list(values))
  force(code)
}

prepare_metref <- function() {
  data("MetRef", package = "KODAMA")
  X <- MetRef$data
  X <- X[, colSums(X) != 0, drop = FALSE]
  X <- KODAMA::normalization(X)$newXtrain
  X <- KODAMA::scaling(X)$newXtrain
  y <- factor(MetRef$donor)
  set.seed(123)
  test <- sample(seq_len(nrow(X)), min(100L, floor(nrow(X) / 5L)))
  list(name = "MetRef", Xtrain = as.matrix(X[-test, , drop = FALSE]),
       ytrain = y[-test], Xtest = as.matrix(X[test, , drop = FALSE]),
       ytest = y[test], ncomp = 22L)
}

prepare_cifar <- function() {
  e <- new.env(parent = emptyenv())
  load(cifar_path, envir = e)
  if (!exists("r", e)) stop("CIFAR RData must contain object 'r'.", call. = FALSE)
  d <- get("r", e)
  feature_cols <- grep("^feat_", names(d), value = TRUE)
  if (!length(feature_cols)) stop("CIFAR feature columns named feat_* were not found.", call. = FALSE)
  train_rows <- which(d$split == "train")
  test_rows <- which(d$split == "test")
  set.seed(123)
  train_rows <- unlist(tapply(train_rows, d$label_idx[train_rows], function(i) sample(i, min(50L, length(i))), simplify = FALSE), use.names = FALSE)
  test_rows <- unlist(tapply(test_rows, d$label_idx[test_rows], function(i) sample(i, min(10L, length(i))), simplify = FALSE), use.names = FALSE)
  list(name = "CIFAR100_n5000", Xtrain = as.matrix(d[train_rows, feature_cols, drop = FALSE]),
       ytrain = factor(d$label_idx[train_rows]), Xtest = as.matrix(d[test_rows, feature_cols, drop = FALSE]),
       ytest = factor(d$label_idx[test_rows]), ncomp = 100L)
}

tasks <- list(prepare_metref(), prepare_cifar())
configs <- list(
  default = c(FASTPLS_FAST_OPTIMIZED = "1", FASTPLS_FAST_DEFLCACHE = "1"),
  no_rsvd_workspace_reuse = c(FASTPLS_FAST_OPTIMIZED = "0", FASTPLS_FAST_DEFLCACHE = "1"),
  no_deflation_cache = c(FASTPLS_FAST_OPTIMIZED = "1", FASTPLS_FAST_DEFLCACHE = "0")
)

rows <- list()
row_id <- 1L
for (task in tasks) {
  reference <- NULL
  for (config_name in names(configs)) {
    for (replicate in seq_len(reps)) {
      set.seed(123)
      run <- with_env(configs[[config_name]], {
        elapsed <- system.time({
          model <- pls(task$Xtrain, task$ytrain, ncomp = task$ncomp,
                       method = "simpls", backend = "cpu", svd.method = "rsvd",
                       scaling = "centering", fit = FALSE, return_variance = FALSE,
                       seed = 123)
          prediction <- predict(
            model,
            task$Xtest,
            task$ytest,
            backend = "cpu"
          )$Ypred[[1L]]
        })[["elapsed"]]
        list(model = model, prediction = prediction, elapsed = elapsed)
      })
      if (is.null(reference) && identical(config_name, "default") && replicate == 1L) reference <- run$prediction
      rows[[row_id]] <- data.frame(
        dataset = task$name, configuration = config_name, replicate = replicate,
        n_train = nrow(task$Xtrain), n_test = nrow(task$Xtest), p = ncol(task$Xtrain),
        ncomp = task$ncomp, total_time_sec = run$elapsed,
        accuracy = mean(as.character(run$prediction) == as.character(task$ytest)),
        prediction_agreement_vs_default = mean(as.character(run$prediction) == as.character(reference)),
        stringsAsFactors = FALSE
      )
      row_id <- row_id + 1L
    }
  }
}

raw <- do.call(rbind, rows)
summary <- do.call(rbind, lapply(split(raw, interaction(raw$dataset, raw$configuration, drop = TRUE)), function(x) {
  data.frame(dataset = x$dataset[[1L]], configuration = x$configuration[[1L]],
             n_repetitions = nrow(x), total_time_sec_median = stats::median(x$total_time_sec),
             total_time_sec_iqr = stats::IQR(x$total_time_sec), accuracy_median = stats::median(x$accuracy),
             agreement_median = stats::median(x$prediction_agreement_vs_default), stringsAsFactors = FALSE)
}))
utils::write.csv(raw, file.path(out_dir, "simpls_execution_ablation_raw.csv"), row.names = FALSE)
utils::write.csv(summary, file.path(out_dir, "simpls_execution_ablation_summary.csv"), row.names = FALSE)
print(summary)
