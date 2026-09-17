#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
results_dir <- if (length(args)) args[[1L]] else "benchmark_results/simpls_multidataset_ablation"
files <- list.files(file.path(results_dir, "rows"), pattern = "\\.csv$", full.names = TRUE)
if (!length(files)) stop("No ablation rows found")
raw <- do.call(rbind, lapply(files, read.csv, check.names = FALSE))
write.csv(raw, file.path(results_dir, "simpls_multidataset_ablation_raw.csv"), row.names = FALSE)

prediction_file <- function(row) {
  file.path(
    results_dir, "predictions",
    sprintf("%s_%s_n%d_rep%d.rds", row$dataset, row$configuration, row$ncomp, row$replicate)
  )
}

pair_reference <- c(
  cached_XtX = "xtx_off",
  incremental_coefficients = "coefficients_recomputed",
  cached_deflation_products = "deflation_inline",
  compact_prediction = "coefficient_cube",
  matrix_free = "explicit_crosscov"
)

raw$prediction_agreement <- NA_real_
raw$max_abs_prediction_diff <- NA_real_
for (i in seq_len(nrow(raw))) {
  if (!identical(raw$status[[i]], "success")) next
  ref_config <- pair_reference[[raw$pair[[i]]]]
  ref_row <- raw[
    raw$dataset == raw$dataset[[i]] &
      raw$configuration == ref_config &
      raw$replicate == raw$replicate[[i]],
    , drop = FALSE
  ]
  if (!nrow(ref_row)) next
  path_a <- prediction_file(raw[i, , drop = FALSE])
  path_b <- prediction_file(ref_row[1L, , drop = FALSE])
  if (!file.exists(path_a) || !file.exists(path_b)) next
  a <- readRDS(path_a)
  b <- readRDS(path_b)
  if (identical(raw$task_type[[i]], "classification")) {
    raw$prediction_agreement[[i]] <- mean(as.character(a) == as.character(b), na.rm = TRUE)
  } else {
    keep <- is.finite(a) & is.finite(b)
    raw$prediction_agreement[[i]] <- if (sum(keep) > 1L) cor(a[keep], b[keep]) else NA_real_
    raw$max_abs_prediction_diff[[i]] <- if (any(keep)) max(abs(a[keep] - b[keep])) else NA_real_
  }
}
write.csv(raw, file.path(results_dir, "simpls_multidataset_ablation_raw.csv"), row.names = FALSE)

median_na <- function(x) if (all(is.na(x))) NA_real_ else median(x, na.rm = TRUE)
iqr_na <- function(x) if (all(is.na(x))) NA_real_ else IQR(x, na.rm = TRUE)
keys <- c("dataset", "task_type", "n_train", "n_test", "p", "q", "ncomp",
          "pair", "configuration", "optimized_value", "optimization_applicable",
          "metric_name")
groups <- split(raw[raw$status == "success", ], interaction(
  raw[raw$status == "success", keys], drop = TRUE, lex.order = TRUE
))
summary <- do.call(rbind, lapply(groups, function(x) {
  out <- x[1L, keys, drop = FALSE]
  out$replicates <- nrow(x)
  out$total_time_median_sec <- median_na(x$total_time_sec)
  out$total_time_iqr_sec <- iqr_na(x$total_time_sec)
  out$incremental_rss_median_mb <- median_na(x$incremental_peak_rss_mb)
  out$incremental_rss_iqr_mb <- iqr_na(x$incremental_peak_rss_mb)
  out$metric_median <- median_na(x$metric_value)
  out$prediction_agreement_min <- if (all(is.na(x$prediction_agreement))) NA_real_ else min(x$prediction_agreement, na.rm = TRUE)
  out$max_abs_prediction_diff <- if (all(is.na(x$max_abs_prediction_diff))) NA_real_ else max(x$max_abs_prediction_diff, na.rm = TRUE)
  out
}))

effects <- do.call(rbind, lapply(split(summary, interaction(summary$dataset, summary$pair, drop = TRUE)), function(x) {
  before <- x[!x$optimized_value, , drop = FALSE]
  after <- x[x$optimized_value, , drop = FALSE]
  if (nrow(before) != 1L || nrow(after) != 1L) return(NULL)
  pair_raw <- raw[
    raw$dataset == after$dataset &
      raw$pair == after$pair &
      raw$status == "success",
    , drop = FALSE
  ]
  reference_raw <- pair_raw[!pair_raw$optimized_value, , drop = FALSE]
  optimized_raw <- pair_raw[pair_raw$optimized_value, , drop = FALSE]
  paired <- merge(
    reference_raw[, c("replicate", "total_time_sec", "incremental_peak_rss_mb")],
    optimized_raw[, c("replicate", "total_time_sec", "incremental_peak_rss_mb")],
    by = "replicate", suffixes = c("_reference", "_optimized")
  )
  paired_speedup <- paired$total_time_sec_reference / paired$total_time_sec_optimized
  paired_rss_reduction <- 100 * (
    paired$incremental_peak_rss_mb_reference -
      paired$incremental_peak_rss_mb_optimized
  ) / paired$incremental_peak_rss_mb_reference
  data.frame(
    dataset = after$dataset,
    task_type = after$task_type,
    n_train = after$n_train,
    p = after$p,
    q = after$q,
    ncomp = after$ncomp,
    optimization = after$pair,
    optimization_applicable = after$optimization_applicable,
    reference_configuration = before$configuration,
    optimized_configuration = after$configuration,
    reference_time_sec = before$total_time_median_sec,
    optimized_time_sec = after$total_time_median_sec,
    speedup = before$total_time_median_sec / after$total_time_median_sec,
    speedup_iqr = iqr_na(paired_speedup),
    reference_incremental_rss_mb = before$incremental_rss_median_mb,
    optimized_incremental_rss_mb = after$incremental_rss_median_mb,
    rss_reduction_pct = 100 * (before$incremental_rss_median_mb - after$incremental_rss_median_mb) /
      before$incremental_rss_median_mb,
    rss_reduction_iqr_pct = iqr_na(paired_rss_reduction),
    metric_abs_diff = abs(before$metric_median - after$metric_median),
    prediction_agreement_min = after$prediction_agreement_min,
    max_abs_prediction_diff = after$max_abs_prediction_diff,
    stringsAsFactors = FALSE
  )
}))

write.csv(summary, file.path(results_dir, "simpls_multidataset_ablation_summary.csv"), row.names = FALSE)
write.csv(effects, file.path(results_dir, "simpls_multidataset_ablation_effects.csv"), row.names = FALSE)
print(effects)
