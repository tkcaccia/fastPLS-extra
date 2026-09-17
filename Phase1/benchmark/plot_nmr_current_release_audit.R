#!/usr/bin/env Rscript

# Create current-release fixed-component and training-selected NMR figures.

options(stringsAsFactors = FALSE)
required <- c("ggplot2", "patchwork", "scales")
missing <- required[!vapply(required, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing)) stop("Missing packages: ", paste(missing, collapse = ", "))

parse_args <- function(x = commandArgs(trailingOnly = TRUE)) {
  out <- list()
  for (item in x) {
    if (!startsWith(item, "--")) next
    fields <- strsplit(substring(item, 3L), "=", fixed = TRUE)[[1L]]
    out[[gsub("-", "_", fields[[1L]])]] <-
      if (length(fields) > 1L) paste(fields[-1L], collapse = "=") else "TRUE"
  }
  out
}
args <- parse_args()
arg <- function(name, default = NULL) {
  value <- args[[name]]
  if (is.null(value) || !nzchar(value)) default else value
}

root <- normalizePath(arg("repo", getwd()), mustWork = TRUE)
input_dir <- normalizePath(arg(
  "input_dir",
  file.path(root, "publication_results", "0.99.39", "current_release", "nmr")
), mustWork = TRUE)
plssvd_selection_csv <- arg(
  "plssvd_selection_csv",
  file.path(input_dir, "selection_plssvd", "nmr_component_selection_raw.csv")
)
simpls_selection_csv <- arg(
  "simpls_selection_csv",
  file.path(input_dir, "selection_simpls", "nmr_component_selection_raw.csv")
)
out_dir <- arg("output_dir", file.path(input_dir, "figures"))
deposited_summary_csv <- arg(
  "deposited_summary",
  file.path(input_dir, "deposited")
)
deposited_prediction_rds <- arg(
  "deposited_prediction",
  file.path(
    input_dir,
    "deposited",
    "deposited_plssvd_cpu_irlba_k165_rep1_prediction.rds"
  )
)
selected_plssvd <- as.integer(arg("plssvd_ncomp", "5"))
selected_simpls <- as.integer(arg("simpls_ncomp", "50"))
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

read_result <- function(path) utils::read.csv(path, check.names = FALSE)
read_peak <- function(path) {
  if (!file.exists(path)) return(NA_real_)
  lines <- readLines(path, warn = FALSE)
  linux <- grep("Maximum resident set size \\(kbytes\\)", lines, value = TRUE)
  if (length(linux)) {
    value <- as.numeric(sub("^.*:\\s*", "", linux[[length(linux)]]))
    return(value / 1024)
  }
  macos <- grep("maximum resident set size", lines, value = TRUE,
                ignore.case = TRUE)
  if (!length(macos)) return(NA_real_)
  value <- as.numeric(sub("^\\s*([0-9]+).*$", "\\1", macos[[length(macos)]]))
  value / 1024^2
}

route_spec <- function(prefix, family, backend, solver, ncomp, label) {
  stem <- sprintf("%s_%s_%s_%s_k%d", prefix, family, backend, solver, ncomp)
  list(
    stem = stem, family = family, backend = backend, solver = solver,
    ncomp = ncomp, label = label,
    result = file.path(input_dir, paste0(stem, ".csv")),
    prediction = file.path(input_dir, paste0(stem, "_prediction.rds")),
    time = file.path(input_dir, paste0(stem, ".time"))
  )
}

