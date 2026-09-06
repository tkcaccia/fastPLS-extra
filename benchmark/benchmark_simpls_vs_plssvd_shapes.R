#!/usr/bin/env Rscript

# Direct matched PLS-SVD versus SIMPLS speed comparison across matrix shapes.
# Each pair changes only the PLS family. The worker runs every fit in a fresh
# process and records fit plus prediction time and held-out regression metrics.

args <- commandArgs(trailingOnly = TRUE)
repo_dir <- if (length(args) >= 1L) {
  normalizePath(args[[1L]], winslash = "/", mustWork = TRUE)
} else {
  normalizePath(".", winslash = "/", mustWork = TRUE)
}
out_dir <- if (length(args) >= 2L) {
  args[[2L]]
} else {
  file.path(
    repo_dir,
    "benchmark_results",
    paste0("simpls_vs_plssvd_shapes_", format(Sys.time(), "%Y%m%d_%H%M%S"))
  )
}
backends <- if (length(args) >= 3L) {
  trimws(strsplit(args[[3L]], ",", fixed = TRUE)[[1L]])
} else {
  c("cpu", "cuda")
}
backends <- backends[nzchar(backends)]
if (!length(backends)) stop("At least one backend is required.", call. = FALSE)

worker <- file.path(
  repo_dir, "benchmark", "metal_validation", "metal_worker.R"
)
if (!file.exists(worker)) stop("Missing worker: ", worker, call. = FALSE)
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

shapes <- list(
  wide = c(n_train = 400, n_test = 100, p = 2000, q = 20, k = 10),
  tall_thin = c(n_train = 5000, n_test = 1000, p = 50, q = 20, k = 10),
  high_response = c(n_train = 1000, n_test = 250, p = 300, q = 500, k = 50),
  balanced = c(n_train = 5000, n_test = 1000, p = 500, q = 50, k = 50),
  high_components = c(
    n_train = 3000, n_test = 600, p = 768, q = 200, k = 100
  )
)

make_config <- function(shape_name, shape, method, backend, replicate) {
  seed <- 100L + replicate
  list(
    run_id = paste(
      "matched_shape", shape_name, method, backend,
      paste0("r", replicate), paste0("s", seed), sep = "__"
    ),
    experiment = "matched_shape_family",
    dataset = paste0("synthetic_", shape_name),
    task_type = "regression",
    method = method,
    backend = backend,
    precision = "float64",
    classifier = "argmax",
    ncomp = as.integer(shape[["k"]]),
    replicate = as.integer(replicate),
    seed = seed,
    data_seed = 777L,
    oversample = 32L,
    power = 5L,
    svd_method = "rsvd",
    task_path = NULL,
    n_train = as.integer(shape[["n_train"]]),
    n_test = as.integer(shape[["n_test"]]),
    p = as.integer(shape[["p"]]),
    q = as.integer(shape[["q"]]),
    latent_rank = as.integer(min(20L, shape[["p"]], shape[["q"]])),
    noise = 0.25,
    train_n = NULL,
    test_n = NULL,
    p_limit = NULL,
    q_limit = NULL,
    kernel = "linear",
    gamma = NULL,
    degree = 3L,
    coef0 = 1,
    north = 1L,
    scaling = "centering",
    save_diagnostics = FALSE
  )
}

runs <- list()
for (shape_name in names(shapes)) {
  for (method in c("plssvd", "simpls")) {
    for (backend in backends) {
      for (replicate in 1:3) {
        runs[[length(runs) + 1L]] <- make_config(
          shape_name, shapes[[shape_name]], method, backend, replicate
        )
      }
    }
  }
}
saveRDS(runs, file.path(out_dir, "configurations.rds"))

parse_peak_rss <- function(path) {
  if (!file.exists(path)) return(NA_real_)
  lines <- readLines(path, warn = FALSE)
  hit <- grep(
    "Maximum resident set size \\(kbytes\\)|maximum resident set size",
    lines,
    value = TRUE
  )
  if (!length(hit)) return(NA_real_)
  value <- suppressWarnings(as.numeric(gsub("[^0-9]", "", tail(hit, 1L))))
  if (!is.finite(value)) return(NA_real_)
  if (grepl("kbytes", tail(hit, 1L), ignore.case = TRUE)) value / 1024 else
    value / 1024^2
}

