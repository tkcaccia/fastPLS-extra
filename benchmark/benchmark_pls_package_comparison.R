#!/usr/bin/env Rscript

# Current-release comparison of fastPLS with independent R implementations.
# Each package-method pair runs in an isolated process so unsupported methods,
# timeouts, and memory failures remain explicit in the result table.

options(stringsAsFactors = FALSE)

bench_lib <- Sys.getenv("FASTPLS_BENCH_LIB", "")
if (nzchar(bench_lib) && dir.exists(bench_lib)) {
  .libPaths(unique(c(normalizePath(bench_lib, winslash = "/", mustWork = TRUE), .libPaths())))
}

parse_args <- function(args = commandArgs(trailingOnly = TRUE)) {
  out <- list()
  for (arg in args) {
    if (!startsWith(arg, "--")) next
    kv <- substring(arg, 3L)
    bits <- strsplit(kv, "=", fixed = TRUE)[[1L]]
    key <- gsub("-", "_", bits[[1L]], fixed = TRUE)
    val <- if (length(bits) > 1L) paste(bits[-1L], collapse = "=") else "TRUE"
    out[[key]] <- val
  }
  out
}

args <- parse_args()
arg <- function(key, default = NULL) {
  val <- args[[key]]
  if (is.null(val) || !nzchar(val)) default else val
}

`%||%` <- function(a, b) if (is.null(a)) b else a

script_file <- grep("^--file=", commandArgs(FALSE), value = TRUE)
script_file <- if (length(script_file)) sub("^--file=", "", script_file[[1L]]) else "benchmark_pls_package_comparison.R"
repo_root <- normalizePath(file.path(dirname(script_file), ".."), winslash = "/", mustWork = FALSE)

mode <- arg("mode", "run_one")
dataset_id <- tolower(arg("dataset", "singlecell"))
ncomp_requested <- as.integer(arg("ncomp", if (dataset_id == "nmr") "100" else "50"))
if (!is.finite(ncomp_requested) || is.na(ncomp_requested) || ncomp_requested < 1L) ncomp_requested <- 50L
split_seed <- as.integer(arg("seed", "123"))
if (!is.finite(split_seed) || is.na(split_seed)) split_seed <- 123L
method_id <- arg("method_id", "")
replicate_id <- as.integer(arg("replicate", "1"))
if (!is.finite(replicate_id) || is.na(replicate_id)) replicate_id <- 1L
row_out <- arg("row_out", "")
results_dir <- arg("results_dir", getwd())
status_override <- arg("status", "")
message_override <- arg("message", "")

base_method_ids <- c(
  "fastPLS_simpls_cpu_rsvd", "fastPLS_plssvd_cpu_rsvd", "fastPLS_opls_cpu_rsvd", "fastPLS_kernelpls_cpu_rsvd",
  "fastPLS_simpls_cuda_rsvd", "fastPLS_plssvd_cuda_rsvd", "fastPLS_opls_cuda_rsvd", "fastPLS_kernelpls_cuda_rsvd",
  "pls_simpls_fit", "pls_oscorespls_fit", "pls_kernelpls_fit",
  "mdatools_plsda_or_pls", "plsdepot_simpls", "pcv_simpls",
  "plsgenomics_pls_regression", "mixOmics_pls", "chemometrics_pls_eigen",
  "chemometrics_pls2_nipals", "spls_spls", "ropls_pls", "ropls_opls"
)
classification_only_method_ids <- c(
  "fastPLS_simpls_cpu_rsvd_lda", "fastPLS_plssvd_cpu_rsvd_lda",
  "fastPLS_opls_cpu_rsvd_lda", "fastPLS_kernelpls_cpu_rsvd_lda",
  "fastPLS_simpls_cuda_rsvd_lda", "fastPLS_plssvd_cuda_rsvd_lda",
  "fastPLS_opls_cuda_rsvd_lda", "fastPLS_kernelpls_cuda_rsvd_lda",
  "plsgenomics_pls_lda", "mixOmics_plsda", "mixOmics_splsda", "spls_splsda"
)

if (identical(mode, "list_methods")) {
  classification_dataset_ids <- c(
    "ccle", "cifar100", "gtex_v8", "imagenet",
    "metref", "retina", "singlecell", "tabula", "tcga_brca", "tcga_hnsc_methylation",
    "tcga_pan_cancer"
  )
  regression_dataset_ids <- c("cbmc_citeseq", "nmr", "prism")
  is_classification <- dataset_id %in% classification_dataset_ids ||
    grepl("^class", dataset_id) || grepl("classification", dataset_id)
  if (dataset_id %in% regression_dataset_ids ||
      grepl("^reg", dataset_id) || grepl("regression", dataset_id)) {
    is_classification <- FALSE
  }
  method_ids <- base_method_ids
  if (isTRUE(is_classification)) {
    method_ids <- c(method_ids, classification_only_method_ids)
  }
  cat(paste(method_ids, collapse = "\n"))
  cat("\n")
  quit(status = 0)
}

source(file.path(repo_root, "benchmark", "helpers_dataset_memory_compare.R"))

quiet_require <- function(pkg) {
  suppressPackageStartupMessages(requireNamespace(pkg, quietly = TRUE))
}

package_version_chr <- function(pkg) {
  if (!quiet_require(pkg)) return(NA_character_)
  as.character(utils::packageVersion(pkg))
}

load_compare_task <- function(dataset_id, split_seed) {
  task_root <- Sys.getenv("FASTPLS_TASK_ROOT", "")
  task_path <- if (nzchar(task_root)) {
    file.path(task_root, paste0(dataset_id, "_task.rds"))
  } else {
    ""
  }
  if (nzchar(task_path) && file.exists(task_path)) {
    task <- readRDS(task_path)
  } else {
    path <- find_dataset_rdata(dataset_id)
    task <- as_task(path, dataset_id = dataset_id, split_seed = split_seed)
  }
  task <- validate_publication_task(task, dataset_id)
  precision <- tolower(Sys.getenv("FASTPLS_BENCH_PRECISION", "float64"))
  task <- coerce_task_precision(task, precision = precision)
  if (identical(task$task_type, "classification")) {
    task$Ytrain <- droplevels(as.factor(task$Ytrain))
    task$Ytest <- factor(task$Ytest, levels = levels(task$Ytrain))
    if (anyNA(task$Ytest)) {
      stop(
        "Held-out labels contain classes absent from training for ",
        dataset_id, "; no samples were removed.",
        call. = FALSE
      )
    }
    task$n_classes <- nlevels(task$Ytrain)
  } else {
    task$Ytrain <- coerce_benchmark_matrix(task$Ytrain, precision)
    task$Ytest <- coerce_benchmark_matrix(task$Ytest, precision)
    task$n_classes <- ncol(task$Ytrain)
  }
  task
}

task <- load_compare_task(dataset_id, split_seed)
task_type <- task$task_type
Xtrain <- if (is_float32_matrix(task$Xtrain)) float::dbl(task$Xtrain) else as.matrix(task$Xtrain)
Xtest <- if (is_float32_matrix(task$Xtest)) float::dbl(task$Xtest) else as.matrix(task$Xtest)
Ytrain <- if (is_float32_matrix(task$Ytrain)) float::dbl(task$Ytrain) else task$Ytrain
Ytest <- if (is_float32_matrix(task$Ytest)) float::dbl(task$Ytest) else task$Ytest

