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
scope <- tolower(Sys.getenv("FASTPLS_COMPONENT_PATH_SCOPE", "all"))
if (scope == "cmpb") {
    raw <- raw[platform == "CUDA workstation"]
} else if (scope != "all") {
    stop("FASTPLS_COMPONENT_PATH_SCOPE must be 'all' or 'cmpb'.")
}
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
}, by = .(
    platform, dataset, task_type, method, backend, classifier, ncomp, precision
)]

selection <- fread(selection_file)
if ("status" %in% names(selection)) {
    selection <- selection[status == "success"]
}
if (!"selected_classifier" %in% names(selection)) {
    selection[, selected_classifier := NA_character_]
}
selection <- selection[, .(
    dataset,
    method = family,
    selected_ncomp = as.integer(selected_ncomp),
    selected_classifier,
    selection_metric,
    selection_status,
    grid_min,
    grid_max,
    intrinsic_limit,
    selection_oversample = oversample,
    selection_power = power
)]
contract_file <- Sys.getenv("FASTPLS_COMPONENT_CONTRACT", "")
if (nzchar(contract_file)) {
    contract <- fread(normalizePath(contract_file, mustWork = TRUE))
    contract <- contract[, .(
        dataset, method = family,
        retained_ncomp = as.integer(selected_ncomp)
    )]
    selection <- merge(
        selection, contract,
        by = c("dataset", "method"), all.x = TRUE
    )
    selection[!is.na(retained_ncomp), selected_ncomp := retained_ncomp]
    selection[, retained_ncomp := NULL]
}

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
), by = .(platform, dataset, method, backend, classifier)]

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
architecture_colours <- c(
    "Mac CPU" = "#0072B2",
    "Metal" = "#E69F00",
    "Linux CPU" = "#009E73",
    "CUDA" = "#CC79A7"
)
if (scope == "cmpb") {
    architecture_colours <- architecture_colours[c("Linux CPU", "CUDA")]
}

plot_long <- rbindlist(list(
    summary[, .(platform, dataset, task_type, method, backend, classifier, ncomp,
                measure = "Predictive metric", value = metric_median,
                q1 = metric_q1, q3 = metric_q3)],
    summary[, .(platform, dataset, task_type, method, backend, classifier, ncomp,
                measure = "Fit + prediction time (s)", value = total_sec_median,
                q1 = total_sec_q1, q3 = total_sec_q3)],
    summary[, .(platform, dataset, task_type, method, backend, classifier, ncomp,
                measure = "Incremental host RSS (MiB)",
                value = incremental_rss_mib_median,
                q1 = incremental_rss_mib_q1,
                q3 = incremental_rss_mib_q3)]
))
plot_long[, architecture := fifelse(
    platform == "Metal workstation" & backend == "CPU", "Mac CPU",
    fifelse(
        platform == "Metal workstation" & backend == "Metal", "Metal",
        fifelse(backend == "CUDA", "CUDA", "Linux CPU")
    )
)]
plot_long[, classifier_display := fifelse(
    task_type == "regression", "Regression",
    fifelse(classifier == "lda", "LDA", "Argmax")
)]
plot_long[, architecture := factor(
    architecture,
    levels = names(architecture_colours)
)]
plot_long[, classifier_display := factor(
    classifier_display,
    levels = c("Argmax", "LDA", "Regression")
)]
plot_long[, method := factor(method, levels = names(family_labels),
                             labels = unname(family_labels))]
plot_long[, measure := factor(
    measure,
    levels = c("Predictive metric", "Fit + prediction time (s)",
               "Incremental host RSS (MiB)")
)]

architecture_shapes <- c(
    "Mac CPU" = 21,
    "Metal" = 22,
    "Linux CPU" = 23,
    "CUDA" = 24
)
architecture_shapes <- architecture_shapes[names(architecture_colours)]

for (dataset_id in unique(plot_long$dataset)) {
    current <- plot_long[dataset == dataset_id & is.finite(value)]
    metric_label <- if (current$task_type[[1L]] == "classification") {
        "Test accuracy"
    } else {
        "Test RMSD"
    }
    current[, measure_display := fifelse(
        as.character(measure) == "Predictive metric",
        metric_label,
        as.character(measure)
    )]
    current[, measure_display := factor(
        measure_display,
        levels = c(
            metric_label,
            "Fit + prediction time (s)",
            "Incremental host RSS (MiB)"
        )
    )]
    selected <- selection[dataset == dataset_id]
    selected[, method := factor(method, levels = names(family_labels),
                                labels = unname(family_labels))]
    figure <- ggplot(
        current,
        aes(
            ncomp,
            value,
            colour = architecture,
            fill = architecture,
            shape = architecture,
            linetype = classifier_display,
            group = interaction(architecture, classifier_display)
        )
    ) +
        geom_vline(
            data = selected,
            aes(xintercept = selected_ncomp),
            inherit.aes = FALSE,
            colour = "grey35",
            linewidth = 0.5,
            linetype = "dotted"
        ) +
        geom_ribbon(
            aes(ymin = q1, ymax = q3),
            alpha = 0.12,
            colour = NA,
            linetype = 0,
            show.legend = FALSE,
            na.rm = TRUE
        ) +
        geom_line(linewidth = 0.65, na.rm = TRUE) +
        geom_point(
            size = 2.0,
            stroke = 0.6,
            colour = "black",
            na.rm = TRUE
        ) +
        facet_grid(measure_display ~ method, scales = "free_y") +
        scale_colour_manual(values = architecture_colours, drop = FALSE) +
        scale_fill_manual(values = architecture_colours, drop = FALSE) +
        scale_shape_manual(values = architecture_shapes, drop = FALSE) +
        scale_linetype_manual(
            values = c(Argmax = "solid", LDA = "dashed", Regression = "solid")
        ) +
        labs(
            title = paste(
                dataset_labels[[dataset_id]],
                "component-dependent prediction and computation"
            ),
            subtitle = paste(
                "Models fitted on the predefined training set and evaluated on",
                "the fixed test set; medians and interquartile ranges from three",
                "isolated processes"
            ),
            x = "Components",
            y = NULL,
            colour = NULL,
            fill = NULL,
            shape = NULL,
            linetype = "Prediction head"
        ) +
        theme_bw(base_size = 9.5) +
        theme(
            plot.title = element_text(face = "bold", size = 13),
            strip.text = element_text(face = "bold"),
            panel.grid.minor = element_blank(),
            legend.position = "bottom",
            legend.box = "horizontal",
            axis.text.x = element_text(angle = 45, hjust = 1)
        )
    if (current$task_type[[1L]] == "regression") {
        figure <- figure + guides(linetype = "none")
    }
    stem <- paste0("component_path_", dataset_id)
    ggsave(file.path(plot_dir, paste0(stem, ".png")), figure,
           width = 10.8, height = 8.2, units = "in", dpi = 300, bg = "white")
    ggsave(file.path(plot_dir, paste0(stem, ".pdf")), figure,
           width = 10.8, height = 8.2, units = "in", device = cairo_pdf,
           bg = "white")
}

message("Wrote current-release component-path summaries to ", output_dir)