empty_result <- function(config, status, error) {
  data.frame(
    run_id = config$run_id,
    experiment = config$experiment,
    dataset = config$dataset,
    task_type = config$task_type,
    method = config$method,
    backend_requested = config$backend,
    backend_reported = NA_character_,
    prediction_backend = NA_character_,
    svd_method = config$svd_method,
    classifier = config$classifier,
    precision = config$precision,
    ncomp = config$ncomp,
    n_train = config$n_train,
    n_test = config$n_test,
    p = config$p,
    q = config$q,
    seed = config$seed,
    replicate = config$replicate,
    oversample = config$oversample,
    power = config$power,
    kernel = config$kernel,
    north = config$north,
    fit_sec = NA_real_,
    prediction_sec = NA_real_,
    total_sec = NA_real_,
    baseline_rss_mb = NA_real_,
    rss_after_fit_mb = NA_real_,
    rss_after_prediction_mb = NA_real_,
    peak_rss_mb = NA_real_,
    incremental_peak_rss_mb = NA_real_,
    metric_name = "rmsd",
    metric_value = NA_real_,
    accuracy = NA_real_,
    q2 = NA_real_,
    rmsd = NA_real_,
    prediction_checksum = NA_real_,
    prediction_length = NA_integer_,
    status = status,
    warnings = "",
    error = error,
    stringsAsFactors = FALSE
  )
}

raw_file <- file.path(out_dir, "simpls_vs_plssvd_shapes_raw.csv")
rows <- list()
for (index in seq_along(runs)) {
  config <- runs[[index]]
  message(
    sprintf(
      "[%s] %d/%d %s",
      format(Sys.time(), "%Y-%m-%d %H:%M:%S"),
      index, length(runs), config$run_id
    )
  )
  config_path <- file.path(out_dir, paste0(config$run_id, "_config.rds"))
  result_path <- file.path(out_dir, paste0(config$run_id, "_result.rds"))
  stdout_path <- file.path(out_dir, paste0(config$run_id, ".out"))
  time_path <- file.path(out_dir, paste0(config$run_id, ".time"))
  saveRDS(config, config_path)

  time_flag <- if (identical(Sys.info()[["sysname"]], "Darwin")) "-l" else "-v"
  command_args <- c(
    "300s", "/usr/bin/time", time_flag,
    file.path(R.home("bin"), "Rscript"),
    worker, config_path, result_path
  )
  exit_status <- system2(
    "timeout",
    command_args,
    stdout = stdout_path,
    stderr = time_path
  )
  if (file.exists(result_path)) {
    row <- readRDS(result_path)
  } else {
    row <- empty_result(
      config,
      if (identical(exit_status, 124L)) "timeout" else "process_failed",
      paste("exit status", exit_status)
    )
  }
  row$peak_rss_mb <- parse_peak_rss(time_path)
  row$incremental_peak_rss_mb <- if (
    is.finite(row$peak_rss_mb) && is.finite(row$baseline_rss_mb)
  ) {
    max(0, row$peak_rss_mb - row$baseline_rss_mb)
  } else {
    NA_real_
  }
  rows[[length(rows) + 1L]] <- row
  utils::write.csv(do.call(rbind, rows), raw_file, row.names = FALSE)
  unlink(config_path)
}

raw <- do.call(rbind, rows)
success <- raw[raw$status == "success" & is.finite(raw$total_sec), , drop = FALSE]
if (!nrow(success)) {
  stop("No matched shape run completed; inspect per-run output files.", call. = FALSE)
}
keys <- c("dataset", "method", "backend_requested")
groups <- split(success, interaction(success[keys], drop = TRUE))
summary_rows <- lapply(groups, function(x) {
  data.frame(
    dataset = x$dataset[[1L]],
    method = x$method[[1L]],
    backend = x$backend_requested[[1L]],
    n_train = x$n_train[[1L]],
    n_test = x$n_test[[1L]],
    p = x$p[[1L]],
    q = x$q[[1L]],
    ncomp = x$ncomp[[1L]],
    oversample = x$oversample[[1L]],
    power = x$power[[1L]],
    seeds = paste(sort(unique(x$seed)), collapse = "/"),
    median_total_sec = stats::median(x$total_sec),
    iqr_total_sec = stats::IQR(x$total_sec),
    median_fit_sec = stats::median(x$fit_sec),
    median_prediction_sec = stats::median(x$prediction_sec),
    median_rmsd = stats::median(x$rmsd),
    median_q2 = stats::median(x$q2),
    median_peak_rss_mb = stats::median(x$peak_rss_mb, na.rm = TRUE),
    completed_runs = nrow(x),
    stringsAsFactors = FALSE
  )
})
summary <- do.call(rbind, summary_rows)
summary <- summary[order(summary$backend, summary$dataset, summary$method), ]
utils::write.csv(
  summary,
  file.path(out_dir, "simpls_vs_plssvd_shapes_summary.csv"),
  row.names = FALSE
)

