#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
root <- normalizePath(if (length(args) >= 1L) args[[1L]] else ".", mustWork = TRUE)
out_dir <- if (length(args) >= 2L) {
  args[[2L]]
} else {
  file.path(root, "benchmark_results", "simpls_vs_plssvd_shapes_20260726")
}
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

metal_file <- file.path(
  root, "benchmark_results", "metal_validation_20260726", "summary",
  "metal_validation_summary.csv"
)
metal_raw_file <- file.path(
  root, "benchmark_results", "metal_validation_20260726", "summary",
  "metal_validation_all_raw.csv"
)
cuda_file <- file.path(
  root, "benchmark_results", "simpls_vs_plssvd_shapes_20260726_cuda",
  "simpls_vs_plssvd_shapes_summary.csv"
)
stopifnot(
  file.exists(metal_file), file.exists(metal_raw_file), file.exists(cuda_file)
)

metal <- read.csv(metal_file, check.names = FALSE)
metal <- metal[
  metal$experiment == "synthetic_scaling" &
    metal$precision == "float64" &
    metal$method %in% c("plssvd", "simpls") &
    metal$backend_requested %in% c("cpu", "metal"),
  ,
  drop = FALSE
]
metal_raw <- read.csv(metal_raw_file, check.names = FALSE)
metal_raw <- metal_raw[
  metal_raw$experiment == "synthetic_scaling" &
    metal_raw$precision == "float64" &
    metal_raw$method %in% c("plssvd", "simpls") &
    metal_raw$backend_requested %in% c("cpu", "metal") &
    metal_raw$status == "success",
  ,
  drop = FALSE
]
metal_iqr <- aggregate(
  total_sec ~ dataset + method + backend_requested,
  data = metal_raw,
  FUN = IQR
)
names(metal_iqr)[names(metal_iqr) == "total_sec"] <- "iqr_total_sec"
metal <- merge(
  metal, metal_iqr,
  by = c("dataset", "method", "backend_requested"),
  all.x = TRUE,
  sort = FALSE
)
metal <- data.frame(
  platform = "Apple M3",
  backend = toupper(metal$backend_requested),
  dataset = metal$dataset,
  method = metal$method,
  n_train = metal$n_train,
  n_test = metal$n_test,
  p = metal$p,
  q = metal$q,
  ncomp = metal$ncomp,
  oversample = metal$oversample,
  power = metal$power,
  seeds = "101/102/103",
  median_total_sec = metal$median_total_sec,
  iqr_total_sec = metal$iqr_total_sec,
  median_rmsd = ifelse(metal$task_type == "regression", metal$median_metric, NA_real_),
  median_q2 = NA_real_,
  completed_runs = metal$successes,
  stringsAsFactors = FALSE
)

cuda <- read.csv(cuda_file, check.names = FALSE)
cuda <- data.frame(
  platform = "Chiamaka Linux",
  backend = toupper(cuda$backend),
  dataset = cuda$dataset,
  method = cuda$method,
  n_train = cuda$n_train,
  n_test = cuda$n_test,
  p = cuda$p,
  q = cuda$q,
  ncomp = cuda$ncomp,
  oversample = cuda$oversample,
  power = cuda$power,
  seeds = cuda$seeds,
  median_total_sec = cuda$median_total_sec,
  iqr_total_sec = cuda$iqr_total_sec,
  median_rmsd = cuda$median_rmsd,
  median_q2 = cuda$median_q2,
  completed_runs = cuda$completed_runs,
  stringsAsFactors = FALSE
)

combined <- rbind(metal, cuda)
combined$family <- ifelse(combined$method == "plssvd", "PLS-SVD", "SIMPLS")
combined$shape <- sub("^synthetic_", "", combined$dataset)

keys <- c(
  "platform", "backend", "dataset", "shape", "n_train", "n_test", "p", "q",
  "ncomp", "oversample", "power", "seeds"
)
plssvd <- combined[combined$method == "plssvd", , drop = FALSE]
simpls <- combined[combined$method == "simpls", , drop = FALSE]
paired <- merge(
  plssvd, simpls, by = keys, suffixes = c("_plssvd", "_simpls"), all = TRUE
)
paired$simpls_over_plssvd_time <-
  paired$median_total_sec_simpls / paired$median_total_sec_plssvd
paired$log2_time_ratio <- log2(paired$simpls_over_plssvd_time)
paired$runtime_winner <- ifelse(
  paired$simpls_over_plssvd_time < 0.95, "SIMPLS",
  ifelse(paired$simpls_over_plssvd_time > 1.05, "PLS-SVD", "Near parity")
)

