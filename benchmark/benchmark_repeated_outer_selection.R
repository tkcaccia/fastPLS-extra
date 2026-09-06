#!/usr/bin/env Rscript

# Repeated outer-partition assessment with training-only component selection.
# The workflow quantifies both selected-component stability and predictive
# dispersion; timing repetitions are deliberately not treated as uncertainty.

args <- commandArgs(trailingOnly = TRUE)
get_arg <- function(name, default = NULL) {
  key <- paste0("--", name, "=")
  hit <- args[startsWith(args, key)]
  if (!length(hit)) return(default)
  sub(key, "", hit[[1L]], fixed = TRUE)
}
split_csv <- function(x) {
  trimws(strsplit(x, ",", fixed = TRUE)[[1L]])
}
bind_rows_fill <- function(...) {
  frames <- Filter(function(x) is.data.frame(x) && nrow(x), list(...))
  if (!length(frames)) return(data.frame())
  fields <- unique(unlist(lapply(frames, names), use.names = FALSE))
  frames <- lapply(frames, function(x) {
    missing <- setdiff(fields, names(x))
    for (field in missing) x[[field]] <- NA
    x[fields]
  })
  do.call(rbind, frames)
}

dataset <- tolower(get_arg("dataset", "metref"))
data_path <- path.expand(get_arg("data", ""))
out_dir <- get_arg("out", "")
if (!nzchar(out_dir)) {
  results_root <- Sys.getenv("FASTPLS_RESULTS_ROOT")
  if (!nzchar(results_root)) stop("Set --out or FASTPLS_RESULTS_ROOT.")
  out_dir <- file.path(results_root, "repeated_outer_selection", dataset)
}
out_dir <- path.expand(out_dir)
methods <- split_csv(get_arg(
  "methods",
  if (identical(dataset, "nmr")) "plssvd,simpls" else "plssvd,simpls,opls,kernelpls"
))
classifiers <- split_csv(get_arg(
  "classifiers",
  if (identical(dataset, "nmr")) "regression" else "argmax,lda"
))
backend <- tolower(get_arg("backend", if (identical(dataset, "nmr")) "cuda" else "cpu"))
svd_method <- tolower(get_arg("svd_method", if (identical(dataset, "nmr")) "rsvd" else "irlba"))
outer_seeds <- as.integer(split_csv(get_arg(
  "outer_seeds",
  if (identical(dataset, "nmr")) "1201,2203,3209,4211,5231" else
    "101,211,307,401,503,601,701,809,907,1009"
)))
outer_train_fraction <- as.numeric(get_arg("outer_train_fraction", "0.8"))
inner_kfold <- as.integer(get_arg("inner_kfold", if (identical(dataset, "nmr")) "3" else "5"))
inner_seed <- as.integer(get_arg("inner_seed", "9101"))
fit_seed <- as.integer(get_arg("fit_seed", "123"))
resume <- tolower(get_arg("resume", "true")) %in% c("true", "1", "yes")

if (!nzchar(data_path) || !file.exists(data_path)) {
  stop("Provide an existing --data=DATASET.RData file.", call. = FALSE)
}
if (!outer_train_fraction > 0.5 || !outer_train_fraction < 1) {
  stop("outer_train_fraction must be between 0.5 and 1.", call. = FALSE)
}
if (anyNA(outer_seeds) || !length(outer_seeds)) {
  stop("outer_seeds must contain valid integers.", call. = FALSE)
}

script_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
script_path <- if (length(script_arg)) {
  normalizePath(sub("^--file=", "", script_arg[[1L]]), mustWork = TRUE)
} else {
  normalizePath("benchmark/benchmark_repeated_outer_selection.R", mustWork = TRUE)
}
source(file.path(dirname(script_path), "helpers_dataset_memory_compare.R"))

lib_loc <- Sys.getenv("FASTPLS_LIB", unset = "")
if (nzchar(lib_loc)) .libPaths(c(lib_loc, .libPaths()))
suppressPackageStartupMessages(library(fastPLS))
if (identical(backend, "cuda") && !isTRUE(has_cuda())) {
  stop("The selected fastPLS installation has no CUDA backend.", call. = FALSE)
}
if (identical(backend, "metal") && !isTRUE(has_metal())) {
  stop("The selected fastPLS installation has no Metal backend.", call. = FALSE)
}

as_double <- function(x) {
  if (inherits(x, "float32")) float::dbl(x) else as.matrix(x)
}

