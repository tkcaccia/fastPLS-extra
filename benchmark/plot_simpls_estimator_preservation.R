#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
get_arg <- function(name, default) {
  key <- paste0("--", name, "=")
  hit <- args[startsWith(args, key)]
  if (!length(hit)) return(default)
  sub(key, "", hit[[1L]], fixed = TRUE)
}

in_dir <- get_arg(
  "input",
  "benchmark_results/simpls_estimator_preservation_20260725"
)
out_dir <- get_arg("out", file.path(in_dir, "plots"))
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

if (!requireNamespace("ggplot2", quietly = TRUE)) {
  stop("ggplot2 is required.", call. = FALSE)
}

all_endpoints <- file.path(
  in_dir, "simpls_estimator_preservation_all_endpoints.csv"
)
if (file.exists(all_endpoints)) {
  results <- utils::read.csv(all_endpoints, stringsAsFactors = FALSE)
} else {
  result_files <- file.path(
    in_dir,
    c(
      "simpls_estimator_preservation_irlba.csv",
      "simpls_estimator_approximation_rsvd.csv"
    )
  )
  if (!all(file.exists(result_files))) {
    stop("Current SIMPLS validation endpoint files are missing.", call. = FALSE)
  }
  results <- do.call(rbind, lapply(
    result_files, utils::read.csv, stringsAsFactors = FALSE
  ))
}
results$solver_label <- factor(
  results$solver,
  levels = c("irlba", "rsvd"),
  labels = c("Fixed-control IRLBA", "Approximate rSVD")
)
results$dataset_label <- gsub("^syn_", "Synthetic: ", results$dataset)
results$dataset_label <- gsub("_", " ", results$dataset_label)
results$dataset_label <- gsub(" p lt n", " p < n", results$dataset_label, fixed = TRUE)
results$dataset_label <- gsub(" p gt n", " p > n", results$dataset_label, fixed = TRUE)
dataset_order <- unique(results$dataset_label)
results$dataset_label <- factor(results$dataset_label, levels = rev(dataset_order))
results$source <- factor(results$source, levels = c("synthetic", "real"))

floor_value <- 1e-16
results$prediction_error_plot <- pmax(
  results$prediction_relative_error,
  floor_value
)
results$angle_plot <- pmax(
  results$score_subspace_max_angle_degrees,
  floor_value
)

theme_publication <- ggplot2::theme_bw(base_size = 11) +
  ggplot2::theme(
    panel.grid.minor = ggplot2::element_blank(),
    legend.position = "bottom",
    strip.background = ggplot2::element_rect(fill = "#F2F4F7"),
    strip.text = ggplot2::element_text(face = "bold"),
    axis.text.y = ggplot2::element_text(size = 8),
    plot.title = ggplot2::element_text(face = "bold", size = 12),
    plot.margin = ggplot2::margin(8, 10, 8, 8)
  )

make_plot <- function(value, y_label, title, tolerance_value) {
  ggplot2::ggplot(
    results,
    ggplot2::aes(
      x = .data[[value]],
      y = dataset_label,
      colour = solver_label,
      shape = source
    )
  ) +
    ggplot2::geom_vline(
      xintercept = tolerance_value,
      linetype = "dashed",
      linewidth = 0.45,
      colour = "#555555"
    ) +
    ggplot2::geom_point(alpha = 0.72, size = 1.9, position = ggplot2::position_jitter(height = 0.12)) +
    ggplot2::scale_x_log10() +
    ggplot2::scale_colour_manual(values = c("#0072B2", "#D55E00")) +
    ggplot2::labs(
      x = y_label,
      y = NULL,
      colour = "Direction solver",
      shape = "Data source",
      title = title
    ) +
    theme_publication
}

prediction_plot <- make_plot(
  "prediction_error_plot",
  "Relative prediction error versus pls::simpls.fit (log scale)",
  "Prediction agreement",
  1e-4
)
angle_plot <- make_plot(
  "angle_plot",
  "Maximum score-subspace angle, degrees (log scale)",
  "Latent-subspace agreement",
  0.1
)

ggplot2::ggsave(
  file.path(out_dir, "simpls_prediction_agreement.png"),
  prediction_plot,
  width = 9,
  height = 5.8,
  dpi = 320
)
ggplot2::ggsave(
  file.path(out_dir, "simpls_prediction_agreement.pdf"),
  prediction_plot,
  width = 9,
  height = 5.8
)
ggplot2::ggsave(
  file.path(out_dir, "simpls_subspace_agreement.png"),
  angle_plot,
  width = 9,
  height = 5.8,
  dpi = 320
)
ggplot2::ggsave(
  file.path(out_dir, "simpls_subspace_agreement.pdf"),
  angle_plot,
  width = 9,
  height = 5.8
)

cat("Plots: ", normalizePath(out_dir, winslash = "/", mustWork = FALSE), "\n", sep = "")