if (identical(task_type, "classification")) {
  class_levels <- levels(Ytrain)
  Ytrain_dummy <- stats::model.matrix(~ Ytrain - 1)
  colnames(Ytrain_dummy) <- class_levels
} else {
  class_levels <- NULL
  Ytrain_dummy <- as.matrix(Ytrain)
}

decode_scores <- function(scores, levels = class_levels) {
  scores <- as.matrix(scores)
  if (!nrow(scores)) stop("Prediction score matrix has zero rows.")
  if (ncol(scores) == 1L) {
    if (length(levels) < 2L) stop("Cannot decode one-column classification scores.")
    return(factor(ifelse(scores[, 1L] >= 0.5, levels[2L], levels[1L]), levels = levels))
  }
  factor(levels[max.col(scores, ties.method = "first")], levels = levels)
}

last_component_matrix <- function(x, ncomp_eff = ncomp_requested, n_response = task$n_classes) {
  if (is.null(x)) stop("No prediction matrix/array supplied.")
  if (length(dim(x)) == 3L) {
    d <- dim(x)
    dn <- dimnames(x)
    names2 <- tolower(dn[[2L]] %||% character())
    names3 <- tolower(dn[[3L]] %||% character())
    response_names <- tolower(colnames(Ytrain_dummy) %||% character())
    dim2_is_comp <- length(names2) && any(grepl("^comp", names2))
    dim3_is_comp <- length(names3) && any(grepl("^comp", names3))
    dim2_is_response <- length(names2) && all(names2 %in% response_names)
    dim3_is_response <- length(names3) && all(names3 %in% response_names)
    if (isTRUE(dim2_is_comp) || (d[3L] == n_response && !isTRUE(dim2_is_response))) {
      ncomp_eff <- as.integer(min(ncomp_eff, d[2L]))
      return(as.matrix(x[, ncomp_eff, , drop = TRUE]))
    }
    if (isTRUE(dim3_is_comp) || isTRUE(dim2_is_response) || d[2L] == n_response) {
      ncomp_eff <- as.integer(min(ncomp_eff, d[3L]))
      return(as.matrix(x[, , ncomp_eff, drop = TRUE]))
    }
    if (d[2L] >= min(ncomp_eff, d[2L])) return(as.matrix(x[, min(ncomp_eff, d[2L]), , drop = TRUE]))
    return(as.matrix(x[, , min(ncomp_eff, d[3L]), drop = TRUE]))
  }
  as.matrix(x)
}

metric_from_prediction <- function(pred) {
  if (identical(task_type, "classification")) {
    pred <- factor(pred, levels = levels(Ytest))
    acc <- mean(as.character(pred) == as.character(Ytest), na.rm = TRUE)
    secondary <- classification_secondary_metrics(Ytest, pred)
    return(list(metric_name = "accuracy", metric_value = acc, accuracy = acc,
                balanced_accuracy = secondary$balanced_accuracy,
                macro_f1 = secondary$macro_f1,
                rmse = NA_real_, q2 = NA_real_, mae = NA_real_))
  }
  pred <- as.matrix(pred)
  obs <- as.matrix(Ytest)
  if (!all(dim(pred) == dim(obs))) {
    pred <- matrix(pred, nrow = nrow(obs), ncol = ncol(obs))
  }
  err <- obs - pred
  rmse <- sqrt(mean(err^2, na.rm = TRUE))
  mae <- mean(abs(err), na.rm = TRUE)
  denom <- sum((obs - matrix(colMeans(Ytrain), nrow(obs), ncol(obs), byrow = TRUE))^2, na.rm = TRUE)
  q2 <- if (is.finite(denom) && denom > 0) 1 - sum(err^2, na.rm = TRUE) / denom else NA_real_
  if (ncol(obs) == 1L) {
    list(metric_name = "q2", metric_value = q2, accuracy = NA_real_,
         rmse = rmse, q2 = q2, mae = mae)
  } else {
    list(metric_name = "rmsd", metric_value = rmse, accuracy = NA_real_,
         rmse = rmse, q2 = q2, mae = mae)
  }
}

predict_from_pls_fit <- function(fit, Xnew, ncomp_eff) {
  ncomp_eff <- min(as.integer(ncomp_eff), dim(fit$coefficients)[3L])
  coef <- fit$coefficients[, , ncomp_eff, drop = TRUE]
  if (is.null(dim(coef))) coef <- matrix(coef, ncol = ncol(Ytrain_dummy))
  Xc <- sweep(as.matrix(Xnew), 2L, fit$Xmeans, "-")
  pred <- Xc %*% coef
  pred <- sweep(pred, 2L, fit$Ymeans, "+")
  if (identical(task_type, "classification")) decode_scores(pred) else pred
}

extract_prediction_generic <- function(obj, Xnew = Xtest) {
  pred_obj <- tryCatch(stats::predict(obj, Xnew), error = function(e) NULL)
  if (is.null(pred_obj)) pred_obj <- obj
  candidates <- list(
    pred_obj$predclass, pred_obj$Ypred, pred_obj$ypred, pred_obj$y.pred,
    pred_obj$p.pred, pred_obj$c.pred, pred_obj$pred, pred_obj$prediction,
    pred_obj$y.hat, pred_obj$class, pred_obj$classes, pred_obj$predict
  )
  for (cand in candidates) {
    if (is.null(cand)) next
    if (is.list(cand) && !is.data.frame(cand)) {
      for (part in cand) {
        if (is.matrix(part) || is.array(part) || is.data.frame(part) ||
            is.factor(part) || is.character(part) || is.numeric(part)) {
          cand <- part
          break
        }
      }
    }
    if (identical(task_type, "classification")) {
      if (is.factor(cand) || is.character(cand)) return(factor(cand, levels = levels(Ytest)))
      if (is.data.frame(cand)) {
        if (ncol(cand) == 1L) return(factor(cand[[1L]], levels = levels(Ytest)))
        return(decode_scores(as.matrix(cand)))
      }
      if (is.matrix(cand) || is.array(cand)) return(decode_scores(last_component_matrix(cand)))
    } else {
      if (is.data.frame(cand)) cand <- as.matrix(cand)
      if (is.matrix(cand) || is.array(cand) || is.numeric(cand)) {
        mat <- if (is.array(cand)) last_component_matrix(cand, n_response = ncol(Ytrain_dummy)) else as.matrix(cand)
        if (nrow(mat) == nrow(Ytest)) return(mat)
      }
    }
  }
  if (identical(task_type, "classification")) {
    if (is.factor(pred_obj) || is.character(pred_obj)) return(factor(pred_obj, levels = levels(Ytest)))
    if (is.matrix(pred_obj) || is.array(pred_obj)) return(decode_scores(last_component_matrix(pred_obj)))
  } else if (is.matrix(pred_obj) || is.array(pred_obj) || is.numeric(pred_obj)) {
    mat <- if (is.array(pred_obj)) last_component_matrix(pred_obj, n_response = ncol(Ytrain_dummy)) else as.matrix(pred_obj)
    if (nrow(mat) == nrow(Ytest)) return(mat)
  }
  stop("Could not decode predictions from object of class: ", paste(class(pred_obj), collapse = ","))
}