task <- as_task(data_path, dataset_id = dataset, split_seed = 123L)
X <- rbind(as_double(task$Xtrain), as_double(task$Xtest))
classification <- identical(task$task_type, "classification")
if (classification) {
  levels_all <- union(levels(factor(task$Ytrain)), levels(factor(task$Ytest)))
  Y <- factor(
    c(as.character(task$Ytrain), as.character(task$Ytest)),
    levels = levels_all
  )
} else {
  Y <- rbind(as_double(task$Ytrain), as_double(task$Ytest))
}
rm(task)
gc(full = TRUE)

component_grid <- function(dataset, method, n, p, q, classification) {
  grid <- switch(
    dataset,
    metref = c(2L, 5L, 10L, 15L, 20L, 22L),
    gtex_v8 = c(2L, 5L, 10L, 20L, 32L, 50L, 75L, 100L),
    retina = c(2L, 5L, 10L, 20L, 30L, 40L, 50L),
    nmr = if (identical(method, "plssvd")) {
      c(2L, 5L, 10L, 20L, 50L, 75L, 100L)
    } else {
      c(10L, 25L, 50L, 75L, 100L, 125L, 150L, 165L, 200L)
    },
    stop("No component grid configured for dataset ", dataset)
  )
  max_allowed <- min(n - 2L, p)
  if (identical(method, "plssvd")) {
    response_rank <- if (classification) max(1L, q - 1L) else q
    max_allowed <- min(max_allowed, response_rank)
  }
  grid <- sort(unique(grid[grid <= max_allowed]))
  if (classification && identical(method, "plssvd") &&
      length(grid) && max(grid) < max_allowed) {
    grid <- sort(unique(c(grid, max_allowed)))
  }
  if (!length(grid)) stop("No feasible components remain for ", dataset, "/", method)
  list(
    values = grid,
    maximum_allowed = max_allowed,
    upper_rank_constrained = identical(method, "plssvd") && max(grid) == max_allowed
  )
}

outer_partition <- function(seed) {
  set.seed(seed)
  if (!classification) {
    train <- sort(sample.int(nrow(X), floor(outer_train_fraction * nrow(X))))
    return(list(train = train, test = setdiff(seq_len(nrow(X)), train)))
  }
  by_class <- split(seq_along(Y), Y)
  train <- unlist(lapply(by_class, function(index) {
    n_train <- floor(length(index) * outer_train_fraction)
    n_train <- min(max(1L, n_train), max(1L, length(index) - 1L))
    sample(index, n_train)
  }), use.names = FALSE)
  train <- sort(train)
  list(train = train, test = setdiff(seq_along(Y), train))
}

metric_from_fit <- function(fit, truth) {
  if (classification) {
    predicted <- fit$Ypred
    if (is.list(predicted)) predicted <- predicted[[length(predicted)]]
    predicted <- factor(predicted, levels = levels(Y))
    accuracy <- mean(predicted == factor(truth, levels = levels(Y)), na.rm = TRUE)
    return(list(
      metric_name = "accuracy",
      metric_value = accuracy,
      accuracy = accuracy,
      RMSD = NA_real_,
      Q2 = if (length(fit$Q2Y)) as.numeric(tail(fit$Q2Y, 1L)) else NA_real_
    ))
  }
  predicted <- fit$Ypred
  if (is.list(predicted) && !is.data.frame(predicted)) {
    predicted <- predicted[[length(predicted)]]
  }
  truth <- as.matrix(truth)
  # A single requested component can retain a trailing singleton array
  # dimension. Collapse it without changing the sample-response ordering.
  if (length(predicted) == length(truth)) {
    predicted <- array(as.numeric(predicted), dim = dim(truth))
  } else {
    predicted <- as.matrix(predicted)
  }
  rmsd <- if (identical(dim(predicted), dim(truth))) {
    sqrt(mean((truth - predicted)^2))
  } else {
    NA_real_
  }
  list(
    metric_name = "RMSD",
    metric_value = rmsd,
    accuracy = NA_real_,
    RMSD = rmsd,
    Q2 = if (length(fit$Q2Y)) as.numeric(tail(fit$Q2Y, 1L)) else NA_real_
  )
}

dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
raw_path <- file.path(out_dir, "repeated_outer_raw.csv")
existing <- if (resume && file.exists(raw_path)) {
  read.csv(raw_path, stringsAsFactors = FALSE)
} else {
  data.frame()
}

