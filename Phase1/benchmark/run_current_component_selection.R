#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
benchmark_lib <- Sys.getenv("FASTPLS_BENCH_LIB", "")
if (nzchar(benchmark_lib)) {
  .libPaths(unique(c(benchmark_lib, .libPaths())))
}
suppressPackageStartupMessages(library(fastPLS))

`%||%` <- function(left, right) {
  if (is.null(left) || !length(left)) right else left
}

script_arg <- commandArgs()[grep("^--file=", commandArgs())]
script_path <- normalizePath(sub("^--file=", "", script_arg[[1L]]))
repo_dir <- normalizePath(file.path(dirname(script_path), ".."))
source(file.path(repo_dir, "benchmark", "helpers_dataset_memory_compare.R"))
worker <- file.path(repo_dir, "benchmark", "component_selection_worker.R")
task_root <- normalizePath(
  Sys.getenv("FASTPLS_COMPONENT_TASK_ROOT", Sys.getenv("FASTPLS_DATA_ROOT")),
  mustWork = TRUE
)
results_root <- Sys.getenv("FASTPLS_RESULTS_ROOT")
out_dir <- if (length(args)) args[[1L]] else {
  if (!nzchar(results_root)) {
    stop("Supply an output directory or set FASTPLS_RESULTS_ROOT.", call. = FALSE)
  }
  file.path(results_root, "component_selection")
}
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

ordinary_datasets <- c(
  "cbmc_citeseq", "ccle", "cifar100", "gtex_v8", "metref", "prism",
  "retina", "tabula", "tcga_brca", "tcga_hnsc_methylation",
  "tcga_pan_cancer"
)
grid_contract_path <- normalizePath(
  Sys.getenv(
    "FASTPLS_COMPONENT_GRID_CONTRACT",
    file.path(repo_dir, "config", "cmpb_selection_grids.csv")
  ),
  mustWork = TRUE
)
grid_contract <- read.csv(
  grid_contract_path, stringsAsFactors = FALSE, check.names = FALSE
)
if (!all(c("dataset", "components") %in% names(grid_contract))) {
  stop("The component-grid contract must contain dataset and components.")
}
parse_grid <- function(value) {
  grid <- sort(unique(as.integer(strsplit(value, ",", fixed = TRUE)[[1L]])))
  if (!length(grid) || anyNA(grid) || any(grid < 1L)) {
    stop("Every candidate grid must contain positive integer components.")
  }
  grid
}
grid_by_dataset <- setNames(
  lapply(grid_contract$components, parse_grid), grid_contract$dataset
)
missing_grids <- setdiff(ordinary_datasets, names(grid_by_dataset))
if (length(missing_grids)) {
  stop("Missing component grids for: ", paste(missing_grids, collapse = ", "))
}
dataset_caps <- vapply(
  grid_by_dataset[ordinary_datasets], max, integer(1L)
)
families <- c("plssvd", "simpls", "opls", "kernelpls")
classification_heads <- c("argmax", "lda")
kfold <- as.integer(Sys.getenv("FASTPLS_COMPONENT_KFOLD", "10"))
seed <- as.integer(Sys.getenv("FASTPLS_COMPONENT_SEED", "123"))
n.cores <- as.integer(Sys.getenv("FASTPLS_COMPONENT_NCORES", "1"))
if (!is.finite(n.cores) || n.cores < 1L) {
  stop("FASTPLS_COMPONENT_NCORES must be positive.", call. = FALSE)
}
component_precision <- tolower(Sys.getenv(
  "FASTPLS_COMPONENT_PRECISION", "native"
))
timeout_seconds <- as.integer(Sys.getenv("FASTPLS_BENCHMARK_TIMEOUT", "1800"))
if (!is.finite(timeout_seconds) || timeout_seconds < 1L) {
  stop("FASTPLS_BENCHMARK_TIMEOUT must be positive.", call. = FALSE)
}
timeout_command <- Sys.which("timeout")
if (!nzchar(timeout_command)) {
  stop("The component-selection runner requires coreutils timeout.")
}
if (!component_precision %in% c("native", "float32", "float64")) {
  stop(
    "FASTPLS_COMPONENT_PRECISION must be native, float32, or float64.",
    call. = FALSE
  )
}
dataset_filter <- Sys.getenv("FASTPLS_COMPONENT_DATASETS", "")
if (nzchar(dataset_filter)) {
  requested <- trimws(strsplit(dataset_filter, ",", fixed = TRUE)[[1L]])
  dataset_caps <- dataset_caps[names(dataset_caps) %in% requested]
}
family_filter <- Sys.getenv("FASTPLS_COMPONENT_FAMILIES", "")
if (nzchar(family_filter)) {
  requested <- trimws(strsplit(family_filter, ",", fixed = TRUE)[[1L]])
  families <- families[families %in% requested]
}
if (!length(dataset_caps) || !length(families)) {
  stop("The dataset or family filter selected no configurations.", call. = FALSE)
}

