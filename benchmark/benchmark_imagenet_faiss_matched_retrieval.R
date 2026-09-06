#!/usr/bin/env Rscript

# Matched exploratory ImageNet retrieval control. Raw DINOv2 and PLS scores
# use the same float32 split, cosine metric, neighbours, and FAISS
# query blocks. The pooled 1,281,167-image feature archive was randomly divided
# into 1,000,000 development-training and 281,167 development-holdout rows with
# seed 123. This is not the canonical ImageNet train/validation split. The
# dimensions and k=10 were fixed for this matched run but were informed by
# earlier exploration on the same holdout, so accuracy is descriptive rather
# than an unbiased external-validation estimate.

setting <- function(name, default) {
  value <- Sys.getenv(name, unset = default)
  if (nzchar(value)) value else default
}

script_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
script_file <- if (length(script_arg)) sub("^--file=", "", script_arg[[1L]]) else "benchmark_imagenet_faiss_matched_retrieval.R"
script_dir <- dirname(normalizePath(script_file, winslash = "/", mustWork = FALSE))

mode <- setting("IMAGENET_RETRIEVAL_MODE", "search")
space <- setting("IMAGENET_RETRIEVAL_SPACE", "raw")
method <- setting("IMAGENET_RETRIEVAL_METHOD", "exact")
task_file <- path.expand(setting(
  "IMAGENET_RETRIEVAL_TASK",
  "~/Documents/fastpls/data/imagenet_float32_seed123_train1000000_task.rds"
))
out_dir <- path.expand(setting(
  "IMAGENET_RETRIEVAL_OUT",
  "~/fastPLS_results_0.99.39/imagenet_faiss"
))
train_n <- as.integer(setting("IMAGENET_RETRIEVAL_TRAIN_N", "1000000"))
eval_n <- as.integer(setting("IMAGENET_RETRIEVAL_EVAL_N", "281167"))
max_ncomp <- as.integer(setting("IMAGENET_RETRIEVAL_MAX_NCOMP", "200"))
ncomp <- as.integer(setting("IMAGENET_RETRIEVAL_NCOMP", "100"))
knn_k <- as.integer(setting("IMAGENET_RETRIEVAL_K", "10"))
block_n <- as.integer(setting("IMAGENET_RETRIEVAL_BLOCK_N", "5000"))
reps <- as.integer(setting("IMAGENET_RETRIEVAL_REPS", "3"))
seed <- as.integer(setting("IMAGENET_RETRIEVAL_SEED", "123"))
label_crossprod_source <- path.expand(setting(
  "IMAGENET_RETRIEVAL_LABEL_CPP",
  file.path(script_dir, "imagenet_label_crossprod_float32.cpp")
))

dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
suppressPackageStartupMessages(library(float))
task <- readRDS(task_file)
stopifnot(train_n <= task$n_train, eval_n <= task$n_test)

msg <- function(...) {
  message(sprintf("[%s] %s", format(Sys.time(), "%F %T"), sprintf(...)))
}

rss_mb <- function(field = "VmHWM") {
  x <- grep(paste0("^", field, ":"), readLines("/proc/self/status", warn = FALSE), value = TRUE)
  if (!length(x)) return(NA_real_)
  as.numeric(sub(".*?([0-9]+)\\s+kB.*", "\\1", x[[1L]])) / 1024
}

timed <- function(expr) {
  start <- proc.time()[["elapsed"]]
  value <- force(expr)
  list(value = value, seconds = proc.time()[["elapsed"]] - start)
}

score_paths <- function(kind) {
  stem <- file.path(out_dir, sprintf("%s_n%d_k%d", kind, train_n, max_ncomp))
  list(
    train = paste0(stem, "_train.rds"),
    test = paste0(stem, "_test.rds"),
    model = paste0(stem, "_model.rds"),
    preparation = paste0(stem, "_preparation.csv")
  )
}

load_train <- function() {
  value <- readRDS(task$Xtrain_rds)
  if (train_n < nrow(value)) value <- value[seq_len(train_n), , drop = FALSE]
  value
}

load_test <- function() {
  value <- readRDS(task$Xtest_rds)
  if (eval_n < nrow(value)) value <- value[seq_len(eval_n), , drop = FALSE]
  value
}

float_sweep <- function(x, value, op) {
  getFromNamespace(".float32_sweep_cols", "fastPLS")(x, value, op)
}

save_preparation <- function(kind, model, train_scores, test_scores, fit_sec,
                             train_projection_sec, test_projection_sec) {
  paths <- score_paths(kind)
  saveRDS(train_scores, paths$train, compress = FALSE)
  saveRDS(test_scores, paths$test, compress = FALSE)
  saveRDS(model, paths$model)
  write.csv(data.frame(
    representation = kind,
    train_n = train_n,
    eval_n = eval_n,
    max_ncomp = max_ncomp,
    precision = "float32",
    backend = "cuda",
    svd_method = "rsvd",
    fit_time_sec = fit_sec,
    train_projection_time_sec = train_projection_sec,
    test_projection_time_sec = test_projection_sec,
    transformation_time_sec = fit_sec + train_projection_sec + test_projection_sec,
    peak_host_rss_mb = rss_mb(),
    stringsAsFactors = FALSE
  ), paths$preparation, row.names = FALSE)
}

