#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 3L) {
    stop(
        "Usage: build_supplement_cuda_ikpls_figure.R SUMMARY_CSV OUTPUT_PNG OUTPUT_PDF",
        call. = FALSE
    )
}

suppressPackageStartupMessages({
    library(ggplot2)
    library(patchwork)
    library(scales)
})

input <- read.csv(args[[1L]], stringsAsFactors = FALSE, check.names = FALSE)
required <- c(
    "dataset", "task_type", "implementation", "median_accuracy",
    "median_rmsd", "median_cold_total_sec", "median_warm_total_sec",
    "median_peak_rss_mib", "median_peak_gpu_process_mib"
)
missing <- setdiff(required, names(input))
if (length(missing)) {
    stop("CUDA comparison summary is missing: ", paste(missing, collapse = ", "))
}

classification_datasets <- c(
    "ccle", "cifar100", "gtex_v8", "metref", "retina", "tabula",
    "tcga_brca", "tcga_hnsc_methylation", "tcga_pan_cancer", "imagenet"
)
regression_datasets <- c("cbmc_citeseq", "prism", "nmr")
dataset_labels <- c(
    ccle = "CCLE", cifar100 = "CIFAR-100", gtex_v8 = "GTEx v8",
    metref = "MetRef", retina = "Retina", tabula = "Tabula\nMuris",
    tcga_brca = "TCGA-\nBRCA",
    tcga_hnsc_methylation = "TCGA-HNSC\nmethyl.",
    tcga_pan_cancer = "TCGA Pan-\nCancer",
    imagenet = "ImageNet/\nDINOv2", cbmc_citeseq = "CBMC\nCITE-seq",
    prism = "PRISM", nmr = "NMR"
)
methods <- c("fastPLS_cuda", "IKPLS_jax_cuda_alg2")
method_labels <- c(
    fastPLS_cuda = "fastPLS",
    IKPLS_jax_cuda_alg2 = "IKPLS"
)

complete_panel <- function(task_type, datasets) {
    grid <- expand.grid(
        dataset = datasets, implementation = methods,
        stringsAsFactors = FALSE
    )
    observed <- input[input$task_type == task_type, , drop = FALSE]
    merged <- merge(grid, observed, by = c("dataset", "implementation"), all.x = TRUE)
    merged$dataset <- factor(
        merged$dataset, levels = datasets, labels = dataset_labels[datasets]
    )
    merged$implementation <- factor(merged$implementation, levels = rev(methods))
    merged
}

classification <- complete_panel("classification", classification_datasets)
regression <- complete_panel("regression", regression_datasets)

status_label <- function(data, value) {
    ifelse(
        !is.na(value), "",
        ifelse(
            grepl("memory|oom|resource", data$status, ignore.case = TRUE),
            "Memory\nlimit",
            ifelse(grepl("fail|error", data$status, ignore.case = TRUE), "Failed", "NE")
        )
    )
}

publication_theme <- function(show_y = TRUE) {
    theme_minimal(base_size = 8.2) +
        theme(
            axis.title = element_blank(),
            axis.text.x = element_text(face = "bold", size = 5.8, angle = 45,
                                       hjust = 1),
            axis.text.y = if (show_y) element_text(size = 7.2) else element_blank(),
            axis.ticks = element_blank(),
            panel.grid = element_blank(),
            plot.title = element_text(face = "bold", size = 9.7),
            plot.subtitle = element_text(size = 6.8),
            legend.key.height = unit(0.22, "in"),
            plot.margin = margin(3, 5, 3, 5)
        )
}

format_time <- function(cold, warm) {
    one <- function(value) {
        ifelse(value < 0.1, sprintf("%.3f", value),
               ifelse(value < 10, sprintf("%.2f", value), sprintf("%.0f", value)))
    }
    ifelse(is.na(cold), "", paste0(one(cold), "\n(", one(warm), ")"))
}

heat_panel <- function(data, field, title, subtitle, colours, formatter,
                       trans = "identity", limits = NULL, show_y = TRUE,
                       labels = NULL) {
    data$value <- data[[field]]
    data$label <- if (is.null(labels)) formatter(data$value) else labels
    data$label[is.na(data$value)] <- status_label(data, data$value)[is.na(data$value)]
    ggplot(data, aes(dataset, implementation, fill = value)) +
        geom_tile(colour = "white", linewidth = 0.4) +
        geom_text(aes(label = label), size = 2.0, colour = "grey10", lineheight = 0.9) +
        scale_fill_gradientn(
            colours = colours, trans = trans, limits = limits,
            oob = squish, na.value = "grey88", name = NULL
        ) +
        scale_y_discrete(labels = method_labels) +
        labs(title = title, subtitle = subtitle) +
        publication_theme(show_y)
}

