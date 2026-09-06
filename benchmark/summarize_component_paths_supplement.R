#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 4L) {
  stop(
    "Usage: summarize_component_paths_supplement.R ",
    "CORE_RAW RETINA_TABULA_RAW SELECTION_STATUS OUTPUT_DIR"
  )
}

core_file <- normalizePath(args[[1L]], mustWork = TRUE)
extension_file <- normalizePath(args[[2L]], mustWork = TRUE)
selection_file <- normalizePath(args[[3L]], mustWork = TRUE)
output_dir <- normalizePath(args[[4L]], mustWork = FALSE)
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
plot_dir <- file.path(output_dir, "component_path_plots")
dir.create(plot_dir, recursive = TRUE, showWarnings = FALSE)

needed <- c("data.table", "ggplot2", "cowplot", "scales")
missing <- needed[!vapply(needed, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing)) stop("Missing packages: ", paste(missing, collapse = ", "))

suppressPackageStartupMessages({
  library(data.table)
  library(ggplot2)
  library(cowplot)
})

current_datasets <- c(
  "metref", "ccle", "tcga_brca", "tcga_hnsc_methylation",
  "gtex_v8", "tcga_pan_cancer", "retina", "tabula", "cifar100",
  "cbmc_citeseq", "prism", "nmr"
)
families <- c("plssvd", "simpls", "opls", "kernelpls")
family_labels <- c(
  plssvd = "PLS-SVD",
  simpls = "SIMPLS",
  opls = "OPLS",
  kernelpls = "kernel PLS"
)
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
  prism = "PRISM",
  nmr = "NMR"
)

legacy_variants <- c(
  cpp_plssvd_cpu_rsvd = "CPU",
  gpu_plssvd_fp64 = "CUDA",
  cpp_simpls_cpu_rsvd = "CPU",
  gpu_simpls_fp64 = "CUDA",
  cpp_opls_cpu_rsvd = "CPU",
  gpu_opls_fp64 = "CUDA",
  cpp_kernelpls_cpu_rsvd = "CPU",
  gpu_kernelpls_fp64 = "CUDA"
)
extension_variants <- c(
  cpp_plssvd_cpu_rsvd = "CPU",
  gpu_plssvd_rsvd = "CUDA",
  cpp_simpls_cpu_rsvd = "CPU",
  gpu_simpls_rsvd = "CUDA",
  cpp_opls_cpu_rsvd = "CPU",
  gpu_opls_rsvd = "CUDA",
  cpp_kernelpls_cpu_rsvd = "CPU",
  gpu_kernelpls_rsvd = "CUDA"
)
all_variants <- c(
  legacy_variants,
  extension_variants[!names(extension_variants) %in% names(legacy_variants)]
)

standardize <- function(data, variant_map, datasets) {
  data <- copy(data)
  data <- data[
    dataset %in% datasets &
      variant_name %in% names(variant_map) &
      classifier == "argmax" &
      status %in% c("ok", "capped")
  ]
  data[, backend_label := unname(variant_map[variant_name])]
  data[, .(
    dataset = as.character(dataset),
    task_type = as.character(task_type),
    family = as.character(method_panel),
    backend = backend_label,
    requested_ncomp = as.integer(requested_ncomp),
    effective_ncomp = as.integer(effective_ncomp),
    replicate = as.integer(replicate),
    total_time_ms = as.numeric(total_time_ms),
    performance = as.numeric(metric_value),
    performance_name = as.character(metric_name),
    peak_host_rss_mb = as.numeric(peak_host_rss_mb),
    peak_gpu_mem_mb = as.numeric(peak_gpu_mem_mb),
    n_train = as.integer(n_train),
    n_test = as.integer(n_test),
    p = as.integer(p),
    q = as.integer(n_classes),
    status = as.character(status)
  )]
}

