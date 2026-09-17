#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
value <- function(name, default) {
  prefix <- paste0("--", name, "=")
  hit <- args[startsWith(args, prefix)]
  if (!length(hit)) default else sub(prefix, "", hit[[1L]], fixed = TRUE)
}

lib <- value("lib", Sys.getenv("FASTPLS_LIB", ""))
if (nzchar(lib)) .libPaths(c(path.expand(lib), .libPaths()))
suppressPackageStartupMessages({
  library(fastPLS)
  library(float)
})

script_arg <- grep("^--file=", commandArgs(), value = TRUE)
script <- if (length(script_arg)) sub("^--file=", "", script_arg[[1L]]) else
  file.path(getwd(), "benchmark", "benchmark_lda_backend_agreement.R")
repo <- normalizePath(file.path(dirname(script), ".."), mustWork = TRUE)
source(file.path(repo, "benchmark", "helpers_dataset_memory_compare.R"))

out_value <- value("out", "")
if (!nzchar(out_value)) {
  results_root <- Sys.getenv("FASTPLS_RESULTS_ROOT")
  if (!nzchar(results_root)) stop("Set --out or FASTPLS_RESULTS_ROOT.")
  out_value <- file.path(results_root, "lda_backend_agreement")
}
out_dir <- normalizePath(out_value, mustWork = FALSE)
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
datasets <- strsplit(value("datasets", "metref,cifar100,singlecell"), ",", fixed = TRUE)[[1L]]
methods <- strsplit(value("methods", "simpls,plssvd"), ",", fixed = TRUE)[[1L]]
components <- sort(unique(as.integer(strsplit(value("ncomp", "2,5,10,20"), ",", fixed = TRUE)[[1L]])))
components <- components[is.finite(components) & components > 0L]
reps <- max(1L, as.integer(value("reps", "3")))
seed <- as.integer(value("seed", "123"))
use_cuda <- isTRUE(has_cuda()) && isTRUE(fastPLS:::lda_cuda_native_available())

legacy_lda <- function(scores, labels, n_classes, k) {
  scores <- scores[, seq_len(k), drop = FALSE]
  counts <- as.numeric(tabulate(labels, nbins = n_classes))
  class_sums <- rowsum(scores, labels, reorder = TRUE)
  class_sums <- class_sums[as.character(seq_len(n_classes)), , drop = FALSE]
  means <- class_sums / counts
  pooled <- crossprod(scores)
  for (cls in seq_len(n_classes)) {
    pooled <- pooled - counts[[cls]] * tcrossprod(means[cls, ])
  }
  pooled <- pooled / max(1, nrow(scores) - n_classes)
  scale <- sum(diag(pooled)) / k
  if (!is.finite(scale) || scale <= 0) scale <- 1
  lambda <- 1e-8 * scale
  diag(pooled) <- diag(pooled) + lambda
  inverse <- tryCatch(solve(pooled), error = function(e) qr.solve(pooled))
  linear <- means %*% inverse
  priors <- counts / sum(counts)
  constants <- -0.5 * rowSums(means * linear) + log(pmax(priors, .Machine$double.xmin))
  list(linear = linear, constants = constants, ridge = lambda)
}

legacy_predict <- function(scores, model, k) {
  max.col(
    sweep(scores[, seq_len(k), drop = FALSE] %*% t(model$linear),
          2L, model$constants, "+", check.margin = FALSE),
    ties.method = "first"
  )
}

numeric_scores <- function(bits) {
  fastPLS:::.float32_to_numeric_matrix(methods::new("float32", Data = bits))
}

accuracy <- function(observed, codes, levels) {
  mean(as.character(observed) == levels[as.integer(codes)])
}

fit_score_space <- function(task, method) {
  fit <- pls(
    float::fl(task$Xtrain), task$Ytrain,
    ncomp = components, method = method, backend = "cpu",
    svd.method = "rsvd", classifier = "argmax", seed = seed,
    return_variance = FALSE
  )
  fit <- fastPLS:::.fastpls_restore_internal_output_fields(fit)
  effective <- sort(unique(as.integer(fit$ncomp)))
  kmax <- max(effective)
  list(
    model = fit,
    effective = effective,
    train = fastPLS:::.float32_train_scores(fit, float::fl(task$Xtrain))[, seq_len(kmax), drop = FALSE],
    test = fastPLS:::.float32_train_scores(fit, float::fl(task$Xtest))[, seq_len(kmax), drop = FALSE]
  )
}