rows <- list()
for (method in methods) {
  if (!method %in% c("plssvd", "simpls", "opls", "kernelpls")) {
    warning("Skipping unsupported method: ", method)
    next
  }
  endpoints <- if (classification) classifiers else "regression"
  for (classifier in endpoints) {
    for (outer_index in seq_along(outer_seeds)) {
      outer_seed <- outer_seeds[[outer_index]]
      already_done <- nrow(existing) > 0L && any(
        existing$method == method &
          existing$classifier == classifier &
          existing$outer_seed == outer_seed &
          existing$status == "ok"
      )
      if (isTRUE(already_done)) next

      split <- outer_partition(outer_seed)
      train <- split$train
      test <- split$test
      q <- if (classification) nlevels(droplevels(Y[train])) else ncol(Y)
      grid_info <- component_grid(
        dataset, method, length(train), ncol(X), q, classification
      )
      grid <- grid_info$values
      message(sprintf(
        "[%s] dataset=%s method=%s classifier=%s outer=%d/%d seed=%d grid=%s",
        format(Sys.time(), "%Y-%m-%d %H:%M:%S"), dataset, method, classifier,
        outer_index, length(outer_seeds), outer_seed, paste(grid, collapse = ",")
      ))

      Ytrain <- if (classification) droplevels(Y[train]) else Y[train, , drop = FALSE]
      Ytest <- if (classification) {
        factor(Y[test], levels = levels(Ytrain))
      } else {
        Y[test, , drop = FALSE]
      }
      selection_error <- ""
      fit_error <- ""
      selected_ncomp <- NA_integer_
      effective_grid <- grid
      selection_time <- NA_real_
      final_time <- NA_real_
      metrics <- list(
        metric_name = if (classification) "accuracy" else "RMSD",
        metric_value = NA_real_, accuracy = NA_real_, RMSD = NA_real_, Q2 = NA_real_
      )

      gc(full = TRUE)
      selection_time <- system.time({
        selected <- tryCatch(
          pls.single.cv(
            Xdata = X[train, , drop = FALSE],
            Ydata = Ytrain,
            ncomp = grid,
            scaling = "centering",
            method = method,
            backend = backend,
            svd.method = svd_method,
            seed = inner_seed,
            kfold = inner_kfold,
            north = 1L,
            kernel = "linear",
            classifier = if (classification) classifier else "argmax",
            fit = FALSE,
            selection_metric = if (classification) "accuracy" else "rmsd"
          ),
          error = function(e) {
            selection_error <<- conditionMessage(e)
            NULL
          }
        )
      })[["elapsed"]]

      if (!is.null(selected)) {
        effective_grid <- as.integer(selected$ncomp)
        selected_ncomp <- as.integer(selected$best_ncomp[[1L]])
        final_time <- system.time({
          final_fit <- tryCatch(
            pls(
              Xtrain = X[train, , drop = FALSE],
              Ytrain = Ytrain,
              Xtest = X[test, , drop = FALSE],
              Ytest = Ytest,
              ncomp = selected_ncomp,
              scaling = "centering",
              method = method,
              backend = backend,
              svd.method = svd_method,
              classifier = if (classification) classifier else "argmax",
              north = 1L,
              kernel = "linear",
              fit = FALSE,
              return_variance = FALSE,
              seed = fit_seed
            ),
            error = function(e) {
              fit_error <<- conditionMessage(e)
              NULL
            }
          )
        })[["elapsed"]]
        if (!is.null(final_fit)) {
          metrics <- metric_from_fit(final_fit, Ytest)
          rm(final_fit)
        }
        rm(selected)
      }

      status <- if (
        !isTRUE(nzchar(selection_error)) &&
        !isTRUE(nzchar(fit_error)) &&
        length(metrics$metric_value) == 1L &&
        isTRUE(is.finite(metrics$metric_value))
      ) "ok" else "failed"
      row <- data.frame(
        dataset = dataset,
        method = method,
        classifier = classifier,
        backend = backend,
        svd_method = svd_method,
        outer_index = outer_index,
        outer_seed = outer_seed,
        n_total = nrow(X),
        n_outer_train = length(train),
        n_outer_test = length(test),
        p = ncol(X),
        q = q,
        inner_kfold = inner_kfold,
        component_grid = paste(grid, collapse = ";"),
        effective_component_grid = paste(effective_grid, collapse = ";"),
        grid_min = min(grid),
        grid_max = max(grid),
        effective_grid_min = min(effective_grid),
        effective_grid_max = max(effective_grid),
        selected_ncomp = selected_ncomp,
        selected_lower_boundary = is.finite(selected_ncomp) &&
          selected_ncomp == min(effective_grid),
        selected_upper_boundary = is.finite(selected_ncomp) &&
          selected_ncomp == max(effective_grid),
        upper_grid_rank_constrained = grid_info$upper_rank_constrained,
        metric_name = metrics$metric_name,
        metric_value = metrics$metric_value,
        accuracy = metrics$accuracy,
        RMSD = metrics$RMSD,
        Q2 = metrics$Q2,
        selection_time_sec = selection_time,
        final_fit_prediction_time_sec = final_time,
        total_time_sec = selection_time + final_time,
        status = status,
        error = trimws(paste(selection_error, fit_error)),
        stringsAsFactors = FALSE
      )
      rows[[length(rows) + 1L]] <- row
      current <- bind_rows_fill(
        existing,
        if (length(rows)) do.call(rbind, rows) else data.frame()
      )
      write.csv(current, raw_path, row.names = FALSE)
      gc(full = TRUE)
    }
  }
}