pair_keys <- unique(summary[c("dataset", "backend")])
paired <- do.call(rbind, lapply(seq_len(nrow(pair_keys)), function(i) {
  key <- pair_keys[i, ]
  x <- summary[
    summary$dataset == key$dataset &
      summary$backend == key$backend,
    ,
    drop = FALSE
  ]
  a <- x[x$method == "plssvd", , drop = FALSE]
  b <- x[x$method == "simpls", , drop = FALSE]
  if (!nrow(a) || !nrow(b)) return(NULL)
  data.frame(
    dataset = key$dataset,
    backend = key$backend,
    n_train = a$n_train,
    n_test = a$n_test,
    p = a$p,
    q = a$q,
    ncomp = a$ncomp,
    plssvd_total_sec = a$median_total_sec,
    simpls_total_sec = b$median_total_sec,
    simpls_over_plssvd_time = b$median_total_sec / a$median_total_sec,
    plssvd_rmsd = a$median_rmsd,
    simpls_rmsd = b$median_rmsd,
    plssvd_q2 = a$median_q2,
    simpls_q2 = b$median_q2,
    completed_runs_each = min(a$completed_runs, b$completed_runs),
    stringsAsFactors = FALSE
  )
}))
utils::write.csv(
  paired,
  file.path(out_dir, "simpls_vs_plssvd_shapes_paired.csv"),
  row.names = FALSE
)

if (requireNamespace("ggplot2", quietly = TRUE)) {
  shape_order <- paste0("synthetic_", names(shapes))
  paired$dataset <- factor(paired$dataset, levels = shape_order)
  p_ratio <- ggplot2::ggplot(
    paired,
    ggplot2::aes(dataset, simpls_over_plssvd_time, colour = backend, group = backend)
  ) +
    ggplot2::geom_hline(yintercept = 1, linetype = "dashed", colour = "#555555") +
    ggplot2::geom_line(linewidth = 0.7) +
    ggplot2::geom_point(size = 2.5) +
    ggplot2::scale_y_log10() +
    ggplot2::labs(
      x = "Matrix-shape regime",
      y = "SIMPLS / PLS-SVD total time",
      title = "Matched PLS-family runtime across matrix shapes",
      subtitle = "Values below 1 favour SIMPLS; all non-family factors are fixed"
    ) +
    ggplot2::theme_classic(base_size = 11) +
    ggplot2::theme(
      plot.title = ggplot2::element_text(face = "bold"),
      axis.text.x = ggplot2::element_text(angle = 25, hjust = 1)
    )
  ggplot2::ggsave(
    file.path(out_dir, "simpls_vs_plssvd_time_ratio.png"),
    p_ratio, width = 7.5, height = 4.8, dpi = 320
  )
  ggplot2::ggsave(
    file.path(out_dir, "simpls_vs_plssvd_time_ratio.pdf"),
    p_ratio, width = 7.5, height = 4.8
  )
}

writeLines(
  c(
    paste("created:", format(Sys.time(), "%Y-%m-%d %H:%M:%S %z")),
    paste("R:", R.version.string),
    paste("fastPLS:", as.character(utils::packageVersion("fastPLS"))),
    paste("backends:", paste(backends, collapse = ",")),
    "precision: float64",
    "svd.method: rsvd",
    "oversample: 32",
    "power: 5",
    "data_seed: 777",
    "rsvd_seeds: 101/102/103",
    "replicates: 3",
    "timing: public fit plus public prediction",
    capture.output(sessionInfo())
  ),
  file.path(out_dir, "session_info.txt")
)

message("Results written to ", out_dir)
