#!/usr/bin/env Rscript

# Summarize the current-release component paths produced independently on the
# CUDA and Metal workstations. CPU rows remain platform-specific so runtime
# ratios are never formed across computers.

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 4L) {
    stop(
        "Usage: summarize_current_component_paths.R ",
        "CUDA_RAW METAL_RAW COMPONENT_SELECTION OUTPUT_DIR",
        call. = FALSE
    )
}

required <- c("ggplot2", "data.table")
missing <- required[!vapply(required, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing)) {
    stop("Missing packages: ", paste(missing, collapse = ", "), call. = FALSE)
}

suppressPackageStartupMessages({
    library(data.table)
    library(ggplot2)
})

cuda_file <- normalizePath(args[[1L]], mustWork = TRUE)
metal_file <- normalizePath(args[[2L]], mustWork = TRUE)
selection_file <- normalizePath(args[[3L]], mustWork = TRUE)
output_dir <- normalizePath(args[[4L]], mustWork = FALSE)
plot_dir <- file.path(output_dir, "component_path_plots")
dir.create(plot_dir, recursive = TRUE, showWarnings = FALSE)

read_panel <- function(path, platform_name) {
    value <- fread(path)
    value[, platform := platform_name]
    value
}

raw <- rbindlist(
    list(read_panel(cuda_file, "CUDA workstation"),
         read_panel(metal_file, "Metal workstation")),
    use.names = TRUE,
    fill = TRUE
)
raw <- raw[status == "success"]
raw[, backend := toupper(backend_requested)]
raw[backend == "METAL", backend := "Metal"]
raw[backend == "CUDA", backend := "CUDA"]
raw[backend == "CPU", backend := "CPU"]

median_iqr <- function(x) {
    x <- x[is.finite(x)]
    if (!length(x)) return(c(median = NA_real_, q1 = NA_real_, q3 = NA_real_))
    c(
        median = stats::median(x),
        q1 = unname(stats::quantile(x, 0.25)),
        q3 = unname(stats::quantile(x, 0.75))
    )
}

summary <- raw[, {
    elapsed <- median_iqr(total_sec)
    metric <- median_iqr(metric_value)
    peak <- median_iqr(peak_rss_mb)
    incremental <- median_iqr(incremental_peak_rss_mb)
    list(
        n_success = .N,
        metric_name = metric_name[[1L]],
        metric_median = metric[["median"]],
        metric_q1 = metric[["q1"]],
        metric_q3 = metric[["q3"]],
        total_sec_median = elapsed[["median"]],
        total_sec_q1 = elapsed[["q1"]],
        total_sec_q3 = elapsed[["q3"]],
        peak_rss_mib_median = peak[["median"]],
        peak_rss_mib_q1 = peak[["q1"]],
        peak_rss_mib_q3 = peak[["q3"]],
        incremental_rss_mib_median = incremental[["median"]],
        incremental_rss_mib_q1 = incremental[["q1"]],
        incremental_rss_mib_q3 = incremental[["q3"]],
        control_profile = paste(sort(unique(control_profile)), collapse = ";"),
        oversample = paste(sort(unique(oversample)), collapse = ";"),
        power = paste(sort(unique(power)), collapse = ";"),
        direction_rule = paste(sort(unique(direction_rule)), collapse = ";"),
        execution_route = paste(sort(unique(execution_route)), collapse = ";")
    )
}, by = .(platform, dataset, task_type, method, backend, ncomp, precision)]

selection <- fread(selection_file)
selection <- selection[status == "success", .(
    dataset,
    method = family,
    selected_ncomp = as.integer(selected_ncomp),
    selection_metric,
    selection_status,
    grid_min,
    grid_max,
    intrinsic_limit,
    selection_oversample = oversample,
    selection_power = power
)]

safe_cor <- function(x, y) {
    keep <- is.finite(x) & is.finite(y)
    if (sum(keep) < 3L || uniqueN(x[keep]) < 3L || uniqueN(y[keep]) < 2L) {
        return(NA_real_)
    }
    suppressWarnings(stats::cor(x[keep], y[keep], method = "spearman"))
}