decode_fastpls <- function(model) {
  # `pls()` returns its public result as a list when Xtest is supplied.  In
  # that case predictions are already present and the list is not an S3 model
  # object for a second predict() call.
  pred <- if (!is.null(model$Ypred)) {
    model$Ypred
  } else {
    predict(model, task$Xtest, Ytest = task$Ytest, backend = "cpu")$Ypred
  }
  if (identical(task_type, "classification")) {
    if (is.data.frame(pred)) return(factor(pred[[ncol(pred)]], levels = levels(Ytest)))
    if (is.factor(pred) || is.character(pred)) return(factor(pred, levels = levels(Ytest)))
    if (is.matrix(pred) || is.array(pred)) return(decode_scores(last_component_matrix(pred)))
  }
  if (is.array(pred)) return(last_component_matrix(pred, n_response = ncol(Ytrain_dummy)))
  as.matrix(pred)
}

run_fastpls <- function(method_name,
                        backend = "cpu",
                        svd_method = "rsvd",
                        classifier = "argmax") {
  args <- list(
    Xtrain = task$Xtrain, Ytrain = task$Ytrain,
    Xtest = task$Xtest, Ytest = task$Ytest,
    ncomp = ncomp_requested, method = method_name, backend = backend,
    svd.method = svd_method, scaling = "centering", fit = FALSE, proj = FALSE,
    seed = 123L + replicate_id, classifier = classifier
  )
  if (identical(method_name, "opls")) args$north <- min(1L, max(0L, ncomp_requested - 1L))
  fastPLS::pls(
    args$Xtrain, args$Ytrain, args$Xtest, args$Ytest,
    ncomp = args$ncomp, method = args$method, backend = args$backend,
    svd.method = args$svd.method, scaling = args$scaling, fit = args$fit,
    proj = args$proj, seed = args$seed, north = args$north %||% 1L,
    return_variance = FALSE,
    classifier = args$classifier
  )
}

run_pls_fit <- function(fit_fun) {
  fit <- fit_fun(Xtrain, Ytrain_dummy, ncomp = ncomp_requested)
  list(fit = fit, pred = predict_from_pls_fit(fit, Xtest, ncomp_requested))
}

runner_mdatools <- function() {
  ns <- asNamespace("mdatools")
  if (identical(task_type, "classification") && exists("plsda", envir = ns, inherits = FALSE)) {
    f <- get("plsda", envir = ns)
    fit <- tryCatch(
      f(Xtrain, Ytrain, ncomp = ncomp_requested, center = TRUE, scale = FALSE, cv = NULL),
      error = function(e) f(Xtrain, Ytrain, ncomp = ncomp_requested, center = TRUE, scale = FALSE)
    )
    pred_obj <- stats::predict(fit, Xtest)
    scores <- pred_obj$p.pred %||% pred_obj$c.pred
    return(list(fit = fit, pred = decode_scores(last_component_matrix(scores))))
  }
  f <- get("pls", envir = ns)
  fit <- tryCatch(
    f(Xtrain, Ytrain_dummy, ncomp = ncomp_requested, center = TRUE, scale = FALSE, method = "simpls", cv = NULL),
    error = function(e) f(Xtrain, Ytrain_dummy, ncomp = ncomp_requested, center = TRUE, scale = FALSE)
  )
  list(fit = fit, pred = extract_prediction_generic(fit))
}

runner_plsgenomics_regression <- function() {
  f <- get("pls.regression", envir = asNamespace("plsgenomics"))
  fit <- f(Xtrain, Ytrain_dummy, Xtest = Xtest, ncomp = ncomp_requested)
  pred <- fit$Ypred %||% fit$y.pred %||% fit$pred
  if (identical(task_type, "classification")) {
    list(fit = fit, pred = decode_scores(last_component_matrix(pred)))
  } else {
    list(fit = fit, pred = last_component_matrix(pred, n_response = ncol(Ytrain_dummy)))
  }
}

runner_plsgenomics_lda <- function() {
  f <- get("pls.lda", envir = asNamespace("plsgenomics"))
  fit <- f(Xtrain, Ytrain, Xtest = Xtest, ncomp = ncomp_requested, nruncv = 0)
  list(fit = fit, pred = factor(fit$predclass, levels = levels(Ytest)))
}

runner_chemometrics_pls2_nipals <- function() {
  Xc <- scale(Xtrain, center = TRUE, scale = FALSE)
  Xm <- attr(Xc, "scaled:center")
  Yc <- scale(Ytrain_dummy, center = TRUE, scale = FALSE)
  Ym <- attr(Yc, "scaled:center")
  fit <- chemometrics::pls2_nipals(Xc, Yc, a = ncomp_requested, scale = FALSE)
  pred <- sweep(as.matrix(Xtest), 2L, Xm, "-") %*% fit$B
  pred <- sweep(pred, 2L, Ym, "+")
  list(fit = fit, pred = if (identical(task_type, "classification")) decode_scores(pred) else pred)
}

runner_chemometrics_pls_eigen <- function() {
  Xc <- scale(Xtrain, center = TRUE, scale = FALSE)
  Xm <- attr(Xc, "scaled:center")
  Yc <- scale(Ytrain_dummy, center = TRUE, scale = FALSE)
  Ym <- attr(Yc, "scaled:center")
  # chemometrics::pls_eigen indexes the response-side latent dimension directly
  # and fails when a exceeds q. Use the largest valid component count for this
  # package rather than turning a package cap into an adapter error.
  ncomp_eff <- min(ncomp_requested, ncol(Yc), nrow(Xc) - 1L, ncol(Xc))
  fit <- chemometrics::pls_eigen(Xc, Yc, a = ncomp_eff)
  coef_t <- solve(crossprod(fit$T), crossprod(fit$T, Yc))
  pred <- (sweep(as.matrix(Xtest), 2L, Xm, "-") %*% fit$P) %*% coef_t
  pred <- sweep(pred, 2L, Ym, "+")
  list(fit = fit, pred = if (identical(task_type, "classification")) decode_scores(pred) else pred)
}

runner_mixomics_plsda <- function(sparse = FALSE) {
  if (!identical(task_type, "classification")) stop("mixOmics PLS-DA requires classification data.")
  if (isTRUE(sparse)) {
    fit <- mixOmics::splsda(Xtrain, Ytrain, ncomp = ncomp_requested,
                            keepX = rep(ncol(Xtrain), ncomp_requested), scale = FALSE)
  } else {
    fit <- mixOmics::plsda(Xtrain, Ytrain, ncomp = ncomp_requested, scale = FALSE)
  }
  pred_obj <- stats::predict(fit, Xtest)
  comp <- min(ncomp_requested, ncol(pred_obj$class$max.dist))
  list(fit = fit, pred = factor(pred_obj$class$max.dist[, comp], levels = levels(Ytest)))
}