task_path <- function(dataset) {
  path <- file.path(task_root, paste0(dataset, "_task.rds"))
  normalizePath(path, mustWork = TRUE)
}

task_dimensions <- function(task) {
  classification <- is.factor(task$Ytrain) || is.character(task$Ytrain)
  n <- task$n_train %||% dim(task$Xtrain)[[1L]]
  p <- task$p %||% dim(task$Xtrain)[[2L]]
  q <- if (classification) {
    nlevels(factor(task$Ytrain))
  } else if (!is.null(dim(task$Ytrain))) {
    dim(task$Ytrain)[[2L]]
  } else {
    1L
  }
  list(n = as.integer(n), p = as.integer(p), q = as.integer(q),
       classification = classification)
}

make_config <- function(dataset, family, classifier) {
  task <- readRDS(task_path(dataset))
  task <- validate_publication_task(task, dataset)
  dimensions <- task_dimensions(task)
  fold_train_limit <- floor(dimensions$n * (kfold - 1L) / kfold) - 1L
  family_limit <- min(dimensions$p, fold_train_limit)
  if (identical(family, "opls")) {
    # The default OPLS model removes one orthogonal direction before fitting
    # its predictive SIMPLS path.
    family_limit <- family_limit - 1L
  }
  if (identical(family, "plssvd")) {
    response_limit <- if (dimensions$classification) {
      dimensions$q - 1L
    } else {
      dimensions$q
    }
    family_limit <- min(family_limit, response_limit)
  }
  grid <- grid_by_dataset[[dataset]]
  grid <- grid[grid <= family_limit]
  if (!length(grid)) {
    stop("No valid component count for ", dataset, "/", family, call. = FALSE)
  }
  list(
    run_id = paste(dataset, family, classifier, sep = "__"),
    dataset = dataset,
    family = family,
    classifier = classifier,
    task_path = task_path(dataset),
    grid = grid,
    intrinsic_limit = as.integer(family_limit),
    kfold = kfold,
    seed = seed,
    n.cores = n.cores,
    selection_metric = if (dimensions$classification) "accuracy" else "rmsd",
    precision = component_precision
  )
}

configs <- unlist(lapply(names(dataset_caps), function(dataset) {
  task <- validate_publication_task(readRDS(task_path(dataset)), dataset)
  dimensions <- task_dimensions(task)
  heads <- if (dimensions$classification) classification_heads else "argmax"
  unlist(lapply(families, function(family) {
    lapply(heads, function(classifier) {
      make_config(dataset, family, classifier)
    })
  }), recursive = FALSE)
}), recursive = FALSE)
saveRDS(configs, file.path(out_dir, "configurations.rds"))

