#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
input_dir <- if (length(args) >= 1L) args[[1L]] else file.path("benchmark_results", "kernel_sensitivity")
output_dir <- if (length(args) >= 2L) args[[2L]] else file.path(input_dir, "plots")
summary_path <- file.path(input_dir, "kernel_sensitivity_summary.csv")
if (!file.exists(summary_path)) stop("Missing kernel sensitivity summary: ", summary_path)
if (!requireNamespace("ggplot2", quietly = TRUE)) stop("ggplot2 is required")
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

d <- read.csv(summary_path, stringsAsFactors = FALSE, check.names = FALSE)
if (!nrow(d)) stop("Kernel sensitivity summary contains no successful rows")
d$kernel <- factor(d$kernel, levels = c("linear", "rbf", "poly"), labels = c("Linear", "RBF", "Polynomial"))
d$backend <- factor(d$backend, levels = c("cpu", "cuda", "metal"), labels = c("CPU", "CUDA", "Metal"))

make_long <- function(x) {
  performance_label <- if (identical(unique(x$task_type), "classification")) "Accuracy" else "RMSD (lower is better)"
  pieces <- list(
    data.frame(x, panel = performance_label, value = x$metric_median, lower = x$metric_q25, upper = x$metric_q75),
    data.frame(x, panel = "Total time, log10(s)", value = log10(pmax(x$total_time_median_sec, 1e-6)), lower = log10(pmax(x$total_time_q25_sec, 1e-6)), upper = log10(pmax(x$total_time_q75_sec, 1e-6))),
    data.frame(x, panel = "Peak host RSS (MB)", value = x$peak_host_rss_median_mb, lower = x$peak_host_rss_q25_mb, upper = x$peak_host_rss_q75_mb),
    data.frame(x, panel = "Peak GPU memory (MB)", value = x$peak_gpu_mem_median_mb, lower = x$peak_gpu_mem_q25_mb, upper = x$peak_gpu_mem_q75_mb)
  )
  out <- do.call(rbind, pieces)
  out$panel <- factor(out$panel, levels = c(performance_label, "Total time, log10(s)", "Peak host RSS (MB)", "Peak GPU memory (MB)"))
  out[is.finite(out$value), , drop = FALSE]
}

pretty_dataset <- function(x) {
  labels <- c(metref = "MetRef", ccle = "CCLE", prism = "PRISM", nmr = "NMR")
  unname(ifelse(x %in% names(labels), labels[x], x))
}

save_task_plot <- function(task_type, stem, title) {
  x <- d[d$task_type == task_type, , drop = FALSE]
  if (!nrow(x)) return(invisible(NULL))
  x$dataset <- factor(pretty_dataset(x$dataset), levels = unique(pretty_dataset(x$dataset)))
  long <- make_long(x)
  pd <- ggplot2::position_dodge(width = 0.38)
  p <- ggplot2::ggplot(long, ggplot2::aes(kernel, value, fill = backend, shape = backend, group = backend)) +
    ggplot2::geom_errorbar(ggplot2::aes(ymin = lower, ymax = upper), color = "black", width = 0.12, position = pd, linewidth = 0.55, na.rm = TRUE) +
    ggplot2::geom_point(color = "black", position = pd, size = 3.2, stroke = 0.85, na.rm = TRUE) +
    ggplot2::facet_grid(panel ~ dataset, scales = "free_y") +
    ggplot2::scale_fill_manual(values = c(CPU = "#56B4E9", CUDA = "#E69F00", Metal = "#009E73"), drop = TRUE) +
    ggplot2::scale_shape_manual(values = c(CPU = 21, CUDA = 24, Metal = 22), drop = TRUE) +
    ggplot2::labs(
      title = title,
      subtitle = "Kernel and component settings selected by five-fold training-only CV; points are held-out medians and bars are interquartile ranges",
      x = NULL, y = NULL, fill = "Backend", shape = "Backend"
    ) +
    ggplot2::theme_bw(base_size = 14) +
    ggplot2::theme(
      plot.title = ggplot2::element_text(face = "bold", size = 16),
      plot.subtitle = ggplot2::element_text(size = 11),
      strip.text = ggplot2::element_text(face = "bold", size = 12),
      axis.text.x = ggplot2::element_text(angle = 25, hjust = 1),
      panel.grid.minor = ggplot2::element_blank(),
      legend.position = "bottom",
      legend.box = "horizontal"
    )
  ggplot2::ggsave(file.path(output_dir, paste0(stem, ".png")), p, width = 11.8, height = 11.2, dpi = 320, bg = "white")
  ggplot2::ggsave(file.path(output_dir, paste0(stem, ".pdf")), p, width = 11.8, height = 11.2, device = grDevices::cairo_pdf)
  invisible(p)
}

save_task_plot("classification", "kernel_sensitivity_classification", "Kernel sensitivity: classification")
save_task_plot("regression", "kernel_sensitivity_regression", "Kernel sensitivity: multivariate regression")

writeLines(c(
  "Kernel sensitivity figures",
  paste0("Source: ", normalizePath(summary_path, winslash = "/", mustWork = TRUE)),
  "Within each figure, facets in the same metric row share a y-axis range.",
  "RBF and polynomial settings and the selected component counts are reported in kernel_sensitivity_selected.csv."
), file.path(output_dir, "plot_manifest.txt"))