core <- standardize(
  fread(core_file),
  all_variants,
  setdiff(current_datasets, c("retina", "tabula"))
)
extension <- standardize(
  fread(extension_file),
  all_variants,
  c("retina", "tabula")
)
raw <- rbindlist(list(core, extension), use.names = TRUE, fill = TRUE)
raw <- raw[family %in% families]

median_iqr <- function(x) {
  x <- x[is.finite(x)]
  if (!length(x)) return(list(median = NA_real_, q1 = NA_real_, q3 = NA_real_))
  list(
    median = stats::median(x),
    q1 = unname(stats::quantile(x, 0.25)),
    q3 = unname(stats::quantile(x, 0.75))
  )
}

path_summary <- raw[, {
  tt <- median_iqr(total_time_ms)
  pp <- median_iqr(performance)
  hh <- median_iqr(peak_host_rss_mb)
  gg <- median_iqr(peak_gpu_mem_mb)
  list(
    effective_ncomp = as.integer(stats::median(effective_ncomp, na.rm = TRUE)),
    n_replicates = uniqueN(replicate),
    performance_name = performance_name[[1L]],
    total_time_ms = tt$median,
    total_time_q1_ms = tt$q1,
    total_time_q3_ms = tt$q3,
    performance = pp$median,
    performance_q1 = pp$q1,
    performance_q3 = pp$q3,
    peak_host_rss_mb = hh$median,
    peak_host_rss_q1_mb = hh$q1,
    peak_host_rss_q3_mb = hh$q3,
    peak_gpu_mem_mb = gg$median,
    peak_gpu_mem_q1_mb = gg$q1,
    peak_gpu_mem_q3_mb = gg$q3,
    n_train = n_train[[1L]],
    n_test = n_test[[1L]],
    p = p[[1L]],
    q = q[[1L]]
  )
}, by = .(dataset, task_type, family, backend, requested_ncomp)]

selection_wide <- fread(selection_file)
selection_long <- melt(
  selection_wide,
  id.vars = c("dataset", "evaluated_grid"),
  measure.vars = families,
  variable.name = "family",
  value.name = "selection_detail"
)
selection_long[, selected_ncomp := suppressWarnings(
  as.integer(sub(".*k=([0-9]+).*", "\\1", selection_detail))
)]
selection_long[!grepl("k=[0-9]+", selection_detail), selected_ncomp := NA_integer_]
selection_long[, selection_status := sub("^k=[0-9]+;[[:space:]]*", "", selection_detail)]
selection_long[is.na(selected_ncomp), selection_status := selection_detail]
selection_long[, selection_source := fifelse(
  dataset == "nmr",
  "five repeated training-only splits; one-SE rule where applicable",
  "five-fold training-only cross-validation"
)]
selection_long[, dataset_label := unname(dataset_labels[dataset])]
selection_long[, family_label := unname(family_labels[family])]
selection_long[, dataset_order := match(dataset, current_datasets)]
selection_long[, family_order := match(family, families)]
setorder(selection_long, dataset_order, family_order)

fwrite(raw, file.path(output_dir, "component_path_raw_matched.csv"))
fwrite(path_summary, file.path(output_dir, "component_path_summary_matched.csv"))
fwrite(selection_long, file.path(output_dir, "component_selection_by_family.csv"))

safe_spearman <- function(x, y) {
  keep <- is.finite(x) & is.finite(y)
  if (sum(keep) < 3L || uniqueN(x[keep]) < 3L || uniqueN(y[keep]) < 2L) {
    return(NA_real_)
  }
  suppressWarnings(stats::cor(x[keep], y[keep], method = "spearman"))
}