runner_mixomics_pls <- function() {
  fit <- mixOmics::pls(Xtrain, Ytrain_dummy, ncomp = ncomp_requested,
                       scale = FALSE, mode = "regression")
  pred_obj <- stats::predict(fit, Xtest)
  pred <- last_component_matrix(pred_obj$predict, n_response = ncol(Ytrain_dummy))
  list(fit = fit, pred = if (identical(task_type, "classification")) decode_scores(pred) else pred)
}

runner_spls <- function(sparse_da = FALSE) {
  if (isTRUE(sparse_da)) {
    if (!identical(task_type, "classification")) stop("splsda requires classification data.")
    fit <- spls::splsda(Xtrain, Ytrain, K = ncomp_requested, eta = 0.9,
                        classifier = "lda", scale.x = FALSE)
    pred <- stats::predict(fit, Xtest)
    return(list(fit = fit, pred = factor(pred, levels = levels(Ytest))))
  }
  fit <- spls::spls(Xtrain, Ytrain_dummy, K = ncomp_requested, eta = 0.9,
                    scale.x = FALSE, scale.y = FALSE, fit = "simpls")
  pred <- stats::predict(fit, Xtest)
  list(fit = fit, pred = if (identical(task_type, "classification")) decode_scores(pred) else as.matrix(pred))
}

predict_from_scores_weights <- function(fit, Xfit, Yfit, Xnew, Ym) {
  if (!is.null(fit$R) && !is.null(fit$C)) {
    R <- as.matrix(fit$R)
    C <- as.matrix(fit$C)
    k <- min(ncomp_requested, ncol(R), ncol(C))
    pred <- as.matrix(Xnew) %*% R[, seq_len(k), drop = FALSE] %*%
      t(C[, seq_len(k), drop = FALSE])
    return(sweep(pred, 2L, Ym, "+"))
  }
  Tscore <- fit$x.scores %||% fit$scores %||% fit$T
  W <- fit$x.wgs %||% fit$weights %||% fit$W
  if (is.null(Tscore) || is.null(W)) {
    stop("SIMPLS fit did not expose X scores and X weights.")
  }
  Tscore <- as.matrix(Tscore)
  W <- as.matrix(W)
  k <- min(ncomp_requested, ncol(Tscore), ncol(W))
  Tscore <- Tscore[, seq_len(k), drop = FALSE]
  W <- W[, seq_len(k), drop = FALSE]
  P <- crossprod(Xfit, Tscore) %*% solve(crossprod(Tscore))
  Q <- crossprod(Yfit, Tscore) %*% solve(crossprod(Tscore))
  B <- W %*% solve(crossprod(P, W)) %*% t(Q)
  pred <- as.matrix(Xnew) %*% B
  sweep(pred, 2L, Ym, "+")
}

runner_plsdepot_simpls <- function() {
  f <- get("simpls", envir = asNamespace("plsdepot"))
  keep <- vapply(seq_len(ncol(Xtrain)), function(j) {
    x <- Xtrain[, j]
    all(is.finite(x)) && stats::sd(x) > sqrt(.Machine$double.eps)
  }, logical(1))
  if (!any(keep)) stop("package_limit: plsdepot::simpls has no finite non-constant predictor columns.")
  Xtrain_use <- Xtrain[, keep, drop = FALSE]
  Xtest_use <- Xtest[, keep, drop = FALSE]
  Xc <- scale(Xtrain_use, center = TRUE, scale = FALSE)
  Xm <- attr(Xc, "scaled:center")
  Yc <- scale(Ytrain_dummy, center = TRUE, scale = FALSE)
  Ym <- attr(Yc, "scaled:center")
  fit <- f(as.matrix(Xc), as.matrix(Yc), comps = ncomp_requested)
  pred <- predict_from_scores_weights(
    fit, as.matrix(Xc), as.matrix(Yc),
    sweep(as.matrix(Xtest_use), 2L, Xm, "-"), Ym
  )
  list(fit = fit, pred = if (identical(task_type, "classification")) decode_scores(pred) else pred)
}

runner_pcv_simpls <- function() {
  f <- get("simpls", envir = asNamespace("pcv"))
  Xc <- scale(Xtrain, center = TRUE, scale = FALSE)
  Xm <- attr(Xc, "scaled:center")
  Yc <- scale(Ytrain_dummy, center = TRUE, scale = FALSE)
  Ym <- attr(Yc, "scaled:center")
  fit <- f(as.matrix(Xc), as.matrix(Yc), ncomp = ncomp_requested)
  pred <- predict_from_scores_weights(
    fit, as.matrix(Xc), as.matrix(Yc),
    sweep(as.matrix(Xtest), 2L, Xm, "-"), Ym
  )
  list(fit = fit, pred = if (identical(task_type, "classification")) decode_scores(pred) else pred)
}

runner_ropls <- function(orthoI = 0L) {
  if (identical(task_type, "classification") && nlevels(Ytrain) > 2L) {
    if (orthoI > 0L) {
      stop("package_limit: ropls OPLS-DA is only available for binary classification.")
    }
    stop("package_limit: ropls PLS-DA adapter is not stable for this multiclass benchmark.")
  }
  f <- get("opls", envir = asNamespace("ropls"))
  fit <- tryCatch(
    f(
      x = Xtrain, y = if (identical(task_type, "classification")) Ytrain else Ytrain_dummy,
      predI = ncomp_requested, orthoI = orthoI, crossvalI = 0, permI = 0,
      scaleC = "center", fig.pdfC = "none", info.txtC = "none"
    ),
    error = function(e) {
      stop(
        "package_limit: ropls could not complete this configured PLS/OPLS fit: ",
        conditionMessage(e),
        call. = FALSE
      )
    }
  )
  pred <- stats::predict(fit, Xtest)
  if (identical(task_type, "classification")) {
    if (is.factor(pred) || is.character(pred)) return(list(fit = fit, pred = factor(pred, levels = levels(Ytest))))
    return(list(fit = fit, pred = decode_scores(pred)))
  }
  list(fit = fit, pred = as.matrix(pred))
}

runner_simple_named <- function(pkg, fun_name) {
  ns <- asNamespace(pkg)
  f <- get(fun_name, envir = ns)
  attempts <- list(
    function() f(Xtrain, Ytrain_dummy, ncomp = ncomp_requested, center = TRUE, scale = FALSE),
    function() f(Xtrain, Ytrain_dummy, comps = ncomp_requested, center = TRUE, scale = FALSE),
    function() f(x = Xtrain, y = Ytrain_dummy, ncomp = ncomp_requested, center = TRUE, scale = FALSE),
    function() f(X = Xtrain, Y = Ytrain_dummy, ncomp = ncomp_requested, center = TRUE, scale = FALSE),
    function() f(Xtrain, Ytrain_dummy, ncomp = ncomp_requested),
    function() f(Xtrain, Ytrain_dummy, comps = ncomp_requested),
    function() f(Xtrain, Ytrain_dummy, ncomp_requested)
  )
  last <- NULL
  for (attempt in attempts) {
    fit <- tryCatch(attempt(), error = function(e) {
      last <<- conditionMessage(e)
      NULL
    })
    if (!is.null(fit)) return(list(fit = fit, pred = extract_prediction_generic(fit)))
  }
  stop(last %||% "No compatible call signature found.")
}

