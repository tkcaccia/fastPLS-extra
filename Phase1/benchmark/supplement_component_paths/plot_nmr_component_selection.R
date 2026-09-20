#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 4L) {
    stop(
        paste(
            "Usage: plot_nmr_component_selection.R",
            "BACKEND_COMPONENT_RAW PLSSVD_DECISION SIMPLS_DECISION OUTPUT_DIR"
        ),
        call. = FALSE
    )
}

required <- c("data.table", "ggplot2")
missing <- required[!vapply(required, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing)) {
    stop("Missing packages: ", paste(missing, collapse = ", "), call. = FALSE)
}

suppressPackageStartupMessages({
    library(data.table)
    library(ggplot2)
})

raw <- fread(normalizePath(args[[1L]], mustWork = TRUE))
decision <- rbindlist(list(
    cbind(
        family = "plssvd",
        fread(normalizePath(args[[2L]], mustWork = TRUE))
    ),
    cbind(
        family = "simpls",
        fread(normalizePath(args[[3L]], mustWork = TRUE))
    )
), use.names = TRUE, fill = TRUE)
if (nrow(decision) != 2L || any(!is.finite(decision$selected_ncomp))) {
    stop("The NMR one-standard-error decisions are incomplete.")
}
output_dir <- normalizePath(args[[4L]], mustWork = FALSE)
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

required_columns <- c(
    "family", "backend", "platform", "requested_ncomp", "replicate",
    "metric_value", "total_sec", "incremental_peak_rss_mib", "status"
)
if (length(setdiff(required_columns, names(raw)))) {
    stop(
        "The backend component-path file is missing: ",
        paste(setdiff(required_columns, names(raw)), collapse = ", "),
        call. = FALSE
    )
}
raw <- raw[status == "success"]
if (!nrow(raw)) stop("No successful NMR component-path rows were found.")

family_levels <- c("PLS-SVD", "SIMPLS-family", "OPLS", "kernel PLS")
family_labels <- c(
    plssvd = "PLS-SVD", simpls = "SIMPLS-family", opls = "OPLS",
    kernelpls = "kernel PLS"
)
decision[, selected_ncomp := as.integer(selected_ncomp)]
raw[, family_label := factor(family_labels[family], levels = family_levels)]
decision[, family_label := factor(family_labels[family], levels = family_levels)]

architecture_labels <- c(
    "linux_nvidia.cpu" = "Linux CPU",
    "linux_nvidia.cuda" = "CUDA"
)
raw[, architecture := architecture_labels[paste(platform, backend, sep = ".")]]
raw <- raw[!is.na(architecture)]
architecture_levels <- c("Linux CPU", "CUDA")
raw[, architecture := factor(architecture, levels = architecture_levels)]

summarize_measure <- function(column, measure_name) {
    result <- raw[, .(
        median = median(get(column), na.rm = TRUE),
        q25 = quantile(get(column), 0.25, na.rm = TRUE),
        q75 = quantile(get(column), 0.75, na.rm = TRUE),
        n_success = .N
    ), by = .(family, family_label, architecture, requested_ncomp)]
    result[, measure := measure_name]
    result
}
summary <- rbindlist(list(
    summarize_measure("metric_value", "Held-out RMSD"),
    summarize_measure("total_sec", "Fit + prediction time (s)"),
    summarize_measure(
        "incremental_peak_rss_mib", "Incremental host RSS (MiB)"
    )
), use.names = TRUE)
summary[, measure := factor(
    measure,
    levels = c(
        "Held-out RMSD", "Fit + prediction time (s)",
        "Incremental host RSS (MiB)"
    )
)]

fwrite(summary, file.path(output_dir, "nmr_test_component_path_summary.csv"))
fwrite(decision, file.path(output_dir, "nmr_training_selected_components.csv"))

architecture_colours <- c("Linux CPU" = "#009E73", "CUDA" = "#CC79A7")
architecture_shapes <- c("Linux CPU" = 23, "CUDA" = 24)
figure <- ggplot(
    summary,
    aes(
        requested_ncomp, median, colour = architecture,
        fill = architecture, group = architecture, shape = architecture
    )
) +
    geom_ribbon(aes(ymin = q25, ymax = q75), alpha = 0.12, colour = NA) +
    geom_line(linewidth = 0.65) +
    geom_point(size = 2.0, stroke = 0.6, colour = "black") +
    geom_vline(
        data = decision,
        aes(xintercept = selected_ncomp),
        inherit.aes = FALSE,
        colour = "#444444",
        linewidth = 0.5,
        linetype = "dotted",
        show.legend = FALSE
    ) +
    facet_grid(measure ~ family_label, scales = "free_y") +
    scale_colour_manual(values = architecture_colours, drop = FALSE) +
    scale_fill_manual(values = architecture_colours, drop = FALSE) +
    scale_shape_manual(values = architecture_shapes, drop = FALSE) +
    scale_x_continuous(breaks = c(1, 50, 100, 150, 200, 250, 300)) +
    labs(
        title = "NMR component-dependent prediction and computation",
        subtitle = paste(
            "Models fitted on the predefined training set and evaluated on",
            "the fixed test set; medians and interquartile ranges from three",
            "isolated processes"
        ),
        x = "Components",
        y = NULL,
        colour = NULL,
        fill = NULL,
        shape = NULL
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

ggsave(
    file.path(output_dir, "figureS12_nmr_test_component_path.png"),
    figure,
    width = 10.8,
    height = 8.2,
    units = "in",
    dpi = 300,
    bg = "white"
)
ggsave(
    file.path(output_dir, "figureS12_nmr_test_component_path.pdf"),
    figure,
    width = 10.8,
    height = 8.2,
    units = "in",
    device = cairo_pdf,
    bg = "white"
)

message("Wrote held-out NMR component-path outputs to ", output_dir)