fixed <- list(
  route_spec("fixed165", "plssvd", "cpu", "irlba", 165L, "PLS-SVD CPU / IRLBA"),
  route_spec("fixed165", "plssvd", "cpu", "rsvd", 165L, "PLS-SVD CPU / rSVD"),
  route_spec("fixed165", "plssvd", "cuda", "rsvd", 165L, "PLS-SVD CUDA / rSVD"),
  route_spec("fixed165", "plssvd", "metal", "rsvd", 165L, "PLS-SVD Metal / rSVD"),
  route_spec("fixed165", "simpls", "cpu", "irlba", 165L, "SIMPLS CPU / IRLBA"),
  route_spec("fixed165", "simpls", "cpu", "rsvd", 165L, "SIMPLS CPU / rSVD"),
  route_spec("fixed165", "simpls", "cuda", "rsvd", 165L, "SIMPLS CUDA / rSVD"),
  route_spec("fixed165", "simpls", "metal", "rsvd", 165L, "SIMPLS Metal / rSVD")
)
selected <- list(
  route_spec("selected", "plssvd", "cpu", "irlba", selected_plssvd, "PLS-SVD CPU / IRLBA"),
  route_spec("selected", "plssvd", "cpu", "rsvd", selected_plssvd, "PLS-SVD CPU / rSVD"),
  route_spec("selected", "plssvd", "cuda", "rsvd", selected_plssvd, "PLS-SVD CUDA / rSVD"),
  route_spec("selected", "plssvd", "metal", "rsvd", selected_plssvd, "PLS-SVD Metal / rSVD"),
  route_spec("selected", "simpls", "cpu", "irlba", selected_simpls, "SIMPLS CPU / IRLBA"),
  route_spec("selected", "simpls", "cpu", "rsvd", selected_simpls, "SIMPLS CPU / rSVD"),
  route_spec("selected", "simpls", "cuda", "rsvd", selected_simpls, "SIMPLS CUDA / rSVD"),
  route_spec("selected", "simpls", "metal", "rsvd", selected_simpls, "SIMPLS Metal / rSVD")
)

validate_specs <- function(specs, require_prediction = TRUE) {
  paths <- unlist(lapply(specs, function(x) {
    required <- c(x$result, x$time)
    if (require_prediction) required <- c(required, x$prediction)
    required
  }))
  absent <- paths[!file.exists(paths)]
  if (length(absent)) stop("Missing current-release NMR files: ", paste(absent, collapse = ", "))
}
validate_specs(fixed)
validate_specs(selected, require_prediction = FALSE)

summarize_specs <- function(specs) {
  do.call(rbind, lapply(specs, function(spec) {
    result <- read_result(spec$result)
    peak <- read_peak(spec$time)
    data.frame(
      label = spec$label, family = spec$family, backend = spec$backend,
      solver = spec$solver, ncomp = spec$ncomp,
      control_profile = if ("control_profile" %in% names(result)) {
        result$control_profile[[1L]]
      } else {
        NA_character_
      },
      oversample = if ("oversample" %in% names(result)) {
        result$oversample[[1L]]
      } else {
        NA_integer_
      },
      power = if ("power" %in% names(result)) {
        result$power[[1L]]
      } else {
        NA_integer_
      },
      seed = if ("seed" %in% names(result)) result$seed[[1L]] else NA_integer_,
      RMSD = median(result$RMSD), Q2 = median(result$Q2),
      total_time_sec = median(result$total_time_sec),
      total_time_iqr = IQR(result$total_time_sec),
      incremental_peak_rss_mib = pmax(0, peak - median(result$baseline_rss_mb)),
      stringsAsFactors = FALSE
    )
  }))
}

fixed_summary <- summarize_specs(fixed)
if (nzchar(deposited_summary_csv) && file.exists(deposited_summary_csv)) {
  deposited_files <- if (dir.exists(deposited_summary_csv)) {
    list.files(
      deposited_summary_csv,
      pattern = "^deposited_plssvd_cpu_irlba_k165_rep[0-9]+[.]csv$",
      full.names = TRUE
    )
  } else {
    deposited_summary_csv
  }
  deposited <- do.call(rbind, lapply(deposited_files, read_result))
  deposited_peak <- deposited$process_peak_rss_mb
  deposited_increment <- deposited_peak - deposited$baseline_rss_mb
  deposited_row <- data.frame(
    label = "Deposited PLS-SVD", family = "plssvd", backend = "cpu",
    solver = "irlba", ncomp = 165L,
    control_profile = NA_character_, oversample = NA_integer_,
    power = NA_integer_, seed = NA_integer_,
    RMSD = median(deposited$RMSD), Q2 = median(deposited$Q2),
    total_time_sec = median(deposited$total_time_sec),
    total_time_iqr = IQR(deposited$total_time_sec),
    incremental_peak_rss_mib = median(
      deposited_increment[is.finite(deposited_increment)]
    ),
    stringsAsFactors = FALSE
  )
  fixed_summary <- rbind(deposited_row, fixed_summary)
}
selected_summary <- summarize_specs(selected)