fastpls_spec <- function(id_suffix, method_name, backend, svd_method,
                         classifier = "argmax", algorithm_label = NULL) {
  classifier_label <- if (identical(classifier, "argmax")) "" else paste0(" + ", toupper(classifier))
  algorithm_label <- algorithm_label %||% paste0(toupper(method_name), classifier_label)
  list(
    id = paste0("fastPLS_", method_name, "_", id_suffix),
    package = "fastPLS",
    algorithm = algorithm_label,
    function_name = sprintf(
      "fastPLS::pls(method='%s', backend='%s', svd.method='%s', classifier='%s')",
      method_name, backend, svd_method, classifier
    ),
    runner = function() {
      list(
        fit = run_fastpls(
          method_name,
          backend = backend,
          svd_method = svd_method,
          classifier = classifier
        ),
        pred = NULL
      )
    },
    decoder = decode_fastpls
  )
}

fastpls_method_specs <- function(classification = FALSE) {
  methods <- c("simpls", "plssvd", "opls", "kernelpls")
  labels <- c(simpls = "SIMPLS", plssvd = "PLSSVD", opls = "OPLS", kernelpls = "kernel PLS")
  specs <- list()
  for (method_name in methods) {
    specs[[length(specs) + 1L]] <- fastpls_spec("cpu_rsvd", method_name, "cpu", "rsvd", "argmax", labels[[method_name]])
    specs[[length(specs) + 1L]] <- fastpls_spec("cuda_rsvd", method_name, "cuda", "rsvd", "argmax", labels[[method_name]])
    if (isTRUE(classification)) {
      specs[[length(specs) + 1L]] <- fastpls_spec("cpu_rsvd_lda", method_name, "cpu", "rsvd", "lda", paste0(labels[[method_name]], " + LDA"))
      specs[[length(specs) + 1L]] <- fastpls_spec("cuda_rsvd_lda", method_name, "cuda", "rsvd", "lda", paste0(labels[[method_name]], " + LDA"))
    }
  }
  specs
}

method_specs_all <- function(task_type) {
  specs <- c(
    fastpls_method_specs(identical(task_type, "classification")),
    list(
    list(id = "pls_simpls_fit", package = "pls", algorithm = "SIMPLS",
         function_name = "pls::simpls.fit", runner = function() run_pls_fit(pls::simpls.fit)),
    list(id = "pls_oscorespls_fit", package = "pls", algorithm = "NIPALS/oscores PLS",
         function_name = "pls::oscorespls.fit", runner = function() run_pls_fit(pls::oscorespls.fit)),
    list(id = "pls_kernelpls_fit", package = "pls", algorithm = "kernel PLS",
         function_name = "pls::kernelpls.fit", runner = function() run_pls_fit(pls::kernelpls.fit)),
    list(id = "mdatools_plsda_or_pls", package = "mdatools", algorithm = "SIMPLS/PLS-DA",
         function_name = "mdatools::plsda or mdatools::pls", runner = runner_mdatools),
    list(id = "plsdepot_simpls", package = "plsdepot", algorithm = "SIMPLS",
         function_name = "plsdepot::simpls", runner = runner_plsdepot_simpls),
    list(id = "pcv_simpls", package = "pcv", algorithm = "SIMPLS",
         function_name = "pcv:::simpls", runner = runner_pcv_simpls),
    list(id = "plsgenomics_pls_regression", package = "plsgenomics", algorithm = "PLS regression",
         function_name = "plsgenomics::pls.regression", runner = runner_plsgenomics_regression),
    list(id = "mixOmics_pls", package = "mixOmics", algorithm = "PLS regression",
         function_name = "mixOmics::pls", runner = runner_mixomics_pls),
    list(id = "chemometrics_pls_eigen", package = "chemometrics", algorithm = "PLS eigen",
         function_name = "chemometrics::pls_eigen", runner = runner_chemometrics_pls_eigen),
    list(id = "chemometrics_pls2_nipals", package = "chemometrics", algorithm = "PLS2 NIPALS",
         function_name = "chemometrics::pls2_nipals", runner = runner_chemometrics_pls2_nipals),
    list(id = "spls_spls", package = "spls", algorithm = "sPLS regression",
         function_name = "spls::spls", runner = function() runner_spls(FALSE)),
    list(id = "ropls_pls", package = "ropls", algorithm = "PLS",
         function_name = "ropls::opls(orthoI=0)", runner = function() runner_ropls(0L)),
    list(id = "ropls_opls", package = "ropls", algorithm = "OPLS",
         function_name = "ropls::opls(orthoI=1)", runner = function() runner_ropls(1L))
  ))
  if (identical(task_type, "classification")) {
    specs <- c(specs, list(
      list(id = "plsgenomics_pls_lda", package = "plsgenomics", algorithm = "PLS-LDA",
           function_name = "plsgenomics::pls.lda", runner = runner_plsgenomics_lda),
      list(id = "mixOmics_plsda", package = "mixOmics", algorithm = "PLS-DA",
           function_name = "mixOmics::plsda", runner = function() runner_mixomics_plsda(FALSE)),
      list(id = "mixOmics_splsda", package = "mixOmics", algorithm = "sPLS-DA",
           function_name = "mixOmics::splsda", runner = function() runner_mixomics_plsda(TRUE)),
      list(id = "spls_splsda", package = "spls", algorithm = "sPLS-DA",
           function_name = "spls::splsda", runner = function() runner_spls(TRUE))
    ))
  }
  specs
}

method_specs <- method_specs_all(task_type)
names(method_specs) <- vapply(method_specs, `[[`, character(1), "id")

function_available <- function(spec) {
  if (!quiet_require(spec$package)) return(FALSE)
  if (identical(spec$id, "mdatools_plsda_or_pls")) {
    ns <- asNamespace("mdatools")
    return(exists("plsda", envir = ns, inherits = FALSE) || exists("pls", envir = ns, inherits = FALSE))
  }
  parts <- strsplit(spec$function_name, "::", fixed = TRUE)[[1L]]
  if (length(parts) < 2L) return(TRUE)
  fun <- sub("^:+", "", sub("\\(.*$", "", parts[[2L]]))
  exists(fun, envir = asNamespace(spec$package), inherits = FALSE)
}

write_row <- function(row, path) {
  dir.create(dirname(normalizePath(path, mustWork = FALSE)), recursive = TRUE, showWarnings = FALSE)
  utils::write.csv(row, path, row.names = FALSE, quote = TRUE, na = "")
}

requested_estimator_from_spec <- function(spec) {
  id <- tolower(spec$id %||% "")
  if (grepl("plssvd", id, fixed = TRUE)) return("plssvd")
  if (grepl("kernelpls", id, fixed = TRUE)) return("kernelpls")
  if (grepl("opls", id, fixed = TRUE)) return("opls")
  if (grepl("simpls", id, fixed = TRUE)) return("simpls")
  as.character(spec$algorithm %||% spec$id)
}

