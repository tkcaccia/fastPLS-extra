#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 3L) {
  stop("Usage: summarize_precision_memory_comparison.R FLOAT32_RAW FLOAT64_RAW OUT_DIR")
}
float32_file <- args[[1L]]
float64_file <- args[[2L]]
out_dir <- args[[3L]]
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

read_results <- function(path, precision) {
  if (!file.exists(path)) stop("Missing precision benchmark file: ", path)
  x <- read.csv(path, stringsAsFactors = FALSE, check.names = FALSE)
  x$comparison_precision <- precision
  x
}

raw_all <- rbind(
  read_results(float32_file, "float32"),
  read_results(float64_file, "float64")
)
raw <- raw_all
raw <- raw[raw$status %in% c("ok", "capped") &
             raw$classifier %in% c("argmax", "lda") &
             raw$backend != "pls_pkg" &
             raw$execution_precision == raw$comparison_precision, , drop = FALSE]
numeric_fields <- intersect(
  c(
    "requested_ncomp", "effective_ncomp", "fit_time_ms", "predict_time_ms",
    "total_time_ms", "metric_value", "accuracy", "top5_accuracy",
    "balanced_accuracy", "macro_f1", "input_storage_mb", "peak_host_rss_mb",
    "peak_gpu_mem_mb", "rss_before_fit_mb", "rss_after_fit_mb",
    "rss_after_predict_mb"
  ),
  names(raw)
)
raw[numeric_fields] <- lapply(raw[numeric_fields], function(x) suppressWarnings(as.numeric(x)))
raw$incremental_host_rss_mb <- ifelse(
  is.finite(raw$peak_host_rss_mb) & is.finite(raw$rss_before_fit_mb),
  pmax(0, raw$peak_host_rss_mb - raw$rss_before_fit_mb),
  NA_real_
)
numeric_fields <- unique(c(numeric_fields, "incremental_host_rss_mb"))

raw$numeric_scope <- ifelse(
  raw$execution_precision == "float32" & raw$classifier_numeric_path == "float32",
  "end_to_end_float32",
  ifelse(
    raw$execution_precision == "float32",
    paste0("float32_fit_with_", raw$classifier_numeric_path, "_classifier"),
    "float64"
  )
)
raw$accelerator_scope <- ifelse(
  tolower(raw$engine) != "gpu",
  "compiled_cpu",
  ifelse(
    raw$execution_precision == "float32",
    paste0(
      "gpu_rsvd_range_products_plus_host_float32_pls; classifier=",
      raw$classifier_backend
    ),
    "cuda_backend"
  )
)
raw$whole_fit_gpu_resident <- ifelse(
  tolower(raw$engine) != "gpu",
  "not_applicable",
  ifelse(raw$execution_precision == "float32", "no", "backend_dependent")
)

group_fields <- intersect(
  c(
    "dataset", "task_type", "variant_name", "requested_method", "executed_method",
    "classifier", "engine", "backend", "implementation_label", "requested_ncomp",
    "metric_name", "comparison_precision", "classifier_numeric_path",
    "numeric_scope", "accelerator_scope", "whole_fit_gpu_resident"
  ),
  names(raw)
)

# Keep failed, skipped, and timed-out runs visible beside the successful-run
# summaries. This prevents a median from concealing an incomplete comparison.
status_raw <- raw_all[
    raw_all$classifier %in% c("argmax", "lda") &
    raw_all$backend != "pls_pkg" &
    (is.na(raw_all$execution_precision) |
       !nzchar(raw_all$execution_precision) |
       raw_all$execution_precision == raw_all$comparison_precision),
  , drop = FALSE
]
status_group_fields <- intersect(group_fields, names(status_raw))
status_keys <- interaction(status_raw[status_group_fields], drop = TRUE, lex.order = TRUE)
status_groups <- split(seq_len(nrow(status_raw)), status_keys)
status_summary <- do.call(rbind, lapply(status_groups, function(idx) {
  row <- status_raw[idx[[1L]], status_group_fields, drop = FALSE]
  status <- tolower(status_raw$status[idx])
  row$n_attempted <- length(idx)
  row$n_successful <- sum(status %in% c("ok", "capped"))
  row$n_timeout <- sum(grepl("timeout", status, fixed = TRUE))
  row$n_error <- sum(status %in% c("error", "killed", "oom"))
  row$n_skipped <- sum(grepl("skip", status, fixed = TRUE))
  row
}))
rownames(status_summary) <- NULL
write.csv(
  status_summary,
  file.path(out_dir, "precision_memory_status_counts.csv"),
  row.names = FALSE,
  na = ""
)