colours <- c(
  "Deposited PLS-SVD" = "#D55E00", "PLS-SVD CPU / IRLBA" = "#56B4E9",
  "PLS-SVD CPU / rSVD" = "#0072B2", "PLS-SVD CUDA / rSVD" = "#004C6D",
  "PLS-SVD Metal / rSVD" = "#CC79A7",
  "SIMPLS CPU / IRLBA" = "#8FD175", "SIMPLS CPU / rSVD" = "#009E73",
  "SIMPLS CUDA / rSVD" = "#006B4F", "SIMPLS Metal / rSVD" = "#E69F00"
)
theme_nmr <- ggplot2::theme_classic(base_size = 10) + ggplot2::theme(
  plot.title = ggplot2::element_text(face = "bold", size = 10),
  plot.subtitle = ggplot2::element_text(size = 8),
  axis.title = ggplot2::element_text(face = "bold", size = 9),
  axis.text = ggplot2::element_text(colour = "black", size = 8),
  legend.position = "bottom", legend.text = ggplot2::element_text(size = 7)
)
point_panel <- function(data, value, title, xlab, log10 = FALSE) {
  data$label <- factor(data$label, levels = rev(unique(data$label)))
  p <- ggplot2::ggplot(data, ggplot2::aes(.data[[value]], label, colour = label)) +
    ggplot2::geom_point(size = 2.5) +
    ggplot2::scale_colour_manual(values = colours, guide = "none") +
    ggplot2::labs(title = title, x = xlab, y = NULL) + theme_nmr
  if (log10) p <- p + ggplot2::scale_x_log10(labels = scales::label_number())
  p
}

fixed_labels <- vapply(fixed, `[[`, character(1), "label")
per_sample_parts <- vector("list", length(fixed))
target <- NULL
for (index in seq_along(fixed)) {
  object <- readRDS(fixed[[index]]$prediction)
  per_sample_parts[[index]] <- data.frame(
    label = fixed[[index]]$label,
    RMSD = object$per_sample_rmsd
  )
  if (identical(fixed[[index]]$label, "SIMPLS CUDA / rSVD")) {
    target <- object
  }
  rm(object)
}
per_sample <- do.call(rbind, per_sample_parts)
if (is.null(target)) stop("The fixed CUDA SIMPLS prediction is missing.")
representative <- which.min(abs(target$per_sample_rmsd - median(target$per_sample_rmsd)))
ppm <- suppressWarnings(as.numeric(colnames(target$observed)))
spectrum <- rbind(
  data.frame(ppm = ppm, intensity = target$observed[representative, ], series = "Observed"),
  data.frame(ppm = ppm, intensity = target$predicted[representative, ], series = "SIMPLS CUDA / rSVD")
)
if (nzchar(deposited_prediction_rds) && file.exists(deposited_prediction_rds)) {
  deposited_object <- readRDS(deposited_prediction_rds)
  deposited_prediction <- if (is.list(deposited_object)) {
    deposited_object$predicted
  } else {
    deposited_object
  }
  stopifnot(identical(dim(deposited_prediction), dim(target$observed)))
  deposited_sample_rmsd <- if (
    is.list(deposited_object) && !is.null(deposited_object$per_sample_RMSD)
  ) {
    deposited_object$per_sample_RMSD
  } else {
    sqrt(rowMeans((target$observed - deposited_prediction)^2))
  }
  per_sample <- rbind(
    per_sample,
    data.frame(label = "Deposited PLS-SVD", RMSD = deposited_sample_rmsd)
  )
  spectrum <- rbind(spectrum, data.frame(
    ppm = ppm, intensity = deposited_prediction[representative, ],
    series = "Deposited PLS-SVD"
  ))
}
per_sample$label <- factor(
  per_sample$label,
  levels = rev(c("Deposited PLS-SVD", fixed_labels))
)
spectrum_colours <- c(
  "Observed" = "#111111", "SIMPLS CUDA / rSVD" = "#0072B2",
  "Deposited PLS-SVD" = "#D55E00"
)
spectrum_panel <- function(data, title) {
  ggplot2::ggplot(data, ggplot2::aes(ppm, intensity, colour = series, linetype = series)) +
    ggplot2::geom_line(linewidth = 0.42) + ggplot2::scale_x_reverse() +
    ggplot2::scale_colour_manual(values = spectrum_colours) +
    ggplot2::labs(title = title, x = "Chemical shift (ppm)", y = "Intensity") + theme_nmr
}