time_limits <- range(
    c(classification$median_cold_total_sec, regression$median_cold_total_sec),
    na.rm = TRUE
)
host_limits <- range(
    c(classification$median_peak_rss_mib, regression$median_peak_rss_mib),
    na.rm = TRUE
)
gpu_limits <- range(
    c(classification$median_peak_gpu_process_mib,
      regression$median_peak_gpu_process_mib),
    na.rm = TRUE
)

panel_a <- heat_panel(
    classification, "median_accuracy", "A  Classification accuracy",
    "Held-out fraction correct",
    c("#eff6fb", "#78b7d6", "#0a4c86"),
    function(value) ifelse(is.na(value), "", sprintf("%.3f", value)),
    limits = c(0, 1)
)
panel_b <- heat_panel(
    regression, "median_rmsd", "B  Regression RMSD",
    "Held-out root mean squared deviation; lower is better",
    c("#e7f5ee", "#63b59d", "#075b4c"),
    function(value) ifelse(is.na(value), "", ifelse(
        value >= 100, sprintf("%.0f", value), sprintf("%.4g", value)
    )),
    trans = "log10", show_y = FALSE
)
panel_c <- heat_panel(
    classification, "median_cold_total_sec", "C  Classification time",
    "Cold total (warm total) in seconds",
    c("#fff4dd", "#f3a35c", "#a31316"), identity,
    trans = "log10", limits = time_limits,
    labels = format_time(
        classification$median_cold_total_sec,
        classification$median_warm_total_sec
    )
)
panel_d <- heat_panel(
    regression, "median_cold_total_sec", "D  Regression time",
    "Cold total (warm total) in seconds",
    c("#fff4dd", "#f3a35c", "#a31316"), identity,
    trans = "log10", limits = time_limits, show_y = FALSE,
    labels = format_time(regression$median_cold_total_sec,
                         regression$median_warm_total_sec)
)
panel_e <- heat_panel(
    classification, "median_peak_rss_mib", "E  Classification host memory",
    "Absolute peak process RSS (MiB)",
    c("#edf7e9", "#74c476", "#005a32"),
    function(value) ifelse(is.na(value), "", sprintf("%.0f", value)),
    trans = "log10", limits = host_limits
)
panel_f <- heat_panel(
    regression, "median_peak_rss_mib", "F  Regression host memory",
    "Absolute peak process RSS (MiB)",
    c("#edf7e9", "#74c476", "#005a32"),
    function(value) ifelse(is.na(value), "", sprintf("%.0f", value)),
    trans = "log10", limits = host_limits, show_y = FALSE
)
panel_g <- heat_panel(
    classification, "median_peak_gpu_process_mib", "G  Classification device memory",
    "Peak memory attributed to the benchmark process (MiB)",
    c("#f2eef7", "#9e9ac8", "#54278f"),
    function(value) ifelse(is.na(value), "", sprintf("%.0f", value)),
    trans = "log10", limits = gpu_limits
)
panel_h <- heat_panel(
    regression, "median_peak_gpu_process_mib", "H  Regression device memory",
    "Peak memory attributed to the benchmark process (MiB)",
    c("#f2eef7", "#9e9ac8", "#54278f"),
    function(value) ifelse(is.na(value), "", sprintf("%.0f", value)),
    trans = "log10", limits = gpu_limits, show_y = FALSE
)

widths <- c(length(classification_datasets), length(regression_datasets))
figure <- wrap_plots(
    wrap_plots(panel_a, panel_b, nrow = 1, widths = widths),
    wrap_plots(panel_c, panel_d, nrow = 1, widths = widths),
    wrap_plots(panel_e, panel_f, nrow = 1, widths = widths),
    wrap_plots(panel_g, panel_h, nrow = 1, widths = widths),
    ncol = 1
) +
    plot_annotation(
        title = "CUDA PLS prediction workflows",
        subtitle = paste(
            "Matched float32 inputs and SIMPLS component contract;",
            "fastPLS SIMPLS-LDA/regression versus IKPLS algorithm 2"
        ),
        theme = theme(
            plot.title = element_text(face = "bold", size = 14),
            plot.subtitle = element_text(size = 8.5)
        )
    )

dir.create(dirname(args[[2L]]), recursive = TRUE, showWarnings = FALSE)
ggsave(args[[2L]], figure, width = 11.2, height = 8.6, units = "in",
       dpi = 300, bg = "white")
ggsave(args[[3L]], figure, width = 11.2, height = 8.6, units = "in",
       device = cairo_pdf, bg = "white")
