#!/usr/bin/env Rscript

# Cross-platform public-API smoke test for every PLS family, classifier, and
# supported precision. Each configuration runs independently inside this
# process and records warnings or errors rather than stopping the full panel.

args <- commandArgs(trailingOnly = TRUE)
backend <- if (length(args)) args[[1L]] else "cpu"
output <- if (length(args) >= 2L) args[[2L]] else "backend_family_smoke.csv"
backend <- match.arg(backend, c("cpu", "cuda", "metal"))

benchmark_lib <- Sys.getenv("FASTPLS_BENCH_LIB", "")
if (nzchar(benchmark_lib)) {
  .libPaths(unique(c(benchmark_lib, .libPaths())))
}
suppressPackageStartupMessages(library(fastPLS))

if (backend == "cuda" && !isTRUE(has_cuda())) {
  stop("The selected fastPLS installation has no CUDA backend.", call. = FALSE)
}
if (backend == "metal" && !isTRUE(has_metal())) {
  stop("The selected fastPLS installation has no Metal backend.", call. = FALSE)
}

`%||%` <- function(left, right) {
  if (is.null(left) || !length(left)) right else left
}

set.seed(20260902)
n_train <- 120L
n_test <- 40L
p <- 24L
X <- matrix(rnorm((n_train + n_test) * p), n_train + n_test, p)
latent <- X[, 1:5, drop = FALSE]
Yreg <- cbind(
  0.8 * latent[, 1] - 0.3 * latent[, 3] + rnorm(nrow(X), sd = 0.08),
  -0.5 * latent[, 2] + 0.4 * latent[, 4] + rnorm(nrow(X), sd = 0.08),
  0.3 * latent[, 1] + 0.5 * latent[, 5] + rnorm(nrow(X), sd = 0.08)
)
class_score <- cbind(
  latent[, 1] - 0.3 * latent[, 2],
  latent[, 3] + 0.2 * latent[, 4],
  -latent[, 1] - latent[, 3] + 0.4 * latent[, 5]
)
Yclass <- factor(max.col(class_score), levels = 1:3,
                 labels = c("A", "B", "C"))
train <- seq_len(n_train)
test <- n_train + seq_len(n_test)

family_grid <- rbind(
  data.frame(method = c("plssvd", "simpls", "opls"), kernel = NA_character_),
  data.frame(method = "kernelpls", kernel = c("linear", "rbf", "poly"))
)
configurations <- do.call(rbind, lapply(c("float64", "float32"), function(precision) {
  do.call(rbind, lapply(c("regression", "classification"), function(task) {
    classifiers <- if (task == "classification") c("argmax", "lda") else "argmax"
    do.call(rbind, lapply(classifiers, function(classifier) {
      transform(family_grid, precision = precision, task = task,
                classifier = classifier)
    }))
  }))
}))
rownames(configurations) <- NULL

as_float <- function(value) {
  float::fl(as.matrix(value))
}

