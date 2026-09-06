args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 3L) {
  stop(
    "Usage: plot_main_selected_computational_performance.R ",
    "COMPONENT_PATH_SUMMARY COMPONENT_SELECTION OUTPUT_DIR"
  )
}

summary_file <- normalizePath(args[[1L]], mustWork = TRUE)
selection_file <- normalizePath(args[[2L]], mustWork = TRUE)
output_dir <- normalizePath(args[[3L]], mustWork = FALSE)
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

needed <- c("data.table", "ggplot2", "cowplot", "scales")
missing <- needed[!vapply(needed, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing)) stop("Missing packages: ", paste(missing, collapse = ", "))

suppressPackageStartupMessages({
  library(data.table)
  library(ggplot2)
  library(cowplot)
})

dataset_order <- c(
  "metref", "ccle", "tcga_brca", "tcga_hnsc_methylation",
  "gtex_v8", "tcga_pan_cancer", "retina", "tabula",
  "cifar100", "cbmc_citeseq", "prism"
)
dataset_ids <- dataset_order
dataset_labels <- c(
  metref = "MetRef",
  ccle = "CCLE",
  tcga_brca = "TCGA-BRCA",
  tcga_hnsc_methylation = "TCGA-HNSC methylation",
  gtex_v8 = "GTEx v8",
  tcga_pan_cancer = "TCGA Pan-Cancer",
  retina = "Retina",
  tabula = "Tabula Muris",
  cifar100 = "CIFAR-100",
  cbmc_citeseq = "CBMC CITE-seq",
  prism = "PRISM"
)
family_order <- c("plssvd", "simpls", "opls", "kernelpls")
family_labels <- c(
  plssvd = "PLS-SVD",
  simpls = "SIMPLS",
  opls = "OPLS",
  kernelpls = "kernel PLS"
)
family_colors <- c(
  "PLS-SVD" = "#0072B2",
  "SIMPLS" = "#D55E00",
  "OPLS" = "#009E73",
  "kernel PLS" = "#CC79A7"
)
backend_shapes <- c("CPU" = 21, "CUDA" = 24)

paths <- fread(summary_file)
selection <- fread(selection_file)[
  dataset %chin% dataset_ids,
  .(dataset, family, selected_ncomp, selection_status)
]
selected <- merge(
  paths[dataset %in% dataset_order],
  selection,
  by = c("dataset", "family"),
  all = FALSE
)
selected <- selected[requested_ncomp == selected_ncomp]

expected <- CJ(
  dataset = dataset_order,
  family = family_order,
  backend = c("CPU", "CUDA"),
  unique = TRUE
)
missing_rows <- fsetdiff(
  expected,
  unique(selected[, .(dataset, family, backend)])
)
if (nrow(missing_rows)) {
  stop(
    "Missing selected-point rows:\n",
    paste(capture.output(print(missing_rows)), collapse = "\n")
  )
}

selected[, dataset_label := factor(
  unname(dataset_labels[dataset]),
  levels = rev(unname(dataset_labels[dataset_order]))
)]
selected[, family_label := factor(
  unname(family_labels[family]),
  levels = unname(family_labels[family_order])
)]
selected[, backend := factor(backend, levels = c("CPU", "CUDA"))]
selected[, total_time_s := total_time_ms / 1000]
selected[, total_time_q1_s := total_time_q1_ms / 1000]
selected[, total_time_q3_s := total_time_q3_ms / 1000]

fwrite(
  selected[
    order(match(dataset, dataset_order), match(family, family_order), backend)
  ],
  file.path(output_dir, "main_selected_computational_performance.csv")
)

dodge <- position_dodge(width = 0.68)
base_theme <- theme_bw(base_size = 10.5) +
  theme(
    panel.grid.minor = element_blank(),
    panel.grid.major.y = element_line(color = "#E6E6E6", linewidth = 0.35),
    panel.grid.major.x = element_line(color = "#EFEFEF", linewidth = 0.3),
    axis.title = element_text(size = 10.5),
    axis.text = element_text(size = 8.5),
    plot.title = element_text(face = "bold", size = 11, hjust = 0),
    legend.position = "none",
    plot.margin = margin(6, 5, 4, 5)
  )

