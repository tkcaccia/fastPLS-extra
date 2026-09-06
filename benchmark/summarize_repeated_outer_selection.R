#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
root <- if (length(args)) path.expand(args[[1L]]) else file.path(
  "benchmark_results", "release_0.99.39", "repeated_outer"
)
out_dir <- if (length(args) > 1L) path.expand(args[[2L]]) else dirname(root)
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

files <- list.files(
  root, pattern = "^repeated_outer_raw[.]csv$",
  recursive = TRUE, full.names = TRUE
)
if (!length(files)) stop("No repeated_outer_raw.csv files found under ", root)

bind_fill <- function(frames) {
  fields <- unique(unlist(lapply(frames, names), use.names = FALSE))
  frames <- lapply(frames, function(x) {
    for (field in setdiff(fields, names(x))) x[[field]] <- NA
    x[fields]
  })
  do.call(rbind, frames)
}

raw <- bind_fill(lapply(files, function(path) {
  x <- read.csv(path, stringsAsFactors = FALSE)
  x$source_file <- normalizePath(path, winslash = "/", mustWork = TRUE)
  x
}))
for (field in c("effective_grid_min", "effective_grid_max")) {
  if (!field %in% names(raw)) raw[[field]] <- NA_real_
}

# Replace earlier PLS-SVD classification boundary flags with the effective
# centered-response rank C - 1. The source rows are retained unchanged.
is_classification_plssvd <- raw$method == "plssvd" & raw$classifier != "regression"
effective_max <- pmax(1L, raw$q - 1L)
raw$effective_grid_max <- ifelse(
  is_classification_plssvd,
  effective_max,
  ifelse(is.na(raw$effective_grid_max), raw$grid_max, raw$effective_grid_max)
)
raw$effective_grid_min <- ifelse(
  is.na(raw$effective_grid_min), raw$grid_min, raw$effective_grid_min
)
raw$selected_lower_boundary <- raw$selected_ncomp == raw$effective_grid_min
raw$selected_upper_boundary <- raw$selected_ncomp == raw$effective_grid_max
raw$upper_grid_rank_constrained <- ifelse(
  is_classification_plssvd,
  TRUE,
  raw$upper_grid_rank_constrained
)

raw <- raw[order(
  raw$dataset, raw$method, raw$classifier, raw$outer_seed
), ]
raw <- raw[!duplicated(
  raw[c("dataset", "method", "classifier", "outer_seed")],
  fromLast = TRUE
), ]
raw <- raw[order(raw$dataset, raw$method, raw$classifier, raw$outer_index), ]
row.names(raw) <- NULL
write.csv(
  raw, file.path(out_dir, "repeated_outer_all_raw.csv"), row.names = FALSE
)

ok <- raw[raw$status == "ok", , drop = FALSE]
failed <- raw[raw$status != "ok", , drop = FALSE]
write.csv(
  failed, file.path(out_dir, "repeated_outer_failures.csv"), row.names = FALSE
)
if (!nrow(ok)) stop("All repeated outer runs failed.")

groups <- split(
  ok,
  interaction(ok$dataset, ok$method, ok$classifier, drop = TRUE)
)
summary <- do.call(rbind, lapply(groups, function(x) {
  values <- x$metric_value
  selected <- x$selected_ncomp
  data.frame(
    dataset = x$dataset[[1L]],
    method = x$method[[1L]],
    classifier = x$classifier[[1L]],
    backend = x$backend[[1L]],
    svd_method = x$svd_method[[1L]],
    n_outer_success = nrow(x),
    metric_name = x$metric_name[[1L]],
    metric_mean = mean(values),
    metric_sd = if (length(values) > 1L) stats::sd(values) else NA_real_,
    metric_median = stats::median(values),
    metric_q025 = unname(stats::quantile(values, 0.025)),
    metric_q25 = unname(stats::quantile(values, 0.25)),
    metric_q75 = unname(stats::quantile(values, 0.75)),
    metric_q975 = unname(stats::quantile(values, 0.975)),
    selected_ncomp_median = stats::median(selected),
    selected_ncomp_min = min(selected),
    selected_ncomp_max = max(selected),
    lower_boundary_frequency = mean(x$selected_lower_boundary, na.rm = TRUE),
    upper_boundary_frequency = mean(x$selected_upper_boundary, na.rm = TRUE),
    rank_constrained_grid = any(x$upper_grid_rank_constrained, na.rm = TRUE),
    total_time_median_sec = stats::median(x$total_time_sec, na.rm = TRUE),
    stringsAsFactors = FALSE
  )
}))
row.names(summary) <- NULL
summary <- summary[order(summary$dataset, summary$method, summary$classifier), ]
write.csv(
  summary,
  file.path(out_dir, "repeated_outer_predictive_dispersion_summary.csv"),
  row.names = FALSE
)

