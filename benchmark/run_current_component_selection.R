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

dataset_caps <- c(
  cbmc_citeseq = 100L,
  ccle = 100L,
  cifar100 = 300L,
  gtex_v8 = 200L,
  metref = 200L,
  prism = 100L,
  retina = 50L,
  tabula = 50L,
  tcga_brca = 100L,
  tcga_hnsc_methylation = 100L,
  tcga_pan_cancer = 200L
)
families <- c("plssvd", "simpls", "opls", "kernelpls")
kfold <- as.integer(Sys.getenv("FASTPLS_COMPONENT_KFOLD", "10"))
seed <- as.integer(Sys.getenv("FASTPLS_COMPONENT_SEED", "123"))
component_precision <- tolower(Sys.getenv(
  "FASTPLS_COMPONENT_PRECISION", "native"
))
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

make_config <- function(dataset, family) {
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
  grid_max <- min(unname(dataset_caps[[dataset]]), family_limit)
  if (grid_max < 1L) {
    stop("No valid component count for ", dataset, "/", family, call. = FALSE)
  }
  list(
    run_id = paste(dataset, family, sep = "__"),
    dataset = dataset,
    family = family,
    task_path = task_path(dataset),
    grid = seq_len(grid_max),
    intrinsic_limit = as.integer(family_limit),
    kfold = kfold,
    seed = seed,
    selection_metric = if (dimensions$classification) "accuracy" else "rmsd",
    precision = component_precision
  )
}

configs <- unlist(lapply(names(dataset_caps), function(dataset) {
  lapply(families, function(family) make_config(dataset, family))
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
    system2(
      "/usr/bin/time",
      c(
        time_flag,
        file.path(R.home("bin"), "Rscript"),
        worker,
        config_path,
        result_path
      ),
      stdout = stdout_path,
      stderr = time_path
    )
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
selected <- summary[summary$status == "success", c(
  "dataset", "family", "selected_ncomp", "selection_status", "grid_min",
  "grid_max", "intrinsic_limit", "selection_metric", "selected_metric"
)]
write.csv(selected, file.path(out_dir, "selected_components.csv"),
          row.names = FALSE)
writeLines(
  c(
    paste("created:", format(Sys.time(), tz = "UTC", usetz = TRUE)),
    paste("fastPLS:", as.character(packageVersion("fastPLS"))),
    paste("task_root:", task_root),
    paste("kfold:", kfold),
    paste("seed:", seed),
    paste("precision:", component_precision),
    "selection_data: training data only",
    "classification_metric: accuracy",
    "regression_metric: RMSD",
    capture.output(sessionInfo())
  ),
  file.path(out_dir, "session_info.txt")
)

cat("Results:", normalizePath(out_dir), "\n")