classifier_from_spec <- function(spec) {
  id <- tolower(spec$id %||% "")
  if (grepl("_lda$", id)) return("lda")
  "argmax"
}

empty_row <- function(spec, status, msg = "") {
  data.frame(
    dataset = task$dataset,
    task_type = task_type,
    dataset_path = task$dataset_path,
    split_seed = split_seed,
    n_train = nrow(Xtrain),
    n_test = nrow(Xtest),
    p = ncol(Xtrain),
    n_response = ncol(Ytrain_dummy),
    input_precision = task$precision,
    execution_precision = if (identical(spec$package, "fastPLS")) task$precision else "float64",
    classifier = classifier_from_spec(spec),
    classifier_backend = if (identical(spec$package, "fastPLS")) NA_character_ else spec$package,
    classifier_numeric_path = if (identical(spec$package, "fastPLS")) NA_character_ else "float64",
    input_storage_mb = as.numeric(task$input_storage_mb),
    ncomp_requested = ncomp_requested,
    replicate = replicate_id,
    method_id = spec$id,
    package = spec$package,
    package_version = package_version_chr(spec$package),
    function_name = spec$function_name,
    algorithm = spec$algorithm,
    requested_estimator = requested_estimator_from_spec(spec),
    executed_estimator = requested_estimator_from_spec(spec),
    independent_implementation = TRUE,
    total_runtime_ms = NA_real_,
    metric_name = if (identical(task_type, "classification")) {
      "accuracy"
    } else if (ncol(Ytrain_dummy) == 1L) {
      "q2"
    } else {
      "rmsd"
    },
    metric_value = NA_real_,
    accuracy = NA_real_,
    balanced_accuracy = NA_real_,
    macro_f1 = NA_real_,
    rmse = NA_real_,
    q2 = NA_real_,
    mae = NA_real_,
    status = status,
    warning_message = "",
    error_message = msg,
    stringsAsFactors = FALSE
  )
}

measure_once <- function(fun) {
  gc(FALSE)
  event_file <- Sys.getenv("FASTPLS_MEASUREMENT_EVENTS", "")
  write_event <- function(event) {
    if (!nzchar(event_file)) return(invisible(NULL))
    row <- data.frame(
      timestamp = as.numeric(Sys.time()),
      replicate = replicate_id,
      event = event,
      rss_mib = current_process_rss_mb(),
      stringsAsFactors = FALSE
    )
    utils::write.table(
      row, event_file, sep = ",", row.names = FALSE,
      col.names = !file.exists(event_file), append = file.exists(event_file)
    )
    invisible(NULL)
  }
  warn <- character()
  err <- NULL
  value <- NULL
  write_event("fit_start")
  t0 <- proc.time()[3L]
  value <- tryCatch(
    withCallingHandlers(fun(), warning = function(w) {
      warn <<- c(warn, conditionMessage(w))
      invokeRestart("muffleWarning")
    }),
    error = function(e) {
      err <<- conditionMessage(e)
      NULL
    }
  )
  elapsed_ms <- as.numeric(proc.time()[3L] - t0) * 1000
  write_event("predict_end")
  list(value = value, elapsed_ms = elapsed_ms, error = err,
       warning = paste(unique(warn), collapse = " | "))
}

run_one <- function(method_id) {
  spec <- method_specs[[method_id]]
  if (is.null(spec)) {
    spec <- list(id = method_id, package = NA_character_, function_name = NA_character_, algorithm = NA_character_)
    return(empty_row(spec, "error", paste("Unknown method_id:", method_id)))
  }
  pkg_ok <- quiet_require(spec$package)
  fun_ok <- if (pkg_ok) function_available(spec) else FALSE
  if (!pkg_ok) return(empty_row(spec, "skipped_package_not_installed", sprintf("Package '%s' is not installed.", spec$package)))
  if (!fun_ok) return(empty_row(spec, "skipped_function_or_method_not_available", sprintf("Function/method '%s' is not available.", spec$function_name)))

  measured <- measure_once(spec$runner)
  row <- empty_row(spec, "ok")
  row$total_runtime_ms <- measured$elapsed_ms
  row$warning_message <- measured$warning
    if (!is.null(measured$error)) {
      row$status <- "error"
      row$error_message <- measured$error
      if (startsWith(measured$error, "package_limit:")) {
        row$status <- "package_limitation"
        row$error_message <- sub("^package_limit:[[:space:]]*", "", measured$error)
      }
      return(row)
    }
  pred <- tryCatch({
    if (!is.null(measured$value$pred)) measured$value$pred else spec$decoder(measured$value$fit)
  }, error = function(e) {
    row$status <<- "prediction_error"
    row$error_message <<- conditionMessage(e)
    NULL
  })
  if (identical(spec$package, "fastPLS") && !is.null(measured$value$fit)) {
    internal <- attr(measured$value$fit, "fastPLS_internal", exact = TRUE)
    row$execution_precision <- benchmark_execution_precision(measured$value$fit, row$execution_precision)
    row$classifier_backend <- benchmark_classifier_backend(measured$value$fit, row$classifier)
    row$classifier_numeric_path <- benchmark_classifier_numeric_path(
      measured$value$fit, row$classifier, row$execution_precision
    )
    row$executed_estimator <- benchmark_executed_method(
      measured$value$fit, row$requested_estimator
    )
    if (!identical(row$requested_estimator, row$executed_estimator)) {
      row$status <- "error_estimator_mismatch"
      row$error_message <- sprintf(
        "requested_estimator=%s; executed_estimator=%s; benchmark row rejected",
        row$requested_estimator,
        row$executed_estimator
      )
      pred <- NULL
    }
  }
  if (!is.null(pred)) {
    met <- metric_from_prediction(pred)
    row$metric_name <- met$metric_name
    row$metric_value <- met$metric_value
    row$accuracy <- met$accuracy
    row$balanced_accuracy <- met$balanced_accuracy %||% NA_real_
    row$macro_f1 <- met$macro_f1 %||% NA_real_
    row$rmse <- met$rmse
    row$q2 <- met$q2
    row$mae <- met$mae
  }
  row
}

pipeline2_method_family <- function(method_id, algorithm, function_name) {
  method_id <- tolower(method_id)
  algorithm <- tolower(algorithm)
  function_name <- tolower(function_name)
  if (grepl("plssvd", method_id, fixed = TRUE)) return("plssvd")
  if (grepl("kernelpls|kernel_pls|kernelpls", method_id) ||
      grepl("kernel", algorithm) || grepl("kernelpls", function_name)) return("kernelpls")
  if (grepl("opls", method_id, fixed = TRUE) ||
      grepl("\\bopls\\b", algorithm) || grepl("ropls::opls", function_name, fixed = TRUE)) return("opls")
  "simpls"
}

pipeline2_short_fastpls <- function(method_id) {
  x <- sub("^fastPLS_", "", method_id)
  x <- gsub("_cpu_", " CPU ", x, fixed = TRUE)
  x <- gsub("_cuda_", " CUDA ", x, fixed = TRUE)
  x <- gsub("_irlba", " IRLBA", x, fixed = TRUE)
  x <- gsub("_rsvd", " rSVD", x, fixed = TRUE)
  x <- gsub("_lda$", " LDA", x)
  x <- gsub("_", " ", x, fixed = TRUE)
  paste("fastPLS", x)
}