prepare_pls <- function() {
  stopifnot(requireNamespace("fastPLS", quietly = TRUE))
  stopifnot(requireNamespace("Rcpp", quietly = TRUE))
  Rcpp::sourceCpp(label_crossprod_source, rebuild = FALSE, showOutput = FALSE)
  Xtrain <- load_train()
  ytrain <- droplevels(task$Ytrain[seq_len(train_n)])
  msg("Fitting float32 CUDA label-aware PLS-SVD/rSVD, n=%d, ncomp=%d",
      train_n, max_ncomp)
  fit_run <- timed({
    y_code <- as.integer(ytrain)
    classes <- levels(ytrain)
    products <- imagenet_label_crossprod_float32(Xtrain, y_code, length(classes))
    center <- float::fl(matrix(products$center, nrow = 1L))
    crosscov <- float::fl(products$crosscov)
    decomposition <- fastPLS::fastsvd(
      crosscov,
      ncomp = max_ncomp,
      backend = "cuda",
      method = "rsvd",
      seed = seed
    )
    list(
      R = decomposition$u[, seq_len(max_ncomp), drop = FALSE],
      mX = center,
      vX = float::fl(matrix(1, nrow = 1L, ncol = ncol(Xtrain))),
      levels = classes,
      svd = decomposition[c("d", "method", "backend", "precision")]
    )
  })
  fit <- fit_run$value
  train_run <- timed({
    projected <- Xtrain %*% fit$R
    offset <- fit$mX %*% fit$R
    float_sweep(projected, offset, "-")
  })
  train_scores <- train_run$value
  rm(Xtrain, ytrain)
  gc()

  Xtest <- load_test()
  test_run <- timed({
    projected <- Xtest %*% fit$R
    offset <- fit$mX %*% fit$R
    float_sweep(projected, offset, "-")
  })
  rm(Xtest)
  gc()
  save_preparation(
    "pls_plssvd", fit, train_scores, test_run$value,
    fit_run$seconds, train_run$seconds, test_run$seconds
  )
}

weighted_vote <- function(indices, distances, labels, truth, levels) {
  codes <- as.integer(labels)
  predicted <- character(nrow(indices))
  top5 <- logical(nrow(indices))
  for (i in seq_len(nrow(indices))) {
    votes <- numeric(length(levels))
    idx <- indices[i, ]
    votes[codes[idx]] <- votes[codes[idx]] + 1 / pmax(distances[i, ], 1e-8)
    rank <- order(votes, decreasing = TRUE)
    predicted[[i]] <- levels[[rank[[1L]]]]
    top5[[i]] <- as.character(truth[[i]]) %in% levels[head(rank, 5L)]
  }
  list(predicted = predicted, top5 = top5)
}

macro_recall <- function(predicted, observed, levels) {
  mean(vapply(levels, function(level) {
    keep <- as.character(observed) == level
    if (any(keep)) mean(predicted[keep] == level) else NA_real_
  }, numeric(1L)), na.rm = TRUE)
}

neighbour_recall <- function(candidate, reference) {
  mean(vapply(seq_len(nrow(reference)), function(i) {
    length(intersect(candidate[i, ], reference[i, ])) / ncol(reference)
  }, numeric(1L)))
}

search_once <- function(Xtrain, Xtest, ytrain, ytest, levels) {
  blocks <- ceiling(nrow(Xtest) / block_n)
  predicted <- vector("list", blocks)
  top5 <- vector("list", blocks)
  indices <- vector("list", blocks)
  first_sec <- NA_real_
  remaining_sec <- 0
  block <- 0L
  for (start in seq.int(1L, nrow(Xtest), by = block_n)) {
    block <- block + 1L
    stop_row <- min(nrow(Xtest), start + block_n - 1L)
    run <- timed(faissR::nn(
      Xtrain,
      Xtest[start:stop_row, , drop = FALSE],
      k = knn_k,
      backend = "cuda",
      method = method,
      metric = "cosine",
      target_recall = 0.99
    ))
    if (block == 1L) first_sec <- run$seconds else remaining_sec <- remaining_sec + run$seconds
    vote <- weighted_vote(
      run$value$indices,
      run$value$distances,
      ytrain,
      ytest[start:stop_row],
      levels
    )
    predicted[[block]] <- vote$predicted
    top5[[block]] <- vote$top5
    indices[[block]] <- run$value$indices
    if (block %% 10L == 0L || block == blocks) {
      msg("%s/%s ncomp=%s repeat block %d/%d", space, method, ncomp, block, blocks)
    }
  }
  list(
    predicted = unlist(predicted, use.names = FALSE),
    top5 = unlist(top5, use.names = FALSE),
    indices = do.call(rbind, indices),
    first_sec = first_sec,
    remaining_sec = remaining_sec,
    search_sec = first_sec + remaining_sec
  )
}