raw <- bind_rows_fill(
  existing,
  if (length(rows)) do.call(rbind, rows) else data.frame()
)
raw <- raw[!duplicated(raw[c("method", "classifier", "outer_seed")], fromLast = TRUE), ]
raw <- raw[order(raw$method, raw$classifier, raw$outer_index), ]
write.csv(raw, raw_path, row.names = FALSE)

ok <- raw[raw$status == "ok", , drop = FALSE]
if (!nrow(ok)) stop("No repeated outer-partition run completed.", call. = FALSE)

group_key <- interaction(ok$method, ok$classifier, drop = TRUE)
dispersion <- do.call(rbind, lapply(split(ok, group_key), function(x) {
  values <- x$metric_value
  selected <- x$selected_ncomp
  data.frame(
    dataset = x$dataset[[1L]],
    method = x$method[[1L]],
    classifier = x$classifier[[1L]],
    backend = x$backend[[1L]],
    svd_method = x$svd_method[[1L]],
    n_outer_success = nrow(x),
    metric_name = x$metric_name[[1L]],
    metric_mean = mean(values),
    metric_sd = stats::sd(values),
    metric_median = stats::median(values),
    metric_q025 = unname(stats::quantile(values, 0.025)),
    metric_q975 = unname(stats::quantile(values, 0.975)),
    selected_ncomp_median = stats::median(selected),
    selected_ncomp_min = min(selected),
    selected_ncomp_max = max(selected),
    lower_boundary_frequency = mean(x$selected_lower_boundary),
    upper_boundary_frequency = mean(x$selected_upper_boundary),
    rank_constrained_grid = any(x$upper_grid_rank_constrained),
    stringsAsFactors = FALSE
  )
}))
row.names(dispersion) <- NULL
write.csv(
  dispersion,
  file.path(out_dir, "repeated_outer_predictive_dispersion.csv"),
  row.names = FALSE
)

selection_frequency <- do.call(rbind, lapply(split(ok, group_key), function(x) {
  frequency <- as.data.frame(table(x$selected_ncomp), stringsAsFactors = FALSE)
  names(frequency) <- c("selected_ncomp", "count")
  frequency$selected_ncomp <- as.integer(as.character(frequency$selected_ncomp))
  frequency$frequency <- frequency$count / sum(frequency$count)
  frequency$dataset <- x$dataset[[1L]]
  frequency$method <- x$method[[1L]]
  frequency$classifier <- x$classifier[[1L]]
  frequency[c("dataset", "method", "classifier", "selected_ncomp", "count", "frequency")]
}))
row.names(selection_frequency) <- NULL
write.csv(
  selection_frequency,
  file.path(out_dir, "repeated_outer_selection_frequency.csv"),
  row.names = FALSE
)

writeLines(
  c(
    sprintf("dataset: %s", dataset),
    sprintf("fastPLS_version: %s", as.character(packageVersion("fastPLS"))),
    sprintf("source: %s", normalizePath(data_path, winslash = "/", mustWork = TRUE)),
    sprintf("n_total: %d", nrow(X)),
    sprintf("p: %d", ncol(X)),
    sprintf("outer_train_fraction: %.3f", outer_train_fraction),
    sprintf("outer_seeds: %s", paste(outer_seeds, collapse = ",")),
    sprintf("inner_kfold: %d", inner_kfold),
    sprintf("methods: %s", paste(methods, collapse = ",")),
    sprintf("classifiers: %s", paste(classifiers, collapse = ",")),
    sprintf("backend: %s", backend),
    sprintf("svd_method: %s", svd_method),
    "rsvd_controls: automatic public defaults selected from each training-fold shape",
    sprintf("inner_seed: %d", inner_seed),
    sprintf("fit_seed: %d", fit_seed),
    "selection wording: best within the evaluated grid; boundary selections are not called optimal"
  ),
  file.path(out_dir, "repeated_outer_manifest.txt")
)
capture.output(sessionInfo(), file = file.path(out_dir, "session_info.txt"))
message("Wrote repeated outer-partition results to ", normalizePath(out_dir))