median_na <- function(x) if (all(is.na(x))) NA_real_ else median(x, na.rm = TRUE)
iqr_na <- function(x) {
  x <- x[is.finite(x)]
  if (length(x) < 2L) NA_real_ else IQR(x)
}
keys <- interaction(raw[group_fields], drop = TRUE, lex.order = TRUE)
groups <- split(seq_len(nrow(raw)), keys)
summary <- do.call(rbind, lapply(groups, function(idx) {
  row <- raw[idx[[1L]], group_fields, drop = FALSE]
  for (field in numeric_fields) {
    row[[field]] <- median_na(raw[[field]][idx])
    row[[paste0(field, "_iqr")]] <- iqr_na(raw[[field]][idx])
  }
  row$n_replicates <- length(idx)
  row
}))
rownames(summary) <- NULL
summary <- merge(
  summary,
  status_summary,
  by = status_group_fields,
  all.x = TRUE,
  sort = FALSE
)
write.csv(summary, file.path(out_dir, "precision_memory_summary_long.csv"), row.names = FALSE, na = "")

identity_fields <- setdiff(
  group_fields,
  c(
    "comparison_precision", "classifier_numeric_path", "executed_method",
    "implementation_label", "numeric_scope", "accelerator_scope",
    "whole_fit_gpu_resident"
  )
)
f32 <- summary[summary$comparison_precision == "float32", , drop = FALSE]
f64 <- summary[summary$comparison_precision == "float64", , drop = FALSE]
paired <- merge(f32, f64, by = identity_fields, suffixes = c("_float32", "_float64"), all = TRUE)

ratio <- function(numerator, denominator) {
  ifelse(is.finite(numerator) & is.finite(denominator) & denominator > 0,
         numerator / denominator, NA_real_)
}
paired$host_rss_ratio_float32_to_float64 <- ratio(
  paired$peak_host_rss_mb_float32, paired$peak_host_rss_mb_float64
)
paired$host_rss_reduction_pct <- 100 * (1 - paired$host_rss_ratio_float32_to_float64)
paired$incremental_host_rss_ratio_float32_to_float64 <- ratio(
  paired$incremental_host_rss_mb_float32,
  paired$incremental_host_rss_mb_float64
)
paired$incremental_host_rss_reduction_pct <-
  100 * (1 - paired$incremental_host_rss_ratio_float32_to_float64)
paired$input_storage_ratio_float32_to_float64 <- ratio(
  paired$input_storage_mb_float32, paired$input_storage_mb_float64
)
paired$input_storage_reduction_pct <-
  100 * (1 - paired$input_storage_ratio_float32_to_float64)
paired$gpu_mem_ratio_float32_to_float64 <- ratio(
  paired$peak_gpu_mem_mb_float32, paired$peak_gpu_mem_mb_float64
)
paired$gpu_mem_reduction_pct <- 100 * (1 - paired$gpu_mem_ratio_float32_to_float64)
paired$float32_speedup <- ratio(paired$total_time_ms_float64, paired$total_time_ms_float32)
paired$prediction_metric_delta_float32_minus_float64 <-
  paired$metric_value_float32 - paired$metric_value_float64
paired$top5_delta_float32_minus_float64 <-
  paired$top5_accuracy_float32 - paired$top5_accuracy_float64
write.csv(paired, file.path(out_dir, "precision_memory_paired_comparison.csv"), row.names = FALSE, na = "")

publication_fields <- intersect(
  c(
    identity_fields,
    "numeric_scope_float32", "accelerator_scope_float32",
    "whole_fit_gpu_resident_float32", "input_storage_mb_float32",
    "input_storage_mb_float64", "input_storage_reduction_pct",
    "incremental_host_rss_mb_float32", "incremental_host_rss_mb_float64",
    "incremental_host_rss_reduction_pct", "peak_host_rss_mb_float32",
    "peak_host_rss_mb_float64", "host_rss_reduction_pct",
    "peak_gpu_mem_mb_float32", "peak_gpu_mem_mb_float64",
    "gpu_mem_reduction_pct", "total_time_ms_float32", "total_time_ms_float64",
    "float32_speedup", "metric_value_float32", "metric_value_float64",
    "prediction_metric_delta_float32_minus_float64", "top5_accuracy_float32",
    "top5_accuracy_float64", "top5_delta_float32_minus_float64",
    "n_attempted_float32", "n_attempted_float64",
    "n_successful_float32", "n_successful_float64",
    "n_timeout_float32", "n_timeout_float64",
    "n_error_float32", "n_error_float64",
    "n_skipped_float32", "n_skipped_float64",
    "total_time_ms_iqr_float32", "total_time_ms_iqr_float64",
    "metric_value_iqr_float32", "metric_value_iqr_float64",
    "peak_host_rss_mb_iqr_float32", "peak_host_rss_mb_iqr_float64",
    "peak_gpu_mem_mb_iqr_float32", "peak_gpu_mem_mb_iqr_float64"
  ),
  names(paired)
)
publication <- paired[publication_fields]
write.csv(
  publication,
  file.path(out_dir, "precision_memory_publication_table.csv"),
  row.names = FALSE,
  na = ""
)