metric_panel <- function(
    data,
    value,
    lower,
    upper,
    title,
    x_label,
    show_y = FALSE) {
  ggplot(
    data,
    aes(
      y = dataset_label,
      x = .data[[value]],
      group = interaction(family_label, backend),
      fill = family_label,
      shape = backend
    )
  ) +
    geom_errorbar(
      aes(xmin = .data[[lower]], xmax = .data[[upper]]),
      orientation = "y",
      position = dodge,
      width = 0.24,
      linewidth = 0.45,
      color = "#555555",
      na.rm = TRUE
    ) +
    geom_point(
      position = dodge,
      size = 2.8,
      stroke = 0.65,
      color = "black",
      na.rm = TRUE
    ) +
    scale_x_log10(labels = scales::label_number()) +
    scale_fill_manual(values = family_colors, drop = FALSE) +
    scale_shape_manual(values = backend_shapes, drop = FALSE) +
    labs(
      x = x_label,
      y = if (show_y) "Dataset" else NULL,
      title = title
    ) +
    base_theme +
    theme(
      axis.text.y = if (show_y) element_text() else element_blank(),
      axis.ticks.y = if (show_y) element_line() else element_blank()
    )
}

time_plot <- metric_panel(
  selected,
  "total_time_s",
  "total_time_q1_s",
  "total_time_q3_s",
  "A  Total time",
  "Fit + prediction (s, log scale)",
  show_y = TRUE
)
host_plot <- metric_panel(
  selected,
  "peak_host_rss_mb",
  "peak_host_rss_q1_mb",
  "peak_host_rss_q3_mb",
  "B  Host memory",
  "Peak process RSS\n(MB, log scale)",
  show_y = TRUE
)
gpu_data <- selected[backend == "CUDA" & peak_gpu_mem_mb > 0]
gpu_plot <- metric_panel(
  gpu_data,
  "peak_gpu_mem_mb",
  "peak_gpu_mem_q1_mb",
  "peak_gpu_mem_q3_mb",
  "C  GPU memory",
  "Peak process GPU memory\n(MB, log scale)"
)

legend_plot <- ggplot(
  selected,
  aes(
    x = total_time_s,
    y = dataset_label,
    fill = family_label,
    shape = backend
  )
) +
  geom_point(size = 3, stroke = 0.65, color = "black") +
  scale_fill_manual(values = family_colors, drop = FALSE) +
  scale_shape_manual(values = backend_shapes, drop = FALSE) +
  guides(
    fill = guide_legend(
      title = "PLS family",
      nrow = 1,
      order = 1,
      override.aes = list(shape = 21)
    ),
    shape = guide_legend(title = "Backend", nrow = 1, order = 2)
  ) +
  theme_void(base_size = 10) +
  theme(
    legend.position = "bottom",
    legend.box = "horizontal",
    legend.title = element_text(face = "bold"),
    legend.text = element_text(size = 9.5)
  )
legend <- get_legend(legend_plot)

memory_panels <- plot_grid(
  host_plot,
  gpu_plot,
  nrow = 1,
  align = "h",
  axis = "tb",
  rel_widths = c(1.22, 1)
)
panels <- plot_grid(
  time_plot,
  memory_panels,
  ncol = 1,
  align = "v",
  rel_heights = c(1, 1)
)
title <- ggdraw() + draw_label(
  "Computational performance at the training-selected component count",
  x = 0.5,
  hjust = 0.5,
  fontface = "bold",
  size = 13
)
caption <- ggdraw() + draw_label(
  "Points are replicate medians; horizontal bars show the interquartile range.",
  x = 0.5,
  hjust = 0.5,
  size = 9
)
figure <- plot_grid(
  title,
  panels,
  legend,
  caption,
  ncol = 1,
  rel_heights = c(0.055, 1, 0.085, 0.04)
)

ggsave(
  file.path(output_dir, "main_selected_computational_performance.png"),
  figure,
  width = 8,
  height = 9.2,
  dpi = 300,
  bg = "white",
  limitsize = FALSE
)
ggsave(
  file.path(output_dir, "main_selected_computational_performance.pdf"),
  figure,
  width = 8,
  height = 9.2,
  bg = "white",
  limitsize = FALSE
)

cat("Wrote main selected-point computational figure to", output_dir, "\n")