rows <- lapply(seq_len(nrow(configurations)), function(index) {
  config <- configurations[index, , drop = FALSE]
  warnings <- character()
  error_message <- ""
  model <- NULL
  elapsed <- tryCatch(
    withCallingHandlers(
      system.time({
        Xtrain <- X[train, , drop = FALSE]
        Xtest <- X[test, , drop = FALSE]
        response <- if (config$task == "classification") Yclass else Yreg
        Ytrain <- if (config$task == "classification") {
          response[train]
        } else {
          response[train, , drop = FALSE]
        }
        Ytest <- if (config$task == "classification") {
          response[test]
        } else {
          response[test, , drop = FALSE]
        }
        if (config$precision == "float32") {
          Xtrain <- as_float(Xtrain)
          Xtest <- as_float(Xtest)
          if (config$task == "regression") {
            Ytrain <- as_float(Ytrain)
            Ytest <- as_float(Ytest)
          }
        }
        fit_arguments <- list(
          Xtrain = Xtrain,
          Ytrain = Ytrain,
          Xtest = Xtest,
          Ytest = Ytest,
          ncomp = 1:4,
          method = config$method,
          backend = backend,
          svd.method = "rsvd",
          classifier = config$classifier,
          scaling = "centering",
          fit = TRUE,
          return_variance = FALSE,
          seed = 91L
        )
        if (config$method == "opls") fit_arguments$north <- 1L
        if (config$method == "kernelpls") {
          fit_arguments$kernel <- config$kernel
          fit_arguments$gamma <- if (config$kernel == "rbf") 1 / p else NULL
          fit_arguments$degree <- 2L
          fit_arguments$coef0 <- 1
        }
        model <- do.call(pls, fit_arguments)
      })[["elapsed"]],
      warning = function(condition) {
        warnings <<- c(warnings, conditionMessage(condition))
        invokeRestart("muffleWarning")
      }
    ),
    error = function(error) {
      error_message <<- conditionMessage(error)
      NA_real_
    }
  )

  latent_model <- if (!is.null(model)) model$inner_model %||% model else NULL
  diagnostics <- if (!is.null(model)) {
    model$diagnostics %||% latent_model$diagnostics %||% list()
  } else {
    list()
  }
  rsvd <- diagnostics$rsvd %||% list()
  direction <- diagnostics$simpls_direction %||% list()
  metric_table <- if (!is.null(model$metrics$test) &&
                      length(model$metrics$test)) {
    tail(model$metrics$test, 1L)[[1L]]$metrics
  } else {
    NULL
  }
  metric_name <- if (config$task == "classification") "accuracy" else "RMSD"
  metric <- if (!is.null(metric_table) && metric_name %in% names(metric_table)) {
    as.numeric(metric_table[[metric_name]][[1L]])
  } else {
    NA_real_
  }
  metric_is_finite <- function(value) {
    is.list(value) &&
      is.data.frame(value$metrics) &&
      metric_name %in% names(value$metrics) &&
      is.finite(value$metrics[[metric_name]][[1L]])
  }
  metric_count <- if (!is.null(model$R2Y)) length(model$R2Y) else 0L
  fitted_metrics_complete <- metric_count > 0L &&
    length(model$metrics$fitted) == metric_count &&
    all(vapply(model$metrics$fitted, metric_is_finite, logical(1L)))
  test_metrics_complete <- metric_count > 0L &&
    length(model$metrics$test) == metric_count &&
    all(vapply(model$metrics$test, metric_is_finite, logical(1L)))
  finite_model <- !is.null(latent_model) &&
    !is.null(latent_model$R) && !is.null(latent_model$Q) &&
    all(is.finite(as.matrix(latent_model$R))) &&
    all(is.finite(as.matrix(latent_model$Q)))
  effective_components <- if (!is.null(latent_model$R)) {
    ncol(as.matrix(latent_model$R))
  } else {
    NA_integer_
  }

  data.frame(
    package_version = as.character(packageVersion("fastPLS")),
    backend = backend,
    precision = config$precision,
    task = config$task,
    method = config$method,
    kernel = config$kernel,
    classifier = config$classifier,
    requested_components = 4L,
    effective_components = effective_components,
    elapsed_sec = as.numeric(elapsed),
    metric_name = metric_name,
    metric = metric,
    fitted_metrics_complete = fitted_metrics_complete,
    test_metrics_complete = test_metrics_complete,
    finite_model = finite_model,
    control_profile = rsvd$control_profile %||% NA_character_,
    oversample = rsvd$oversample %||% NA_integer_,
    power = rsvd$power %||% NA_integer_,
    direction_rule = direction$rule %||% NA_character_,
    directions_per_solve = direction$directions_per_solve %||% NA_integer_,
    refresh_width = direction$refresh_width %||% NA_integer_,
    refresh_iterations = direction$refresh_iterations %||% NA_integer_,
    fresh_start = direction$fresh_start %||% NA,
    status = if (is.null(model)) "failed" else "success",
    warnings = paste(unique(warnings), collapse = " | "),
    error = error_message,
    stringsAsFactors = FALSE
  )
})

result <- do.call(rbind, rows)
dir.create(dirname(output), recursive = TRUE, showWarnings = FALSE)
write.csv(result, output, row.names = FALSE, na = "")
print(result)

if (any(result$status != "success") ||
    any(!result$finite_model) ||
    any(!is.finite(result$metric)) ||
    any(!result$fitted_metrics_complete) ||
    any(!result$test_metrics_complete)) {
  quit(status = 1L)
}