correlations <- path_summary[, .(
  n_path_points = uniqueN(requested_ncomp),
  performance_name = performance_name[[1L]],
  rho_performance = safe_spearman(requested_ncomp, performance),
  rho_total_time = safe_spearman(requested_ncomp, total_time_ms),
  rho_host_rss = safe_spearman(requested_ncomp, peak_host_rss_mb),
  rho_gpu_memory = safe_spearman(requested_ncomp, peak_gpu_mem_mb)
), by = .(dataset, family, backend)]
correlation_grid <- CJ(
  dataset = current_datasets,
  family = families,
  backend = c("CPU", "CUDA"),
  unique = TRUE
)
correlations <- merge(
  correlation_grid,
  correlations,
  by = c("dataset", "family", "backend"),
  all.x = TRUE
)
correlations <- merge(
  correlations,
  selection_long[, .(
    dataset, family, selected_ncomp, selection_status, evaluated_grid
  )],
  by = c("dataset", "family"),
  all.x = TRUE
)
correlations[, dataset_label := unname(dataset_labels[dataset])]
correlations[, family_label := unname(family_labels[family])]
correlations[, interpretation := fifelse(
  is.na(rho_total_time),
  "insufficient path",
  fifelse(
    abs(rho_total_time) >= 0.7,
    "strong monotonic time association",
    "weak/moderate monotonic time association"
  )
)]
correlations[, dataset_order := match(dataset, current_datasets)]
correlations[, family_order := match(family, families)]
correlations[, backend_order := match(backend, c("CPU", "CUDA"))]
setorder(correlations, family_order, dataset_order, backend_order)
fwrite(correlations, file.path(output_dir, "component_metric_spearman_correlations.csv"))

plot_data <- melt(
  path_summary,
  id.vars = c(
    "dataset", "task_type", "family", "backend", "requested_ncomp",
    "performance_name", "n_train", "n_test", "p", "q"
  ),
  measure.vars = c(
    "total_time_ms", "performance", "peak_host_rss_mb", "peak_gpu_mem_mb"
  ),
  variable.name = "measure",
  value.name = "value"
)
plot_data[, measure := factor(
  measure,
  levels = c(
    "total_time_ms", "performance", "peak_host_rss_mb", "peak_gpu_mem_mb"
  )
)]
plot_data[, family := factor(family, levels = families, labels = family_labels)]
plot_data[, backend := factor(backend, levels = c("CPU", "CUDA"))]

backend_colors <- c(CPU = "#0072B2", CUDA = "#D55E00")
backend_lines <- c(CPU = "solid", CUDA = "longdash")
backend_shapes <- c(CPU = 21, CUDA = 24)

