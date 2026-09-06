#!/usr/bin/env Rscript

# Run the current-release SIMPLS ablation in isolated R processes. Each
# configuration is repeated independently so package loading is excluded from
# the reported fit-plus-prediction time.

args <- commandArgs(trailingOnly = TRUE)
repo <- normalizePath(if (length(args)) args[[1L]] else ".", mustWork = TRUE)
results <- Sys.getenv("FASTPLS_ABLATION_OUT")
if (!nzchar(results)) {
  results_root <- Sys.getenv("FASTPLS_RESULTS_ROOT")
  if (!nzchar(results_root)) {
    stop("Set FASTPLS_ABLATION_OUT or FASTPLS_RESULTS_ROOT.", call. = FALSE)
  }
  results <- file.path(results_root, "simpls_ablation")
}
task_dir <- Sys.getenv(
  "FASTPLS_ABLATION_TASK_ROOT", Sys.getenv("FASTPLS_DATA_ROOT")
)
if (!nzchar(task_dir)) stop("Set FASTPLS_DATA_ROOT.", call. = FALSE)
lib <- Sys.getenv("FASTPLS_ABLATION_LIB")
if (!nzchar(lib)) stop("Set FASTPLS_ABLATION_LIB.", call. = FALSE)
dir.create(file.path(results, "rows"), recursive = TRUE, showWarnings = FALSE)
dir.create(file.path(results, "predictions"), recursive = TRUE, showWarnings = FALSE)
dir.create(file.path(results, "logs"), recursive = TRUE, showWarnings = FALSE)
force <- identical(tolower(Sys.getenv("FASTPLS_ABLATION_FORCE", "false")), "true")
time_flag <- if (identical(Sys.info()[["sysname"]], "Darwin")) "-l" else "-v"

cases <- data.frame(
  dataset = c("metref", "ccle", "gtex_v8", "prism"),
  ncomp = c(22L, 20L, 50L, 5L),
  stringsAsFactors = FALSE
)
configs <- c(
  "xtx_off", "xtx_on",
  "coefficients_recomputed", "coefficients_incremental",
  "deflation_inline", "deflation_cached",
  "coefficient_cube", "compact_prediction",
  "explicit_crosscov", "matrix_free"
)

for (i in seq_len(nrow(cases))) {
  task <- file.path(task_dir, paste0(cases$dataset[[i]], "_task.rds"))
  for (config in configs) {
    for (replicate in 1:3) {
      stem <- sprintf(
        "%s_%s_n%d_rep%d",
        cases$dataset[[i]], config, cases$ncomp[[i]], replicate
      )
      output <- file.path(results, "rows", paste0(stem, ".csv"))
      prediction <- file.path(results, "predictions", paste0(stem, ".rds"))
      stdout_path <- file.path(results, "logs", paste0(stem, ".stdout.log"))
      time_path <- file.path(results, "logs", paste0(stem, ".time.log"))
      if (file.exists(output) && !force) next
      command <- c(
        file.path(repo, "benchmark", "benchmark_simpls_multidataset_ablation.R"),
        paste0("--task=", task),
        paste0("--dataset=", cases$dataset[[i]]),
        paste0("--ncomp=", cases$ncomp[[i]]),
        paste0("--configuration=", config),
        paste0("--replicate=", replicate),
        "--seed=123",
        paste0("--output=", output),
        paste0("--prediction-output=", prediction)
      )
      message(format(Sys.time()), " ", stem)
      status <- system2(
        "/usr/bin/time", c(time_flag, "Rscript", command),
        env = paste0("FASTPLS_ABLATION_LIB=", shQuote(lib)),
        stdout = stdout_path, stderr = time_path
      )
      if (!identical(status, 0L)) {
        detail <- c(
          if (file.exists(stdout_path)) readLines(stdout_path, warn = FALSE),
          if (file.exists(time_path)) readLines(time_path, warn = FALSE)
        )
        warning(paste(detail, collapse = "\n"), call. = FALSE)
      }
      if (file.exists(output)) {
        timing <- if (file.exists(time_path)) {
          readLines(time_path, warn = FALSE)
        } else {
          character()
        }
        maximum <- grep("maximum resident set size", timing, value = TRUE,
                        ignore.case = TRUE)
        row <- read.csv(output, check.names = FALSE)
        peak_mb <- if (length(maximum)) {
          if (identical(time_flag, "-l")) {
            as.numeric(sub("^\\s*([0-9]+).*", "\\1", maximum[[1L]])) / 1024^2
          } else {
            as.numeric(sub(".*:[[:space:]]*", "", maximum[[1L]])) / 1024
          }
        } else {
          NA_real_
        }
        row$fit_window_peak_rss_mb <- peak_mb
        row$incremental_peak_rss_mb <- pmax(
          0, peak_mb - row$rss_before_fit_mb
        )
        write.csv(row, output, row.names = FALSE)
      }
    }
  }
}

status <- system2(
  "Rscript",
  c(file.path(repo, "benchmark", "summarize_simpls_multidataset_ablation.R"), results)
)
quit(status = status)