run_head <- function(task, method) {
  latent <- fit_score_space(task, method)
  train_num <- fastPLS:::.float32_to_numeric_matrix(latent$train)
  test_num <- fastPLS:::.float32_to_numeric_matrix(latent$test)
  levels <- latent$model$lev
  labels <- as.integer(factor(task$Ytrain, levels = levels))
  rows <- list()
  row_id <- 1L
  legacy_predictions <- list()

  for (k in latent$effective) {
    old <- legacy_lda(train_num, labels, length(levels), k)
    legacy_predictions[[as.character(k)]] <- legacy_predict(test_num, old, k)
  }

  variants <- c("legacy_inverse", "candidate_cpu_float32")
  if (use_cuda) variants <- c(variants, "candidate_cuda_float32")
  for (variant in variants) {
    for (replicate in seq_len(reps)) {
      for (k in latent$effective) {
        gc(FALSE)
        started <- proc.time()[["elapsed"]]
        result <- tryCatch({
          if (identical(variant, "legacy_inverse")) {
            model <- legacy_lda(train_num, labels, length(levels), k)
            pred <- legacy_predict(test_num, model, k)
            rho <- 1e-8
          } else {
            train_fun <- if (identical(variant, "candidate_cuda_float32"))
              fastPLS:::lda_train_prefix_float32_cuda else
              fastPLS:::lda_train_prefix_float32_cpp
            predict_fun <- if (identical(variant, "candidate_cuda_float32"))
              fastPLS:::lda_predict_float32_cuda else
              fastPLS:::lda_predict_float32_cpp
            model <- train_fun(latent$train[, seq_len(k), drop = FALSE],
                               labels, length(levels), k)[[1L]]
            pred <- predict_fun(latent$test[, seq_len(k), drop = FALSE], model)$pred
            rho <- model$ridge_relative
          }
          list(status = "ok", error = NA_character_, pred = pred, rho = rho)
        }, error = function(e) {
          list(status = "error", error = conditionMessage(e), pred = NULL, rho = NA_real_)
        })
        elapsed <- proc.time()[["elapsed"]] - started
        reference <- legacy_predictions[[as.character(k)]]
        rows[[row_id]] <- data.frame(
          dataset = task$dataset,
          scope = "fixed_score_lda",
          method = method,
          implementation = variant,
          backend = if (grepl("cuda", variant)) "cuda" else "cpu",
          precision = if (grepl("float32", variant)) "float32" else "double",
          replicate = replicate,
          requested_ncomp = k,
          effective_ncomp = k,
          elapsed_sec = elapsed,
          accuracy = if (is.null(result$pred)) NA_real_ else
            accuracy(task$Ytest, result$pred, levels),
          agreement_vs_legacy = if (is.null(result$pred)) NA_real_ else
            mean(result$pred == reference),
          relative_ridge = result$rho,
          n_train = nrow(task$Xtrain), n_test = nrow(task$Xtest),
          p = ncol(task$Xtrain), n_classes = length(levels),
          status = result$status, error = result$error,
          stringsAsFactors = FALSE
        )
        row_id <- row_id + 1L
      }
    }
  }
  do.call(rbind, rows)
}

run_public <- function(task, method) {
  backends <- c("cpu", if (use_cuda) "cuda")
  rows <- list()
  row_id <- 1L
  predictions <- list()
  for (backend in backends) {
    for (replicate in seq_len(reps)) {
      gc(FALSE)
      started <- proc.time()[["elapsed"]]
      result <- tryCatch({
        fit <- pls(
          float::fl(task$Xtrain), task$Ytrain,
          float::fl(task$Xtest), task$Ytest,
          ncomp = components, method = method, backend = backend,
          svd.method = "rsvd", classifier = "lda", seed = seed,
          return_variance = FALSE
        )
        internal <- fastPLS:::.fastpls_restore_internal_output_fields(fit)
        list(status = "ok", error = NA_character_, fit = fit,
             effective = as.integer(internal$ncomp))
      }, error = function(e) {
        list(status = "error", error = conditionMessage(e), fit = NULL,
             effective = integer())
      })
      total_elapsed <- proc.time()[["elapsed"]] - started
      if (is.null(result$fit)) {
        rows[[row_id]] <- data.frame(
          dataset = task$dataset, scope = "public_pls_end_to_end", method = method,
          implementation = paste0("candidate_", backend, "_float32"), backend = backend,
          precision = "float32", replicate = replicate,
          requested_ncomp = max(components), effective_ncomp = NA_integer_,
          elapsed_sec = total_elapsed, accuracy = NA_real_,
          agreement_vs_legacy = NA_real_, relative_ridge = NA_real_,
          n_train = nrow(task$Xtrain), n_test = nrow(task$Xtest),
          p = ncol(task$Xtrain), n_classes = nlevels(task$Ytrain),
          status = result$status, error = result$error
        )
        row_id <- row_id + 1L
        next
      }
      for (index in seq_along(result$effective)) {
        k <- result$effective[[index]]
        pred <- result$fit$Ypred[[index]]
        codes <- as.integer(factor(pred, levels = levels(task$Ytrain)))
        key <- paste(method, k, backend, sep = "|")
        predictions[[key]] <- codes
        cpu_key <- paste(method, k, "cpu", sep = "|")
        rows[[row_id]] <- data.frame(
          dataset = task$dataset, scope = "public_pls_end_to_end", method = method,
          implementation = paste0("candidate_", backend, "_float32"), backend = backend,
          precision = "float32", replicate = replicate,
          requested_ncomp = components[[min(index, length(components))]],
          effective_ncomp = k, elapsed_sec = total_elapsed,
          accuracy = mean(as.character(pred) == as.character(task$Ytest)),
          agreement_vs_legacy = if (identical(backend, "cpu") || is.null(predictions[[cpu_key]]))
            NA_real_ else mean(codes == predictions[[cpu_key]]),
          relative_ridge = NA_real_, n_train = nrow(task$Xtrain),
          n_test = nrow(task$Xtest), p = ncol(task$Xtrain),
          n_classes = nlevels(task$Ytrain), status = "ok", error = NA_character_
        )
        row_id <- row_id + 1L
      }
    }
  }
  do.call(rbind, rows)
}

