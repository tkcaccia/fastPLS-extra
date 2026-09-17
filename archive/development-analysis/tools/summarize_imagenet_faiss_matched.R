#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
input <- if (length(args)) args[[1L]] else
  "benchmark_results/imagenet_faiss_matched_1m_20260725/raw"
output <- if (length(args) > 1L) args[[2L]] else
  "benchmark_results/imagenet_faiss_matched_1m_20260725"
dir.create(file.path(output, "plots"), recursive = TRUE, showWarnings = FALSE)

files <- list.files(input, pattern = "_cuda_(exact|ivf)\\.csv$", full.names = TRUE)
stopifnot(length(files) > 0L)
raw <- do.call(rbind, lapply(files, read.csv, stringsAsFactors = FALSE))

space_code <- c(raw_dinov2 = "raw", pca_scores = "pca", pls_scores = "pls")
raw$space_code <- unname(space_code[raw$feature_space])
raw$component_label <- ifelse(is.na(raw$ncomp), "raw", as.character(raw$ncomp))
raw$gpu_peak_file <- file.path(
  input,
  sprintf(
    "%s_k%s_%s_peak_gpu_mb.txt",
    raw$space_code,
    ifelse(raw$space_code == "raw", "100", raw$component_label),
    raw$faiss_method
  )
)
raw$search_peak_gpu_mb <- vapply(raw$gpu_peak_file, function(path) {
  if (!file.exists(path)) return(NA_real_)
  as.numeric(readLines(path, warn = FALSE)[[1L]])
}, numeric(1L))

prep_gpu <- c(
  pls_scores = as.numeric(readLines(
    file.path(input, "prepare_pls_peak_gpu_mb.txt"), warn = FALSE
  )[[1L]]),
  pca_scores = as.numeric(readLines(
    file.path(input, "prepare_pca_peak_gpu_mb.txt"), warn = FALSE
  )[[1L]]),
  raw_dinov2 = 0
)
raw$preparation_peak_gpu_mb <- unname(prep_gpu[raw$feature_space])
raw$end_to_end_peak_gpu_mb <- pmax(
  raw$preparation_peak_gpu_mb, raw$search_peak_gpu_mb, na.rm = TRUE
)
raw$end_to_end_peak_host_rss_mb <- pmax(
  raw$preparation_peak_host_rss_mb, raw$search_peak_host_rss_mb, na.rm = TRUE
)
write.csv(raw, file.path(output, "imagenet_faiss_matched_raw.csv"), row.names = FALSE)

key <- interaction(
  raw$feature_space, raw$component_label, raw$faiss_method, drop = TRUE
)
groups <- split(raw, key)
summary <- do.call(rbind, lapply(groups, function(part) {
  data.frame(
    feature_space = part$feature_space[[1L]],
    ncomp = part$ncomp[[1L]],
    component_label = part$component_label[[1L]],
    n_features = part$n_features[[1L]],
    compression_ratio = part$compression_ratio[[1L]],
    precision = part$precision[[1L]],
    train_n = part$train_n[[1L]],
    eval_n = part$eval_n[[1L]],
    faiss_method = part$faiss_method[[1L]],
    n_repeats = nrow(part),
    transformation_time_sec = part$transformation_time_sec[[1L]],
    fit_time_sec = part$fit_time_sec[[1L]],
    train_projection_time_sec = part$train_projection_time_sec[[1L]],
    test_projection_time_sec = part$test_projection_time_sec[[1L]],
    query_time_median_sec = median(part$query_time_sec),
    query_time_iqr_sec = IQR(part$query_time_sec),
    inference_time_median_sec = median(part$inference_time_sec),
    inference_time_iqr_sec = IQR(part$inference_time_sec),
    end_to_end_time_median_sec = median(part$end_to_end_time_sec),
    end_to_end_time_iqr_sec = IQR(part$end_to_end_time_sec),
    top1_accuracy = part$top1_accuracy[[1L]],
    top5_accuracy = part$top5_accuracy[[1L]],
    balanced_accuracy = part$balanced_accuracy[[1L]],
    neighbour_recall_at_10 = part$neighbour_recall_at_10[[1L]],
    peak_host_rss_mb = max(part$end_to_end_peak_host_rss_mb, na.rm = TRUE),
    peak_gpu_mem_mb = max(part$end_to_end_peak_gpu_mb, na.rm = TRUE),
    status = if (all(part$status == "success")) "success" else
      paste(unique(part$status), collapse = ";"),
    notes = paste(unique(part$notes), collapse = " "),
    stringsAsFactors = FALSE
  )
}))
rownames(summary) <- NULL
write.csv(
  summary,
  file.path(output, "imagenet_faiss_matched_summary.csv"),
  row.names = FALSE
)