correlations <- summary[, .(
    n_path_points = uniqueN(ncomp),
    metric_name = metric_name[[1L]],
    rho_metric = safe_cor(ncomp, metric_median),
    rho_total_time = safe_cor(ncomp, total_sec_median),
    rho_peak_rss = safe_cor(ncomp, peak_rss_mib_median),
    rho_incremental_rss = safe_cor(ncomp, incremental_rss_mib_median)
), by = .(platform, dataset, method, backend)]

fwrite(raw, file.path(output_dir, "component_path_raw.csv"))
fwrite(summary, file.path(output_dir, "component_path_summary.csv"))
fwrite(selection, file.path(output_dir, "component_selection.csv"))
fwrite(correlations, file.path(output_dir, "component_metric_correlations.csv"))

dataset_labels <- c(
    cbmc_citeseq = "CBMC CITE-seq", ccle = "CCLE", cifar100 = "CIFAR-100",
    gtex_v8 = "GTEx v8", metref = "MetRef", prism = "PRISM",
    retina = "Retina", tabula = "Tabula Muris", tcga_brca = "TCGA-BRCA",
    tcga_hnsc_methylation = "TCGA-HNSC methylation",
    tcga_pan_cancer = "TCGA Pan-Cancer"
)
family_labels <- c(
    plssvd = "PLS-SVD", simpls = "SIMPLS", opls = "OPLS",
    kernelpls = "kernel PLS"
)
backend_colours <- c(CPU = "#2166AC", CUDA = "#B2182B", Metal = "#D95F02")

plot_long <- rbindlist(list(
    summary[, .(platform, dataset, method, backend, ncomp,
                measure = "Predictive metric", value = metric_median)],
    summary[, .(platform, dataset, method, backend, ncomp,
                measure = "Total time (s)", value = total_sec_median)],
    summary[, .(platform, dataset, method, backend, ncomp,
                measure = "Incremental host RSS (MiB)",
                value = incremental_rss_mib_median)]
))
plot_long[, method := factor(method, levels = names(family_labels),
                             labels = unname(family_labels))]
plot_long[, measure := factor(
    measure,
    levels = c("Predictive metric", "Total time (s)",
               "Incremental host RSS (MiB)")
)]

for (dataset_id in unique(plot_long$dataset)) {
    current <- plot_long[dataset == dataset_id & is.finite(value)]
    selected <- selection[dataset == dataset_id]
    selected[, method := factor(method, levels = names(family_labels),
                                labels = unname(family_labels))]
    figure <- ggplot(
        current,
        aes(ncomp, value, colour = backend, linetype = platform,
            group = interaction(platform, backend))
    ) +
        geom_vline(
            data = selected,
            aes(xintercept = selected_ncomp),
            inherit.aes = FALSE,
            colour = "grey35",
            linewidth = 0.35,
            linetype = "dotted"
        ) +
        geom_line(linewidth = 0.62, na.rm = TRUE) +
        geom_point(size = 1.5, na.rm = TRUE) +
        facet_grid(measure ~ method, scales = "free_y") +
        scale_colour_manual(values = backend_colours) +
        labs(
            title = dataset_labels[[dataset_id]],
            subtitle = paste(
                "Current fastPLS component paths; dotted lines mark",
                "training-selected component counts"
            ),
            x = "Requested components",
            y = NULL,
            colour = "Backend",
            linetype = "Computer"
        ) +
        theme_minimal(base_size = 8.5) +
        theme(
            plot.title = element_text(face = "bold", size = 12),
            strip.text = element_text(face = "bold"),
            panel.grid.minor = element_blank(),
            legend.position = "bottom"
        )
    stem <- paste0("component_path_", dataset_id)
    ggsave(file.path(plot_dir, paste0(stem, ".png")), figure,
           width = 9.0, height = 7.0, units = "in", dpi = 300, bg = "white")
    ggsave(file.path(plot_dir, paste0(stem, ".pdf")), figure,
           width = 9.0, height = 7.0, units = "in", device = cairo_pdf,
           bg = "white")
}

message("Wrote current-release component-path summaries to ", output_dir)