all_rows <- list()
row_id <- 1L
for (dataset in datasets) {
  message("[", format(Sys.time(), "%F %T"), "] loading ", dataset)
  task <- as_task(find_dataset_rdata(dataset), dataset, split_seed = seed)
  if (!identical(task$task_type, "classification")) next
  for (method in methods) {
    message("[", format(Sys.time(), "%F %T"), "] ", dataset, " / ", method)
    all_rows[[row_id]] <- run_head(task, method); row_id <- row_id + 1L
    all_rows[[row_id]] <- run_public(task, method); row_id <- row_id + 1L
  }
  rm(task); gc()
}

raw <- do.call(rbind, all_rows)
raw_path <- file.path(out_dir, "lda_backend_agreement_raw.csv")
write.csv(raw, raw_path, row.names = FALSE)
groups <- split(raw, interaction(raw$dataset, raw$scope, raw$method,
                                 raw$implementation, raw$effective_ncomp,
                                 drop = TRUE, lex.order = TRUE))
summary <- do.call(rbind, lapply(groups, function(x) {
  valid <- x[x$status == "ok", , drop = FALSE]
  data.frame(
    dataset = x$dataset[[1L]], scope = x$scope[[1L]], method = x$method[[1L]],
    implementation = x$implementation[[1L]], backend = x$backend[[1L]],
    precision = x$precision[[1L]], effective_ncomp = x$effective_ncomp[[1L]],
    median_elapsed_sec = if (nrow(valid)) median(valid$elapsed_sec) else NA_real_,
    accuracy = if (nrow(valid)) median(valid$accuracy) else NA_real_,
    agreement_vs_legacy = if (!nrow(valid) || all(is.na(valid$agreement_vs_legacy)))
      NA_real_ else median(valid$agreement_vs_legacy, na.rm = TRUE),
    numerical_failures = sum(x$status != "ok"), stringsAsFactors = FALSE
  )
}))
row.names(summary) <- NULL
write.csv(summary, file.path(out_dir, "lda_backend_agreement_summary.csv"), row.names = FALSE)
write.csv(raw[raw$status != "ok", , drop = FALSE],
          file.path(out_dir, "lda_backend_agreement_failures.csv"), row.names = FALSE)

eligible <- summary[is.finite(summary$accuracy), , drop = FALSE]
best <- do.call(rbind, lapply(split(eligible, interaction(eligible$dataset,
  eligible$scope, eligible$method, eligible$implementation, drop = TRUE)), function(x) {
  x[order(-x$accuracy, x$effective_ncomp), , drop = FALSE][1L, ]
}))
write.csv(best, file.path(out_dir, "lda_backend_selected_components.csv"), row.names = FALSE)

report <- c(
  "# PLS-LDA backend agreement", "",
  sprintf("Seed: %d; component grid: %s; replicates: %d.",
          seed, paste(components, collapse = ", "), reps),
  sprintf("CUDA native LDA available: %s.", use_cuda), "",
  "The fixed-score comparison isolates the LDA head by giving the legacy inverse",
  "reference and the candidate CPU/CUDA Cholesky implementations identical PLS scores.",
  "The public comparison includes PLS fitting and therefore also captures backend-level",
  "rSVD variation. Failures are retained in the CSV rather than dropped.", "",
  "Regularization uses rho = 1e-8, 1e-6, 1e-5, 1e-4, 1e-3, 1e-2 and",
  "lambda = rho * trace(Sigma) / q, advancing only after Cholesky failure.",
  "Class moments are indexed explicitly by compact class code, so shuffled",
  "sample order cannot permute class means.", "",
  sprintf("Numerical failures: %d.", sum(raw$status != "ok")), "",
  "## Best evaluated component per implementation", "", "```",
  capture.output(print(
    best[, c("dataset", "scope", "method", "implementation",
             "effective_ncomp", "median_elapsed_sec", "accuracy",
             "agreement_vs_legacy", "numerical_failures")],
    row.names = FALSE
  )),
  "```"
)
writeLines(report, file.path(out_dir, "lda_backend_agreement_report.md"))
print(summary, row.names = FALSE)