exact <- summary[summary$faiss_method == "exact", ]
ivf <- summary[summary$faiss_method == "ivf",
               c("feature_space", "component_label", "neighbour_recall_at_10",
                 "query_time_median_sec", "query_time_iqr_sec",
                 "top1_accuracy", "top5_accuracy")]
names(ivf)[-(1:2)] <- paste0("ivf_", names(ivf)[-(1:2)])
table <- merge(
  exact, ivf, by = c("feature_space", "component_label"), all.x = TRUE
)
table$representation <- factor(
  table$feature_space,
  levels = c("raw_dinov2", "pca_scores", "pls_scores"),
  labels = c("Raw DINOv2", "PCA-rSVD scores", "PLS-SVD/rSVD scores")
)
table <- table[order(table$representation, table$n_features), ]
write.csv(
  table,
  file.path(output, "imagenet_faiss_matched_main_table.csv"),
  row.names = FALSE
)

suppressPackageStartupMessages({
  library(ggplot2)
  library(patchwork)
})
palette <- c(
  "Raw DINOv2" = "#222222",
  "PCA-rSVD scores" = "#2F6690",
  "PLS-SVD/rSVD scores" = "#C44536"
)
plot_data <- table
plot_data$feature_dimension <- plot_data$n_features

accuracy <- rbind(
  transform(plot_data, metric = "Top-1", value = top1_accuracy),
  transform(plot_data, metric = "Top-5", value = top5_accuracy)
)
p1 <- ggplot(
  accuracy,
  aes(feature_dimension, value, colour = representation,
      linetype = metric, group = interaction(representation, metric))
) +
  geom_line(linewidth = 0.8) +
  geom_point(size = 2.5) +
  scale_x_log10(breaks = c(50, 100, 200, 1024)) +
  scale_colour_manual(values = palette) +
  labs(x = "Representation dimension", y = "Accuracy", title = "A  Predictive performance") +
  theme_bw(base_size = 11)

p2 <- ggplot(
  plot_data,
  aes(feature_dimension, inference_time_median_sec, colour = representation,
      group = representation)
) +
  geom_line(linewidth = 0.8) +
  geom_point(size = 2.5) +
  scale_x_log10(breaks = c(50, 100, 200, 1024)) +
  scale_y_log10() +
  scale_colour_manual(values = palette) +
  labs(x = "Representation dimension", y = "Held-out transform + query (s)",
       title = "B  Inference time") +
  theme_bw(base_size = 11)

p3 <- ggplot(
  plot_data,
  aes(feature_dimension, end_to_end_time_median_sec, colour = representation,
      group = representation)
) +
  geom_line(linewidth = 0.8) +
  geom_point(size = 2.5) +
  scale_x_log10(breaks = c(50, 100, 200, 1024)) +
  scale_y_log10() +
  scale_colour_manual(values = palette) +
  labs(x = "Representation dimension", y = "Fit + projections + query (s)",
       title = "C  End-to-end time") +
  theme_bw(base_size = 11)

memory <- rbind(
  transform(plot_data, memory = "Host RSS", value = peak_host_rss_mb),
  transform(plot_data, memory = "GPU", value = peak_gpu_mem_mb)
)
p4 <- ggplot(
  memory,
  aes(feature_dimension, value, colour = representation,
      linetype = memory, group = interaction(representation, memory))
) +
  geom_line(linewidth = 0.8) +
  geom_point(size = 2.5) +
  scale_x_log10(breaks = c(50, 100, 200, 1024)) +
  scale_y_log10() +
  scale_colour_manual(values = palette) +
  labs(x = "Representation dimension", y = "Peak memory (MB)",
       title = "D  Memory") +
  theme_bw(base_size = 11)

combined <- (p1 + p2) / (p3 + p4) +
  plot_layout(guides = "collect") &
  theme(
    legend.position = "bottom",
    legend.box = "vertical",
    plot.title = element_text(face = "bold", size = 11)
  )
ggsave(
  file.path(output, "plots", "imagenet_matched_retrieval.png"),
  combined, width = 8.2, height = 6.6, dpi = 320
)
ggsave(
  file.path(output, "plots", "imagenet_matched_retrieval.pdf"),
  combined, width = 8.2, height = 6.6
)