for (dataset_id in current_datasets) {
  data_ds <- plot_data[dataset == dataset_id]
  if (!nrow(data_ds)) next
  selected_ds <- copy(selection_long[dataset == dataset_id])
  selected_ds[, family := factor(family, levels = families, labels = family_labels)]

  perf_name <- tolower(na.omit(data_ds$performance_name)[1L])
  perf_label <- switch(
    perf_name,
    accuracy = "Accuracy",
    q2 = expression(Q^2),
    rmsd = "RMSD",
    "Predictive metric"
  )
  x_breaks <- sort(unique(data_ds$requested_ncomp))
  x_limits <- range(x_breaks)

  row_plot <- function(measure_name, y_label, log_y = FALSE, show_x = FALSE) {
    dd <- data_ds[measure == measure_name & is.finite(value)]
    p <- ggplot(
      dd,
      aes(
        requested_ncomp, value,
        group = backend,
        color = backend,
        fill = backend,
        linetype = backend,
        shape = backend
      )
    ) +
      geom_vline(
        data = selected_ds[is.finite(selected_ncomp)],
        aes(xintercept = selected_ncomp),
        inherit.aes = FALSE,
        color = "#333333",
        linetype = "dotted",
        linewidth = 0.45
      ) +
      geom_line(linewidth = 0.65, na.rm = TRUE) +
      geom_point(size = 2.1, stroke = 0.65, color = "black", na.rm = TRUE) +
      facet_grid(. ~ family, drop = FALSE) +
      scale_x_continuous(
        breaks = x_breaks,
        limits = x_limits,
        expand = expansion(mult = 0.025)
      ) +
      scale_color_manual(values = backend_colors, drop = FALSE) +
      scale_fill_manual(values = backend_colors, drop = FALSE) +
      scale_linetype_manual(values = backend_lines, drop = FALSE) +
      scale_shape_manual(values = backend_shapes, drop = FALSE) +
      labs(
        x = if (show_x) "Requested components" else NULL,
        y = y_label
      ) +
      theme_bw(base_size = 9.5) +
      theme(
        strip.text = element_text(face = "bold", size = 9.5),
        axis.text = element_text(size = 7.7),
        axis.text.x = if (show_x) {
          element_text(angle = 45, hjust = 1)
        } else {
          element_blank()
        },
        axis.ticks.x = if (show_x) element_line() else element_blank(),
        axis.title = element_text(size = 9.5),
        panel.grid.minor = element_blank(),
        legend.position = "none"
      )
    if (log_y) {
      p + scale_y_log10(labels = scales::label_number())
    } else {
      p + scale_y_continuous(labels = scales::label_number())
    }
  }

  rows <- list(
    row_plot("total_time_ms", "Total time (ms, log)", log_y = TRUE),
    row_plot("performance", perf_label),
    row_plot("peak_host_rss_mb", "Peak host RSS (MB)"),
    row_plot("peak_gpu_mem_mb", "Peak GPU memory (MB)", show_x = TRUE)
  )
  title <- sprintf(
    "%s | train=%s, test=%s, p=%s, q/classes=%s",
    dataset_labels[[dataset_id]],
    data_ds$n_train[[1L]], data_ds$n_test[[1L]],
    data_ds$p[[1L]], data_ds$q[[1L]]
  )
  title_plot <- ggdraw() +
    draw_label(title, fontface = "bold", size = 12, x = 0.5, hjust = 0.5)
  legend <- get_legend(
    row_plot("total_time_ms", "Total time (ms)", show_x = TRUE) +
      theme(
        legend.position = "bottom",
        legend.title = element_blank(),
        legend.text = element_text(size = 9),
        legend.box = "horizontal"
      ) +
      guides(
        color = guide_legend(
          nrow = 1,
          override.aes = list(shape = backend_shapes, fill = backend_colors)
        ),
        fill = "none",
        shape = "none",
        linetype = "none"
      )
  )
  caption <- ggdraw() +
    draw_label(
      "Dotted vertical lines mark training-selected component counts; curves use the fixed outer test set.",
      size = 8.5, x = 0.5, hjust = 0.5
    )
  combined <- plot_grid(
    title_plot,
    plot_grid(plotlist = rows, ncol = 1, align = "v"),
    legend,
    caption,
    ncol = 1,
    rel_heights = c(0.055, 1, 0.055, 0.045)
  )
  ggsave(
    file.path(plot_dir, paste0(dataset_id, "_component_paths.png")),
    combined,
    width = 11.2,
    height = 8.0,
    dpi = 220,
    bg = "white",
    limitsize = FALSE
  )
  ggsave(
    file.path(plot_dir, paste0(dataset_id, "_component_paths.pdf")),
    combined,
    width = 11.2,
    height = 8.0,
    bg = "white",
    limitsize = FALSE
  )
}

writeLines(
  c(
    "Component-path supplementary analysis",
    paste("Core source:", core_file),
    paste("Retina/Tabula extension:", extension_file),
    paste("Training-only selection source:", selection_file),
    "Correlations: Spearman rho across successful component-grid points.",
    "Interpretation: descriptive only; held-out curves were not used to select components.",
    "Precision/backend scope: float64 CPU rSVD and CUDA rSVD, argmax/regression prediction.",
    "Time is total fitting plus prediction; memory is absolute process peak."
  ),
  file.path(output_dir, "component_path_analysis_provenance.txt")
)

cat("Wrote component-path analysis to", output_dir, "\n")