p_distribution <- ggplot2::ggplot(
  per_sample, ggplot2::aes(RMSD, label, fill = label)
) +
  ggplot2::geom_boxplot(width = 0.58, outlier.size = 0.5) +
  ggplot2::scale_fill_manual(values = colours, guide = "none") +
  ggplot2::labs(title = "D  Per-spectrum error", x = "RMSD", y = NULL) +
  theme_nmr
p_spectrum <- spectrum_panel(spectrum, "E  Representative held-out spectrum")
p_spectrum_zoom <- spectrum_panel(
  subset(spectrum, ppm >= 0.5 & ppm <= 1.7),
  "F  Expanded 1.7-0.5 ppm region"
)

main_figure <- (
  point_panel(fixed_summary, "RMSD", "A  Held-out prediction", "Global RMSD") +
    point_panel(fixed_summary, "total_time_sec", "B  Fitting plus prediction", "Time (s, log scale)", TRUE) +
    point_panel(fixed_summary, "incremental_peak_rss_mib", "C  Host-memory increment", "Peak increment (MiB, log scale)", TRUE)
) / (
  p_distribution + p_spectrum + p_spectrum_zoom
) + patchwork::plot_layout(guides = "collect") + patchwork::plot_annotation(
  title = "NMR prediction and computation at 165 components",
  subtitle = paste(
    "fastPLS 0.99.39; float64; identical split, preprocessing,",
    "prediction target, and component count"
  )
) & ggplot2::theme(legend.position = "bottom")
ggplot2::ggsave(file.path(out_dir, "Figure_nmr_fixed165_0.99.39.png"), main_figure,
                width = 12.2, height = 8.1, dpi = 360, bg = "white")
utils::write.csv(fixed_summary, file.path(out_dir, "nmr_fixed165_summary.csv"), row.names = FALSE)

selection_paths <- c(
  `PLS-SVD` = plssvd_selection_csv,
  SIMPLS = simpls_selection_csv
)
missing_selection <- selection_paths[!file.exists(selection_paths)]
if (length(missing_selection)) {
  stop("Missing component-selection files: ", paste(missing_selection, collapse = ", "))
}
selection <- do.call(rbind, lapply(names(selection_paths), function(family) {
  values <- read_result(selection_paths[[family]])
  values <- values[values$status %in% c("ok", "success"), ]
  values$family <- family
  values
}))
selection_summary <- do.call(rbind, lapply(
  split(selection, list(selection$family, selection$ncomp), drop = TRUE),
  function(values) {
    data.frame(
      family = values$family[[1L]], ncomp = values$ncomp[[1L]],
      mean = mean(values$RMSD),
      se = stats::sd(values$RMSD) / sqrt(nrow(values))
    )
  }
))
selection_summary <- selection_summary[order(
  selection_summary$family, selection_summary$ncomp
), ]
selection_decisions <- do.call(rbind, lapply(
  split(selection_summary, selection_summary$family),
  function(values) {
    minimum_index <- which.min(values$mean)
    threshold <- values$mean[[minimum_index]] + values$se[[minimum_index]]
    eligible <- values$ncomp[values$mean <= threshold]
    data.frame(
      family = values$family[[1L]],
      minimum_ncomp = values$ncomp[[minimum_index]],
      threshold = threshold,
      eligible = paste(eligible, collapse = ","),
      selected_ncomp = min(eligible)
    )
  }
))