search <- function() {
  stopifnot(requireNamespace("faissR", quietly = TRUE))
  ytrain <- droplevels(task$Ytrain[seq_len(train_n)])
  ytest <- factor(task$Ytest[seq_len(eval_n)], levels = levels(ytrain))
  levels <- levels(ytrain)
  preparation <- data.frame(
    transformation_time_sec = 0,
    fit_time_sec = 0,
    train_projection_time_sec = 0,
    test_projection_time_sec = 0,
    peak_host_rss_mb = NA_real_
  )

  if (space == "raw") {
    Xtrain <- load_train()
    Xtest <- load_test()
    label <- "raw_dinov2"
    components <- NA_integer_
  } else {
    kind <- switch(
      space,
      pls = "pls_plssvd",
      stop("IMAGENET_RETRIEVAL_SPACE must be raw or pls.")
    )
    paths <- score_paths(kind)
    stopifnot(all(file.exists(unlist(paths[c("train", "test", "preparation")]))))
    Xtrain <- readRDS(paths$train)[, seq_len(ncomp), drop = FALSE]
    Xtest <- readRDS(paths$test)[, seq_len(ncomp), drop = FALSE]
    preparation <- read.csv(paths$preparation, stringsAsFactors = FALSE)
    label <- "pls_scores"
    components <- ncomp
  }

  rows <- vector("list", reps)
  exact_path <- file.path(
    out_dir,
    sprintf("%s_n%d_k%s_exact_neighbors.rds", space, train_n,
            ifelse(is.na(components), "raw", components))
  )
  for (replicate in seq_len(reps)) {
    msg("Searching %s, method=%s, replicate=%d/%d", label, method, replicate, reps)
    result <- search_once(Xtrain, Xtest, ytrain, ytest, levels)
    if (method == "exact" && replicate == 1L) {
      saveRDS(result$indices, exact_path, compress = FALSE)
    }
    recall_at_10 <- if (method == "exact") {
      1
    } else if (file.exists(exact_path)) {
      neighbour_recall(result$indices, readRDS(exact_path))
    } else {
      NA_real_
    }
    rows[[replicate]] <- data.frame(
      feature_space = label,
      ncomp = components,
      n_features = ncol(Xtrain),
      compression_ratio = 1024 / ncol(Xtrain),
      precision = "float32",
      train_n = train_n,
      eval_n = eval_n,
      knn_k = knn_k,
      faiss_backend = "cuda",
      faiss_method = method,
      replicate = replicate,
      transformation_time_sec = preparation$transformation_time_sec[[1L]],
      fit_time_sec = preparation$fit_time_sec[[1L]],
      train_projection_time_sec = preparation$train_projection_time_sec[[1L]],
      test_projection_time_sec = preparation$test_projection_time_sec[[1L]],
      index_and_first_query_sec = result$first_sec,
      remaining_query_sec = result$remaining_sec,
      query_time_sec = result$search_sec,
      inference_time_sec = preparation$test_projection_time_sec[[1L]] + result$search_sec,
      end_to_end_time_sec = preparation$transformation_time_sec[[1L]] + result$search_sec,
      top1_accuracy = mean(result$predicted == as.character(ytest)),
      top5_accuracy = mean(result$top5),
      balanced_accuracy = macro_recall(result$predicted, ytest, levels),
      neighbour_recall_at_10 = recall_at_10,
      preparation_peak_host_rss_mb = preparation$peak_host_rss_mb[[1L]],
      search_peak_host_rss_mb = rss_mb(),
      split_role = "exploratory_development_holdout",
      split_is_standard_imagenet = FALSE,
      hyperparameter_selection = paste(
        "k=10 and dimensions 50/100/200 fixed for this matched run;",
        "informed by earlier exploration; no nested validation"
      ),
      status = "success",
      notes = "Single representation fit; repeated FAISS index/query timing.",
      stringsAsFactors = FALSE
    )
  }
  output <- do.call(rbind, rows)
  path <- file.path(
    out_dir,
    sprintf("%s_n%d_k%s_eval%d_cuda_%s.csv", space, train_n,
            ifelse(is.na(components), "raw", components), eval_n, method)
  )
  write.csv(output, path, row.names = FALSE)
  print(output)
}

set.seed(seed)
switch(
  mode,
  prepare_pls = prepare_pls(),
  search = search(),
  stop("Unknown IMAGENET_RETRIEVAL_MODE.")
)