time_flag <- if (identical(Sys.info()[["sysname"]], "Darwin")) "-l" else "-v"
rows <- list()
paths <- list()
for (index in seq_along(configs)) {
  config <- configs[[index]]
  config_path <- file.path(out_dir, paste0(config$run_id, "_config.rds"))
  result_path <- file.path(out_dir, paste0(config$run_id, "_result.rds"))
  time_path <- file.path(out_dir, paste0(config$run_id, ".time"))
  stdout_path <- file.path(out_dir, paste0(config$run_id, ".out"))
  if (!file.exists(result_path)) {
    saveRDS(config, config_path)
    cat(sprintf("[%d/%d] %s\n", index, length(configs), config$run_id))
    status <- system2(
      timeout_command,
      c(
        "--signal=TERM",
        paste0(timeout_seconds, "s"),
        "/usr/bin/time",
        time_flag,
        file.path(R.home("bin"), "Rscript"),
        worker,
        config_path,
        result_path
      ),
      stdout = stdout_path,
      stderr = time_path
    )
    if (!identical(status, 0L) && !file.exists(result_path)) {
      stop(
        "Component-selection worker failed for ", config$run_id,
        " with exit status ", status, call. = FALSE
      )
    }
    unlink(config_path)
  } else {
    cat(sprintf("[%d/%d] %s [reused]\n", index, length(configs), config$run_id))
  }
  if (!file.exists(result_path)) {
    stop("Worker did not produce a result for ", config$run_id, call. = FALSE)
  }
  rows[[length(rows) + 1L]] <- readRDS(result_path)
  path_file <- sub("[.]rds$", "_path.rds", result_path)
  if (file.exists(path_file)) {
    paths[[length(paths) + 1L]] <- readRDS(path_file)
  }
  write.csv(
    do.call(rbind, rows),
    file.path(out_dir, "component_selection_progress.csv"),
    row.names = FALSE
  )
}

summary <- do.call(rbind, rows)
metric_paths <- do.call(rbind, paths)
write.csv(summary, file.path(out_dir, "component_selection_summary.csv"),
          row.names = FALSE)
write.csv(metric_paths, file.path(out_dir, "component_selection_paths.csv"),
          row.names = FALSE)
successful <- summary[summary$status == "success", , drop = FALSE]
selection_keys <- unique(successful[c("dataset", "family")])
selected_rows <- lapply(seq_len(nrow(selection_keys)), function(index) {
  key <- selection_keys[index, , drop = FALSE]
  candidates <- successful[
    successful$dataset == key$dataset & successful$family == key$family,
    ,
    drop = FALSE
  ]
  chosen <- if (identical(candidates$selection_metric[[1L]], "rmsd")) {
    which.min(candidates$selected_metric)
  } else {
    which.max(candidates$selected_metric)
  }
  candidates[chosen, , drop = FALSE]
})
selected <- do.call(rbind, selected_rows)[c(
  "dataset", "family", "classifier", "selected_ncomp", "selection_status",
  "grid_min", "grid_max", "intrinsic_limit", "selection_metric",
  "selected_metric", "kfold", "seed", "precision", "control_profile",
  "oversample", "power", "package_version"
)]
names(selected)[names(selected) == "classifier"] <- "selected_classifier"
write.csv(selected, file.path(out_dir, "selected_components.csv"),
          row.names = FALSE)
writeLines(
  c(
    paste("created:", format(Sys.time(), tz = "UTC", usetz = TRUE)),
    paste("fastPLS:", as.character(packageVersion("fastPLS"))),
    paste("task_root:", task_root),
    paste("component_grid_contract:", grid_contract_path),
    paste("kfold:", kfold),
    paste("seed:", seed),
    paste("n.cores:", n.cores),
    paste("precision:", component_precision),
    "selection_data: training data only",
    "classification_metric: accuracy",
    "classification_heads: argmax and lda",
    "classification_selection: maximum training-only CV accuracy across component count and classifier",
    "regression_metric: RMSD",
    "tie_rule: the lowest component count, and then the first classifier in the declared order, is retained",
    capture.output(sessionInfo())
  ),
  file.path(out_dir, "session_info.txt")
)

cat("Results:", normalizePath(out_dir), "\n")
