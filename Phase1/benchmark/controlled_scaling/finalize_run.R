#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 3L) stop("Usage: finalize_run.R RESULT_RDS SAMPLE_CSV TIME_LOG")

result_path <- args[[1L]]
sample_path <- args[[2L]]
time_path <- args[[3L]]
row <- readRDS(result_path)

samples <- if (file.exists(sample_path) && file.info(sample_path)$size > 0) {
  tryCatch(read.csv(sample_path, stringsAsFactors = FALSE), error = function(e) NULL)
} else NULL

if (!is.null(samples) && nrow(samples)) {
  rss <- samples$value_mb[samples$kind == "rss"]
  gpu_pid <- samples$value_mb[samples$kind == "gpu_pid"]
  gpu_total <- samples$value_mb[samples$kind == "gpu_total"]
  if (length(rss)) row$process_peak_rss_mb <- max(rss, na.rm = TRUE)
  if (length(gpu_pid)) row$gpu_process_peak_mb <- max(gpu_pid, na.rm = TRUE)
  if (length(gpu_total)) {
    row$gpu_total_baseline_mb <- gpu_total[[1L]]
    row$gpu_total_peak_mb <- max(gpu_total, na.rm = TRUE)
    row$gpu_total_incremental_mb <- max(0, row$gpu_total_peak_mb - row$gpu_total_baseline_mb)
  }
}

if (!is.finite(row$process_peak_rss_mb) && file.exists(time_path)) {
  lines <- readLines(time_path, warn = FALSE)
  linux <- grep("Maximum resident set size", lines, value = TRUE)
  mac <- grep("maximum resident set size", lines, value = TRUE)
  if (length(linux)) {
    kb <- suppressWarnings(as.numeric(gsub("[^0-9]", "", tail(linux, 1L))))
    if (is.finite(kb)) row$process_peak_rss_mb <- kb / 1024
  } else if (length(mac)) {
    bytes <- suppressWarnings(as.numeric(strsplit(trimws(tail(mac, 1L)), " +")[[1L]][1L]))
    if (is.finite(bytes)) row$process_peak_rss_mb <- bytes / 1024^2
  }
}

if (is.finite(row$process_peak_rss_mb) && is.finite(row$baseline_rss_mb)) {
  row$incremental_peak_rss_mb <- max(0, row$process_peak_rss_mb - row$baseline_rss_mb)
}

saveRDS(row, result_path)
write.csv(row, sub("[.]rds$", ".csv", result_path), row.names = FALSE)