pipeline2_method_label <- function(d) {
  if (identical(d$package[[1]], "fastPLS")) return(pipeline2_short_fastpls(d$method_id[[1]]))
  fn <- d$function_name[[1]]
  alg <- d$algorithm[[1]]
  pkg <- d$package[[1]]
  if (is.na(fn) || !nzchar(fn)) fn <- d$method_id[[1]]
  if (is.na(alg) || !nzchar(alg)) {
    sprintf("%s: %s", pkg, fn)
  } else {
    sprintf("%s: %s (%s)", pkg, fn, alg)
  }
}

pipeline2_format_number <- function(x, digits = 4) {
  if (!is.finite(x) || is.na(x)) return("")
  formatC(x, digits = digits, format = "fg", flag = "#")
}

pipeline2_format_time <- function(ms) {
  if (!is.finite(ms) || is.na(ms)) return("")
  sec <- ms / 1000
  if (sec < 10) return(sprintf("%.3f s", sec))
  if (sec < 100) return(sprintf("%.2f s", sec))
  sprintf("%.1f s", sec)
}

pipeline2_format_error <- function(d) {
  status <- d$status[[1]]
  msg <- d$error_message[[1]]
  if (is.na(msg) || !nzchar(msg)) msg <- d$warning_message[[1]]
  if (is.na(msg) || !nzchar(msg)) msg <- status
  paste0(status, ": ", msg)
}

pipeline2_metric_cell <- function(d) {
  if (!identical(d$status[[1]], "ok")) return(pipeline2_format_error(d))
  metric <- d$metric_value[[1]]
  if (!is.finite(metric) || is.na(metric)) return("ok: metric unavailable")
  metric_name <- d$metric_name[[1]]
  if (identical(metric_name, "accuracy") || identical(metric_name, "q2")) {
    pipeline2_format_number(metric, 4)
  } else {
    pipeline2_format_number(metric, 6)
  }
}

pipeline2_time_cell <- function(d) {
  if (!identical(d$status[[1]], "ok")) {
    t <- pipeline2_format_time(d$total_runtime_ms[[1]])
    if (nzchar(t)) return(paste0(pipeline2_format_error(d), " (", t, ")"))
    return(pipeline2_format_error(d))
  }
  pipeline2_format_time(d$total_runtime_ms[[1]])
}

pipeline2_metric_label_for_dataset <- function(d) {
  ok_metric <- d$metric_name[d$status == "ok" & nzchar(d$metric_name)]
  if (length(ok_metric)) return(ok_metric[[1]])
  if (identical(d$task_type[[1]], "classification")) return("accuracy")
  "rmsd"
}

write_pipeline2_wide_tables <- function(raw, results_dir) {
  out_dir <- file.path(results_dir, "rearranged_tables")
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  dataset_order <- c(
    "metref", "ccle", "tcga_brca", "tcga_hnsc_methylation",
    "gtex_v8", "tcga_pan_cancer", "singlecell", "cifar100",
    "cbmc_citeseq", "prism", "nmr", "imagenet"
  )
  dataset_order <- c(intersect(dataset_order, unique(raw$dataset)), setdiff(unique(raw$dataset), dataset_order))
  raw$family <- mapply(
    pipeline2_method_family, raw$method_id, raw$algorithm, raw$function_name,
    USE.NAMES = FALSE
  )

  metric_map <- do.call(rbind, lapply(dataset_order, function(ds) {
    d <- raw[raw$dataset == ds, , drop = FALSE]
    data.frame(
      dataset = ds,
      task_type = d$task_type[[1]],
      displayed_metric = pipeline2_metric_label_for_dataset(d),
      n_train = d$n_train[[1]],
      n_test = d$n_test[[1]],
      p = d$p[[1]],
      n_response = d$n_response[[1]],
      ncomp_requested = d$ncomp_requested[[1]],
      stringsAsFactors = FALSE
    )
  }))
  utils::write.csv(metric_map, file.path(out_dir, "pipeline2_package_dataset_metric_map.csv"), row.names = FALSE, na = "")

  build_family_table <- function(family) {
    d <- raw[raw$family == family, , drop = FALSE]
    if (!nrow(d)) return(data.frame())
    rows <- list()
    idx <- 1L
    for (key in unique(d$method_id)) {
      dk <- d[d$method_id == key, , drop = FALSE]
      metric_row <- data.frame(
        function_package = pipeline2_method_label(dk),
        measure = "metric",
        stringsAsFactors = FALSE
      )
      time_row <- data.frame(
        function_package = pipeline2_method_label(dk),
        measure = "time",
        stringsAsFactors = FALSE
      )
      for (ds in dataset_order) {
        cell <- dk[dk$dataset == ds, , drop = FALSE]
        if (!nrow(cell)) {
          metric_row[[ds]] <- ""
          time_row[[ds]] <- ""
          next
        }
        cell <- cell[order(cell$replicate), , drop = FALSE][1L, , drop = FALSE]
        metric_row[[ds]] <- pipeline2_metric_cell(cell)
        time_row[[ds]] <- pipeline2_time_cell(cell)
      }
      rows[[idx]] <- metric_row
      rows[[idx + 1L]] <- time_row
      idx <- idx + 2L
    }
    out <- do.call(rbind, rows)
    row.names(out) <- NULL
    out
  }

  manifest <- data.frame()
  for (family in c("plssvd", "simpls", "opls", "kernelpls")) {
    tab <- build_family_table(family)
    csv <- file.path(out_dir, paste0("pipeline2_", family, "_package_wide_table.csv"))
    tsv <- file.path(out_dir, paste0("pipeline2_", family, "_package_wide_table.tsv"))
    utils::write.csv(tab, csv, row.names = FALSE, quote = TRUE, na = "")
    utils::write.table(tab, tsv, sep = "\t", row.names = FALSE, quote = FALSE, na = "")
    manifest <- rbind(manifest, data.frame(
      family = family,
      rows = nrow(tab),
      csv = csv,
      tsv = tsv,
      stringsAsFactors = FALSE
    ))
  }
  manifest_path <- file.path(out_dir, "pipeline2_package_wide_tables_manifest.csv")
  utils::write.csv(manifest, manifest_path, row.names = FALSE)
  message("Wrote pipeline 2 wide tables: ", out_dir)
}

