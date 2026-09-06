#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
results_dir <- if (length(args)) args[[1L]] else
  "benchmark_results/simpls_multidataset_ablation"
effects_file <- file.path(results_dir, "simpls_multidataset_ablation_effects.csv")
if (!file.exists(effects_file)) stop("Missing effects table: ", effects_file)
if (!requireNamespace("ggplot2", quietly = TRUE)) stop("ggplot2 is required")

effects <- read.csv(effects_file, check.names = FALSE)
effects <- effects[effects$optimization_applicable & is.finite(effects$speedup), ]
labels <- c(
  cached_XtX = "Cached X'X",
  incremental_coefficients = "Incremental coefficients",
  cached_deflation_products = "Cached deflation products",
  compact_prediction = "Compact prediction",
  matrix_free = "Matrix-free products"
)
effects$optimization <- factor(
  effects$optimization,
  levels = names(labels),
  labels = unname(labels)
)

time_df <- data.frame(
  dataset = effects$dataset,
  optimization = effects$optimization,
  panel = "Runtime effect: log2(reference / optimized)",
  value = log2(effects$speedup)
)
memory_df <- data.frame(
  dataset = effects$dataset,
  optimization = effects$optimization,
  panel = "Incremental peak RSS reduction (%)",
  value = effects$rss_reduction_pct
)
plot_data <- rbind(time_df, memory_df)
plot_data$dataset <- factor(plot_data$dataset, levels = unique(effects$dataset))

jco <- c("#0073C2", "#EFC000", "#868686", "#CD534C", "#7AA6DC", "#003C67")
p <- ggplot2::ggplot(
  plot_data,
  ggplot2::aes(optimization, value, color = dataset, shape = dataset)
) +
  ggplot2::geom_hline(
    data = data.frame(
      panel = c(
        "Runtime effect: log2(reference / optimized)",
        "Incremental peak RSS reduction (%)"
      ),
      intercept = c(0, 0)
    ),
    ggplot2::aes(yintercept = intercept),
    color = "grey55", linewidth = 0.45, linetype = 2,
    inherit.aes = FALSE
  ) +
  ggplot2::geom_point(size = 3, stroke = 0.8) +
  ggplot2::facet_wrap(~panel, scales = "free_y", ncol = 1) +
  ggplot2::scale_color_manual(values = jco) +
  ggplot2::labs(x = NULL, y = NULL, color = "Dataset", shape = "Dataset") +
  ggplot2::theme_bw(base_size = 12) +
  ggplot2::theme(
    panel.grid.minor = ggplot2::element_blank(),
    panel.grid.major.x = ggplot2::element_blank(),
    strip.background = ggplot2::element_rect(fill = "#F2F2F2", color = "black"),
    strip.text = ggplot2::element_text(face = "bold"),
    axis.text.x = ggplot2::element_text(angle = 25, hjust = 1),
    legend.position = "bottom"
  )

ggplot2::ggsave(
  file.path(results_dir, "simpls_optimization_ablation.png"),
  p, width = 10.5, height = 8.2, dpi = 300
)
ggplot2::ggsave(
  file.path(results_dir, "simpls_optimization_ablation.pdf"),
  p, width = 10.5, height = 8.2
)