shape_order <- c(
  "wide", "tall_thin", "high_response", "balanced", "high_components"
)
paired <- paired[
  order(
    match(paired$platform, c("Chiamaka Linux", "Apple M3")),
    match(paired$backend, c("CPU", "CUDA", "METAL")),
    match(paired$shape, shape_order)
  ),
  ,
  drop = FALSE
]

write.csv(
  combined,
  file.path(out_dir, "simpls_vs_plssvd_shapes_all_methods.csv"),
  row.names = FALSE
)
write.csv(
  paired,
  file.path(out_dir, "simpls_vs_plssvd_shapes_paired.csv"),
  row.names = FALSE
)

if (requireNamespace("ggplot2", quietly = TRUE)) {
  plot_data <- paired
  plot_data$shape <- factor(plot_data$shape, levels = shape_order)
  plot_data$execution <- ifelse(
    plot_data$platform == "Chiamaka Linux" & plot_data$backend == "CPU",
    "Intel i7-13700 CPU",
    ifelse(
      plot_data$platform == "Chiamaka Linux" & plot_data$backend == "CUDA",
      "RTX 5060 Ti CUDA",
      ifelse(
        plot_data$platform == "Apple M3" & plot_data$backend == "CPU",
        "Apple M3 CPU",
        "Apple M3 Metal"
      )
    )
  )
  plot_data$execution <- factor(
    plot_data$execution,
    levels = c(
      "Intel i7-13700 CPU", "RTX 5060 Ti CUDA",
      "Apple M3 CPU", "Apple M3 Metal"
    )
  )
  labels <- c(
    wide = "Wide\n400 x 2,000 x 20\nA=10",
    tall_thin = "Tall-thin\n5,000 x 50 x 20\nA=10",
    high_response = "High response\n1,000 x 300 x 500\nA=50",
    balanced = "Balanced\n5,000 x 500 x 50\nA=50",
    high_components = "High components\n3,000 x 768 x 200\nA=100"
  )
  palette <- c(
    "Intel i7-13700 CPU" = "#0072B2",
    "RTX 5060 Ti CUDA" = "#D55E00",
    "Apple M3 CPU" = "#009E73",
    "Apple M3 Metal" = "#CC79A7"
  )
  p <- ggplot2::ggplot(
    plot_data,
    ggplot2::aes(shape, log2_time_ratio, color = execution, group = execution)
  ) +
    ggplot2::geom_hline(yintercept = 0, color = "grey35", linewidth = 0.45) +
    ggplot2::geom_hline(
      yintercept = log2(c(0.95, 1.05)), color = "grey70",
      linewidth = 0.35, linetype = "dashed"
    ) +
    ggplot2::geom_line(linewidth = 0.7) +
    ggplot2::geom_point(size = 2.8, stroke = 0.7) +
    ggplot2::scale_x_discrete(labels = labels) +
    ggplot2::scale_color_manual(values = palette, drop = FALSE) +
    ggplot2::scale_y_continuous(
      breaks = log2(c(0.25, 0.5, 1, 2, 4)),
      labels = c("0.25", "0.5", "1", "2", "4")
    ) +
    ggplot2::labs(
      x = NULL,
      y = "SIMPLS / PLS-SVD total time",
      color = NULL
    ) +
    ggplot2::theme_classic(base_size = 10) +
    ggplot2::guides(
      color = ggplot2::guide_legend(nrow = 2, byrow = TRUE)
    ) +
    ggplot2::theme(
      legend.position = "bottom",
      legend.text = ggplot2::element_text(size = 8.5),
      legend.key.width = grid::unit(1.1, "lines"),
      axis.text.x = ggplot2::element_text(size = 8.5),
      plot.margin = ggplot2::margin(8, 8, 4, 8)
    )
  ggplot2::ggsave(
    file.path(out_dir, "simpls_vs_plssvd_shapes_runtime_ratio.png"),
    p, width = 7.2, height = 4.5, dpi = 320, bg = "white"
  )
  ggplot2::ggsave(
    file.path(out_dir, "simpls_vs_plssvd_shapes_runtime_ratio.pdf"),
    p, width = 7.2, height = 4.5, device = cairo_pdf
  )
}

writeLines(
  c(
    "Matched PLS-SVD versus SIMPLS shape benchmark",
    "",
    "Only the PLS family changes within each paired contrast.",
    "Fixed controls: generated X/Y, split, component count, float64 precision,",
    "centering, rSVD oversampling=32, power=5, seed sequence, and public",
    "fit-plus-predict path. CPU comparisons are interpreted within machine;",
    "absolute CPU times are not compared across Apple M3 and Chiamaka Linux.",
    "",
    "A ratio below 1 favors SIMPLS; above 1 favors PLS-SVD."
  ),
  file.path(out_dir, "README.txt")
)