selection_plot <- ggplot2::ggplot(
  selection, ggplot2::aes(ncomp, RMSD, group = interaction(family, split))
) +
  ggplot2::geom_line(colour = "grey72", linewidth = 0.35) +
  ggplot2::geom_ribbon(
    data = selection_summary,
    ggplot2::aes(
      x = ncomp, ymin = mean - se, ymax = mean + se,
      fill = family, group = family
    ),
    inherit.aes = FALSE, alpha = 0.18
  ) +
  ggplot2::geom_line(
    data = selection_summary,
    ggplot2::aes(x = ncomp, y = mean, colour = family, group = family),
    inherit.aes = FALSE, linewidth = 0.9
  ) +
  ggplot2::geom_hline(
    data = selection_decisions,
    ggplot2::aes(yintercept = threshold), linetype = 3
  ) +
  ggplot2::geom_vline(
    data = selection_decisions,
    ggplot2::aes(xintercept = selected_ncomp), linetype = 2
  ) +
  ggplot2::facet_wrap(~family, ncol = 1, scales = "free_y") +
  ggplot2::scale_colour_manual(values = c(`PLS-SVD` = "#0072B2", SIMPLS = "#009E73")) +
  ggplot2::scale_fill_manual(values = c(`PLS-SVD` = "#0072B2", SIMPLS = "#009E73")) +
  ggplot2::labs(
    title = "A  Training-only component selection",
    subtitle = "Dashed lines show the smallest component count within one standard error of each family minimum",
    x = "Number of components", y = "Validation RMSD"
  ) + theme_nmr + ggplot2::theme(legend.position = "none")

selected_summary$label <- factor(
  selected_summary$label,
  levels = rev(selected_summary$label)
)
selected_panel <- function(value, title, log_scale = FALSE) {
  data <- data.frame(label = selected_summary$label, value = value)
  plot <- ggplot2::ggplot(data, ggplot2::aes(value, label, fill = label)) +
    ggplot2::geom_col(width = 0.65) +
    ggplot2::scale_fill_manual(values = colours, guide = "none") +
    ggplot2::labs(title = title, x = NULL, y = NULL) +
    theme_nmr +
    ggplot2::theme(plot.title = ggplot2::element_text(size = 9, hjust = 0.5))
  if (isTRUE(log_scale)) {
    plot <- plot + ggplot2::scale_x_log10(
      breaks = c(0.1, 1, 10, 100, 1000),
      labels = c("0.1", "1", "10", "100", "1,000")
    )
  }
  plot
}

selected_plot <- (
  selected_panel(selected_summary$incremental_peak_rss_mib, "Peak RSS increment (MiB)") +
    selected_panel(selected_summary$Q2, "Q\u00b2")
) / (
  selected_panel(selected_summary$RMSD, "RMSD") +
    selected_panel(selected_summary$total_time_sec, "Time (s; log scale)", log_scale = TRUE)
) +
  patchwork::plot_annotation(
    title = "B  Training-selected predictive and computational endpoints"
  )

supp_figure <- selection_plot / selected_plot +
  patchwork::plot_layout(heights = c(1.25, 1)) +
  patchwork::plot_annotation(
  title = "Training-selected NMR PLS-SVD and SIMPLS workflows",
  subtitle = "fastPLS 0.99.39; model selection is separate from the matched 165-component implementation benchmark"
)
ggplot2::ggsave(file.path(out_dir, "Figure_nmr_selected_0.99.39.png"), supp_figure,
                width = 7.4, height = 10.0, dpi = 360, bg = "white")
utils::write.csv(selection_summary, file.path(out_dir, "nmr_selection_summary.csv"), row.names = FALSE)
utils::write.csv(selection_decisions, file.path(out_dir, "nmr_selection_decisions.csv"), row.names = FALSE)
utils::write.csv(selected_summary, file.path(out_dir, "nmr_selected_summary.csv"), row.names = FALSE)

writeLines(c(
  "package_version=0.99.39",
  paste0(
    "rsvd_controls=",
    paste(unique(with(
      subset(rbind(fixed_summary, selected_summary), solver == "rsvd"),
      sprintf(
        "%s/%s/%s: oversample=%s, power=%s, seed=%s",
        family, backend, control_profile, oversample, power, seed
      )
    )), collapse = "; ")
  ),
  "fixed_component_count=165",
  paste0("selected_plssvd_components=", selected_plssvd),
  paste0("selected_simpls_components=", selected_simpls),
  paste0(
    "selection_decisions=",
    paste(
      sprintf(
        "%s: minimum=%d, eligible=%s, selected=%d",
        selection_decisions$family,
        selection_decisions$minimum_ncomp,
        selection_decisions$eligible,
        selection_decisions$selected_ncomp
      ),
      collapse = "; "
    )
  ),
  paste0("representative_sample_index=", representative)
), file.path(out_dir, "nmr_figure_manifest.txt"))