selection_frequency <- do.call(rbind, lapply(groups, function(x) {
  frequency <- as.data.frame(table(x$selected_ncomp), stringsAsFactors = FALSE)
  names(frequency) <- c("selected_ncomp", "count")
  frequency$selected_ncomp <- as.integer(as.character(frequency$selected_ncomp))
  frequency$frequency <- frequency$count / sum(frequency$count)
  frequency$dataset <- x$dataset[[1L]]
  frequency$method <- x$method[[1L]]
  frequency$classifier <- x$classifier[[1L]]
  frequency[c(
    "dataset", "method", "classifier", "selected_ncomp", "count", "frequency"
  )]
}))
row.names(selection_frequency) <- NULL
selection_frequency <- selection_frequency[order(
  selection_frequency$dataset, selection_frequency$method,
  selection_frequency$classifier, selection_frequency$selected_ncomp
), ]
write.csv(
  selection_frequency,
  file.path(out_dir, "repeated_outer_selection_frequency.csv"),
  row.names = FALSE
)

if (requireNamespace("ggplot2", quietly = TRUE)) {
  library(ggplot2)
  plot_data <- ok
  method_labels <- c(
    plssvd = "PLS-SVD", simpls = "SIMPLS",
    opls = "OPLS", kernelpls = "kernel PLS"
  )
  classifier_labels <- c(
    argmax = "argmax", lda = "LDA", regression = "regression"
  )
  plot_data$workflow <- paste(
    unname(method_labels[plot_data$method]),
    unname(classifier_labels[plot_data$classifier]),
    sep = " / "
  )
  workflow_levels <- unlist(lapply(
    c("plssvd", "simpls", "opls", "kernelpls"),
    function(method) paste(
      method_labels[[method]],
      classifier_labels[c("argmax", "lda", "regression")],
      sep = " / "
    )
  ), use.names = FALSE)
  plot_data$workflow <- factor(plot_data$workflow, levels = workflow_levels)
  plot_data$dataset_label <- factor(
    plot_data$dataset,
    levels = c("metref", "gtex_v8", "retina", "nmr"),
    labels = c("MetRef", "GTEx v8", "Retina", "NMR")
  )
  plot_data$display_metric <- ifelse(
    plot_data$metric_name == "accuracy",
    plot_data$metric_value,
    plot_data$RMSD
  )

  colors <- c(
    plssvd = "#1B4F72", simpls = "#D35400",
    opls = "#2E8B57", kernelpls = "#8E5A2B"
  )
  p_metric <- ggplot(
    plot_data,
    aes(x = workflow, y = display_metric, fill = method)
  ) +
    geom_boxplot(width = 0.65, outlier.shape = NA, color = "black") +
    geom_point(
      position = position_jitter(width = 0.12, height = 0),
      shape = 21, size = 1.8, color = "black", alpha = 0.8
    ) +
    facet_wrap(
      ~ dataset_label, scales = "free", ncol = 2,
      labeller = label_value
    ) +
    scale_fill_manual(values = colors) +
    labs(
      x = NULL, y = "Outer-test accuracy or RMSD",
      title = "Predictive dispersion across repeated outer partitions"
    ) +
    theme_bw(base_size = 10) +
    theme(
      axis.text.x = element_text(angle = 45, hjust = 1),
      legend.position = "none",
      strip.background = element_rect(fill = "#EAF2F8", color = "black")
    )
  ggsave(
    file.path(out_dir, "repeated_outer_predictive_dispersion.pdf"),
    p_metric, width = 10.5, height = 7.5
  )
  ggsave(
    file.path(out_dir, "repeated_outer_predictive_dispersion.png"),
    p_metric, width = 10.5, height = 7.5, dpi = 300
  )

  selection_frequency$dataset_label <- factor(
    selection_frequency$dataset,
    levels = c("metref", "gtex_v8", "retina", "nmr"),
    labels = c("MetRef", "GTEx v8", "Retina", "NMR")
  )
  selection_frequency$classifier_label <- factor(
    selection_frequency$classifier,
    levels = c("argmax", "lda", "regression"),
    labels = c("argmax", "LDA", "regression")
  )
  p_selection <- ggplot(
    selection_frequency,
    aes(x = selected_ncomp, y = frequency, fill = method, group = method)
  ) +
    geom_point(
      color = "black", shape = 21, size = 3.2,
      position = position_dodge(width = 1.4)
    ) +
    facet_grid(
      dataset_label ~ classifier_label, scales = "free_x", space = "free_x"
    ) +
    scale_fill_manual(
      values = colors,
      labels = c(
        plssvd = "PLS-SVD", simpls = "SIMPLS",
        opls = "OPLS", kernelpls = "kernel PLS"
      )
    ) +
    scale_y_continuous(
      limits = c(0, 1), labels = function(x) sprintf("%.0f%%", 100 * x)
    ) +
    labs(
      x = "Component count selected within the evaluated grid",
      y = "Selection frequency",
      title = "Training-only component-selection stability"
    ) +
    theme_bw(base_size = 10) +
    theme(
      legend.position = "bottom",
      strip.background = element_rect(fill = "#EAF2F8", color = "black")
    )
  ggsave(
    file.path(out_dir, "repeated_outer_selection_frequency.pdf"),
    p_selection, width = 10.5, height = 8
  )
  ggsave(
    file.path(out_dir, "repeated_outer_selection_frequency.png"),
    p_selection, width = 10.5, height = 8, dpi = 300
  )
}

cat("Wrote repeated outer-partition summary to ", normalizePath(out_dir), "\n", sep = "")