summarize_results <- function(results_dir) {
  rows_dir <- file.path(results_dir, "run_rows")
  files <- list.files(rows_dir, pattern = "[.]csv$", full.names = TRUE)
  if (!length(files)) stop("No row CSV files found in ", rows_dir)
  raw <- do.call(rbind, lapply(files, utils::read.csv, check.names = FALSE))
  raw <- raw[order(raw$dataset, raw$method_id, raw$replicate), , drop = FALSE]
  raw_path <- file.path(results_dir, "pls_package_comparison_raw.csv")
  utils::write.csv(raw, raw_path, row.names = FALSE, quote = TRUE, na = "")

  # Keep completion status separate from performance medians so that a failed
  # implementation is never hidden merely because it has no successful rows.
  status_key <- interaction(raw$dataset, raw$method_id, drop = TRUE)
  status_summary <- do.call(rbind, lapply(split(raw, status_key), function(d) {
    status <- tolower(d$status)
    data.frame(
      dataset = d$dataset[1],
      task_type = d$task_type[1],
      method_id = d$method_id[1],
      package = d$package[1],
      algorithm = d$algorithm[1],
      ncomp_requested = d$ncomp_requested[1],
      input_precision = d$input_precision[1],
      execution_precision = d$execution_precision[1],
      requested_estimator = d$requested_estimator[1],
      executed_estimator = d$executed_estimator[1],
      reps_attempted = nrow(d),
      reps_ok = sum(status == "ok"),
      n_timeout = sum(grepl("timeout", status, fixed = TRUE)),
      n_error = sum(status %in% c("error", "killed", "oom")),
      n_skipped = sum(grepl("skip", status, fixed = TRUE)),
      stringsAsFactors = FALSE
    )
  }))
  status_path <- file.path(results_dir, "pls_package_comparison_status.csv")
  utils::write.csv(status_summary, status_path, row.names = FALSE, quote = TRUE, na = "")

  ok <- raw[raw$status == "ok", , drop = FALSE]
  iqr_or_na <- function(x) {
    x <- x[is.finite(x)]
    if (length(x) < 2L) NA_real_ else stats::IQR(x)
  }
  if (nrow(ok)) {
    split_key <- interaction(ok$dataset, ok$method_id, drop = TRUE)
    summary <- do.call(rbind, lapply(split(ok, split_key), function(d) {
      data.frame(
        dataset = d$dataset[1],
        task_type = d$task_type[1],
        method_id = d$method_id[1],
        package = d$package[1],
        algorithm = d$algorithm[1],
        ncomp_requested = d$ncomp_requested[1],
        input_precision = d$input_precision[1],
        execution_precision = d$execution_precision[1],
        classifier = d$classifier[1],
        classifier_backend = d$classifier_backend[1],
        classifier_numeric_path = d$classifier_numeric_path[1],
        requested_estimator = d$requested_estimator[1],
        executed_estimator = d$executed_estimator[1],
        reps_ok = nrow(d),
        median_time_ms = stats::median(d$total_runtime_ms, na.rm = TRUE),
        iqr_time_ms = iqr_or_na(d$total_runtime_ms),
        median_peak_host_rss_mb = if ("peak_host_rss_mb" %in% names(d)) {
          stats::median(d$peak_host_rss_mb, na.rm = TRUE)
        } else {
          NA_real_
        },
        iqr_peak_host_rss_mb = if ("peak_host_rss_mb" %in% names(d)) {
          iqr_or_na(d$peak_host_rss_mb)
        } else {
          NA_real_
        },
        median_metric = stats::median(d$metric_value, na.rm = TRUE),
        iqr_metric = iqr_or_na(d$metric_value),
        metric_name = d$metric_name[1],
        median_accuracy = stats::median(d$accuracy, na.rm = TRUE),
        median_balanced_accuracy = stats::median(d$balanced_accuracy, na.rm = TRUE),
        median_macro_f1 = stats::median(d$macro_f1, na.rm = TRUE),
        median_rmse = stats::median(d$rmse, na.rm = TRUE),
        median_q2 = stats::median(d$q2, na.rm = TRUE),
        stringsAsFactors = FALSE
      )
    }))
  } else {
    summary <- raw[0, , drop = FALSE]
  }
  summary_path <- file.path(results_dir, "pls_package_comparison_summary.csv")
  utils::write.csv(summary, summary_path, row.names = FALSE, quote = TRUE, na = "")
  write_pipeline2_wide_tables(raw, results_dir)

  if (requireNamespace("ggplot2", quietly = TRUE) && nrow(ok)) {
    plot_dir <- file.path(results_dir, "plots")
    dir.create(plot_dir, recursive = TRUE, showWarnings = FALSE)
    for (ds in unique(ok$dataset)) {
      d <- ok[ok$dataset == ds, , drop = FALSE]
      d$method_id <- stats::reorder(d$method_id, d$total_runtime_ms, FUN = stats::median)
      p1 <- ggplot2::ggplot(d, ggplot2::aes(x = method_id, y = total_runtime_ms, color = package)) +
        ggplot2::geom_point(size = 2.4, alpha = 0.85) +
        ggplot2::scale_y_log10() +
        ggplot2::coord_flip() +
        ggplot2::theme_bw(base_size = 13) +
        ggplot2::labs(title = paste0(ds, " package comparison: speed"),
                      x = NULL, y = "Total runtime (ms, log10)")
      p2 <- ggplot2::ggplot(d, ggplot2::aes(x = method_id, y = metric_value, color = package)) +
        ggplot2::geom_point(size = 2.4, alpha = 0.85) +
        ggplot2::coord_flip() +
        ggplot2::theme_bw(base_size = 13) +
        ggplot2::labs(title = paste0(ds, " package comparison: ", d$metric_name[1]),
                      x = NULL, y = d$metric_name[1])
      ggplot2::ggsave(file.path(plot_dir, paste0(ds, "_package_speed.png")), p1, width = 10, height = 7, dpi = 160)
      ggplot2::ggsave(file.path(plot_dir, paste0(ds, "_package_prediction.png")), p2, width = 10, height = 7, dpi = 160)
    }
    best_component_script <- file.path(repo_root, "benchmark", "plot_pipeline2_best_component_performance.R")
    if (file.exists(best_component_script)) {
      status <- system2(
        file.path(R.home("bin"), "Rscript"),
        c(best_component_script, raw_path, plot_dir)
      )
      if (!identical(status, 0L)) {
        warning("Best-component cross-dataset figure generation failed.", call. = FALSE)
      }
    }
  }
  message("Wrote: ", raw_path)
  message("Wrote: ", status_path)
  message("Wrote: ", summary_path)
}

if (identical(mode, "list_methods")) {
  cat(paste(vapply(method_specs, `[[`, character(1), "id"), collapse = "\n"))
  cat("\n")
} else if (identical(mode, "run_one")) {
  if (!nzchar(method_id)) stop("--method-id is required for --mode=run_one")
  row <- run_one(method_id)
  if (!nzchar(row_out)) row_out <- file.path(getwd(), paste0(dataset_id, "_", method_id, "_row.csv"))
  write_row(row, row_out)
  print(row[, c("dataset", "method_id", "package", "total_runtime_ms", "metric_name", "metric_value", "status", "error_message")])
} else if (identical(mode, "missing_row")) {
  spec <- method_specs[[method_id]] %||% list(id = method_id, package = NA_character_, function_name = NA_character_, algorithm = NA_character_)
  row <- empty_row(spec, status_override %||% "missing_row", message_override)
  if (!nzchar(row_out)) row_out <- file.path(getwd(), paste0(dataset_id, "_", method_id, "_missing.csv"))
  write_row(row, row_out)
} else if (identical(mode, "summarize")) {
  summarize_results(results_dir)
} else {
  stop("Unknown --mode: ", mode)
}