if (!requireNamespace("ggplot2", quietly = TRUE) || !nrow(summary)) quit(save = "no")
library(ggplot2)

reduction_labels <- c(
  input_storage_reduction_pct = "Input storage reduction (%)",
  incremental_host_rss_reduction_pct = "Incremental host RSS reduction (%)",
  gpu_mem_reduction_pct = "Peak GPU memory reduction (%)"
)
reduction_data <- do.call(rbind, lapply(names(reduction_labels), function(field) {
  data.frame(
    paired[intersect(
      c("dataset", "requested_method", "classifier", "backend", "requested_ncomp"),
      names(paired)
    )],
    panel = reduction_labels[[field]],
    value = paired[[field]],
    stringsAsFactors = FALSE
  )
}))
reduction_data$panel <- factor(reduction_data$panel, levels = unname(reduction_labels))
reduction_data <- reduction_data[is.finite(reduction_data$value), , drop = FALSE]
if (nrow(reduction_data)) {
  p <- ggplot(
    reduction_data,
    aes(requested_method, value, color = backend, shape = classifier,
        group = interaction(backend, classifier))
  ) +
    geom_hline(yintercept = 0, color = "grey65", linewidth = 0.35) +
    geom_point(position = position_dodge(width = 0.55), size = 2.2, alpha = 0.9) +
    facet_grid(panel ~ dataset, scales = "free_y") +
    labs(
      title = "Measured float32 memory reduction relative to matched float64 runs",
      x = NULL, y = NULL, color = "Backend", shape = "Classifier"
    ) +
    theme_bw(base_size = 11) +
    theme(
      axis.text.x = element_text(angle = 45, hjust = 1),
      legend.position = "bottom",
      panel.grid.minor = element_blank(),
      strip.text = element_text(face = "bold")
    )
  ggsave(file.path(out_dir, "precision_memory_comparison.png"), p,
         width = 15, height = 9, dpi = 180)
  ggsave(file.path(out_dir, "precision_memory_comparison.pdf"), p,
         width = 15, height = 9)
}

absolute_labels <- c(
  total_time_ms = "Total time (ms)",
  metric_value = "Predictive metric",
  incremental_host_rss_mb = "Incremental host RSS (MB)",
  peak_host_rss_mb = "Peak host RSS (MB)",
  peak_gpu_mem_mb = "Peak GPU memory (MB)"
)
for (dataset_name in unique(summary$dataset)) {
  dataset_summary <- summary[summary$dataset == dataset_name, , drop = FALSE]
  absolute_data <- do.call(rbind, lapply(names(absolute_labels), function(field) {
    data.frame(
      dataset_summary[c(
        "variant_name", "requested_method", "backend", "classifier",
        "comparison_precision"
      )],
      panel = absolute_labels[[field]],
      value = dataset_summary[[field]],
      stringsAsFactors = FALSE
    )
  }))
  absolute_data$variant <- with(
    absolute_data,
    paste(requested_method, backend, classifier, sep = " / ")
  )
  absolute_data$panel <- factor(absolute_data$panel, levels = unname(absolute_labels))
  absolute_data <- absolute_data[is.finite(absolute_data$value), , drop = FALSE]
  if (!nrow(absolute_data)) next
  p_dataset <- ggplot(
    absolute_data,
    aes(variant, value, fill = comparison_precision)
  ) +
    geom_col(position = position_dodge(width = 0.75), width = 0.68) +
    facet_wrap(~panel, ncol = 1, scales = "free_y") +
    scale_fill_manual(values = c(float32 = "#009E73", float64 = "#0072B2")) +
    labs(
      title = paste(dataset_name, "matched float32 and float64 benchmarks"),
      x = NULL, y = NULL, fill = "Precision"
    ) +
    theme_bw(base_size = 11) +
    theme(
      axis.text.x = element_text(angle = 45, hjust = 1),
      legend.position = "bottom",
      panel.grid.minor = element_blank(),
      strip.text = element_text(face = "bold")
    )
  safe_name <- gsub("[^A-Za-z0-9_-]+", "_", tolower(dataset_name))
  ggsave(
    file.path(out_dir, paste0("precision_memory_absolute_", safe_name, ".png")),
    p_dataset,
    width = 14,
    height = 14,
    dpi = 180
  )
}
