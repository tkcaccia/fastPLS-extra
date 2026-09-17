#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 3L) {
    stop("Usage: build_figure1_six_panel.R DATA_CSV OUTPUT_PNG OUTPUT_PDF",
         call. = FALSE)
}

suppressPackageStartupMessages({
    library(ggplot2)
    library(patchwork)
    library(scales)
})

input <- read.csv(args[[1L]], stringsAsFactors = FALSE, check.names = FALSE)
required <- c(
    "dataset", "task_type", "implementation", "status", "accuracy",
    "rmsd", "total_sec", "peak_rss_mib"
)
missing <- setdiff(required, names(input))
if (length(missing)) {
    stop("Figure 1 data are missing: ", paste(missing, collapse = ", "),
         call. = FALSE)
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
classification_methods <- c(
    "fastPLS SIMPLS / LDA", "IKPLS",
    "scikit-learn / PLSRegression", "pls / SIMPLS",
    "plsgenomics / PLS-LDA", "mdatools / PLS-DA",
    "plsdepot / SIMPLS", "pcv / SIMPLS",
    "chemometrics / PLS eigen", "mixOmics / PLS-DA",
    "spls / sPLS-DA"
)
regression_methods <- c(
    "fastPLS SIMPLS", "IKPLS",
    "scikit-learn / PLSRegression", "pls / SIMPLS",
    "plsgenomics / PLS regression", "mdatools / PLS",
    "plsdepot / SIMPLS", "pcv / SIMPLS",
    "chemometrics / PLS eigen", "mixOmics / PLS", "spls / sPLS"
)
package_labels <- c(
    "fastPLS SIMPLS / LDA" = "fastPLS",
    "fastPLS SIMPLS" = "fastPLS",
    "IKPLS" = "IKPLS",
    "scikit-learn / PLSRegression" = "scikit-learn",
    "pls / SIMPLS" = "pls",
    "plsgenomics / PLS-LDA" = "plsgenomics",
    "plsgenomics / PLS regression" = "plsgenomics",
    "mdatools / PLS-DA" = "mdatools",
    "mdatools / PLS" = "mdatools",
    "plsdepot / SIMPLS" = "plsdepot",
    "pcv / SIMPLS" = "pcv",
    "chemometrics / PLS eigen" = "chemometrics",
    "mixOmics / PLS-DA" = "mixOmics",
    "mixOmics / PLS" = "mixOmics",
    "spls / sPLS-DA" = "spls",
    "spls / sPLS" = "spls"
)

complete_panel <- function(task_type, datasets, methods) {
    grid <- expand.grid(
        dataset = datasets, implementation = methods,
        stringsAsFactors = FALSE
    )
    observed <- input[input$task_type == task_type, , drop = FALSE]
    merged <- merge(
        grid, observed, by = c("dataset", "implementation"), all.x = TRUE
    )
    merged$dataset <- factor(
        merged$dataset, levels = datasets, labels = dataset_labels[datasets]
    )
    merged$implementation <- factor(
        merged$implementation, levels = rev(methods)
    )
    merged
}

classification <- complete_panel(
    "classification", classification_datasets, classification_methods
)
regression <- complete_panel(
    "regression", regression_datasets, regression_methods
)

status_label <- function(data, value) {
    ifelse(
        !is.na(value), "",
        ifelse(
            grepl("timeout", data$status, ignore.case = TRUE),
            "Timeout",
            ifelse(
                grepl("fail|error", data$status, ignore.case = TRUE),
                "Failed", "NE"
            )
        )
    )
}

format_time <- function(value) {
    ifelse(
        value < 0.1, sprintf("%.3f", value),
        ifelse(value < 10, sprintf("%.2f", value), sprintf("%.0f", value))
    )
}
format_rmsd <- function(value) {
    ifelse(
        value >= 100, sprintf("%.0f", value),
        ifelse(value >= 0.01, sprintf("%.3f", value), format(value,
            digits = 2L, scientific = TRUE
        ))
    )
}

publication_theme <- function(show_method_labels = TRUE) {
    theme_minimal(base_size = 8.3) +
        theme(
            axis.title = element_blank(),
            axis.text.x = element_text(
                face = "bold", size = 6.0, angle = 45, hjust = 1
            ),
            axis.text.y = if (show_method_labels) {
                element_text(size = 6.8)
            } else {
                element_blank()
            },
            axis.ticks.y = element_blank(),
            panel.grid = element_blank(),
            plot.title = element_text(face = "bold", size = 10),
            plot.subtitle = element_text(size = 7.2),
            legend.position = "right",
            legend.key.height = unit(0.25, "in"),
            plot.margin = margin(4, 5, 4, 5)
        )
}

heat_panel <- function(data, field, title, subtitle, colours, formatter,
                       transform = "identity", limits = NULL,
                       show_method_labels = TRUE) {
    value <- data[[field]]
    data$plot_value <- value
    failed <- grepl("fail|error|timeout", data$status, ignore.case = TRUE)
    data$cell_label <- ifelse(
        is.na(value), status_label(data, value),
        ifelse(failed, paste0(formatter(value), "*"), formatter(value))
    )
    ggplot(data, aes(dataset, implementation, fill = plot_value)) +
        geom_tile(colour = "white", linewidth = 0.35) +
        geom_text(aes(label = cell_label), size = 2.15, colour = "grey10") +
        scale_fill_gradientn(
            colours = colours, trans = transform, limits = limits,
            oob = squish, na.value = "grey88", name = NULL
        ) +
        scale_y_discrete(labels = package_labels) +
        labs(title = title, subtitle = subtitle) +
        publication_theme(show_method_labels)
}

time_limits <- range(
    c(classification$total_sec, regression$total_sec),
    na.rm = TRUE
)
memory_limits <- range(
    c(classification$peak_rss_mib, regression$peak_rss_mib),
    na.rm = TRUE
)

panel_a <- heat_panel(
    classification, "accuracy", "A  Classification accuracy",
    "Held-out fraction correct",
    c("#eff6fb", "#78b7d6", "#0a4c86"),
    function(value) sprintf("%.3f", value), limits = c(0, 1)
)
panel_b <- heat_panel(
    regression, "rmsd", "B  Regression RMSD",
    "Held-out root mean squared deviation; lower is better",
    c("#e7f5ee", "#63b59d", "#075b4c"), format_rmsd,
    transform = "log10", show_method_labels = FALSE
)
panel_c <- heat_panel(
    classification, "total_sec", "C  Classification time",
    "Fitting plus held-out prediction (s)",
    c("#fff4dd", "#f3a35c", "#a31316"), format_time,
    transform = "log10", limits = time_limits
)
panel_d <- heat_panel(
    regression, "total_sec", "D  Regression time",
    "Fitting plus held-out prediction (s)",
    c("#fff4dd", "#f3a35c", "#a31316"), format_time,
    transform = "log10", limits = time_limits,
    show_method_labels = FALSE
)
panel_e <- heat_panel(
    classification, "peak_rss_mib", "E  Classification memory",
    "Absolute peak process RSS (MiB)",
    c("#edf7e9", "#74c476", "#005a32"),
    function(value) sprintf("%.0f", value), transform = "log10",
    limits = memory_limits
)
panel_f <- heat_panel(
    regression, "peak_rss_mib", "F  Regression memory",
    "Absolute peak process RSS (MiB)",
    c("#edf7e9", "#74c476", "#005a32"),
    function(value) sprintf("%.0f", value), transform = "log10",
    limits = memory_limits, show_method_labels = FALSE
)

panel_widths <- c(
    length(classification_datasets),
    length(regression_datasets)
)
top_row <- wrap_plots(panel_a, panel_b, nrow = 1L, widths = panel_widths)
time_row <- wrap_plots(panel_c, panel_d, nrow = 1L, widths = panel_widths)
memory_row <- wrap_plots(panel_e, panel_f, nrow = 1L, widths = panel_widths)

figure <- wrap_plots(top_row, time_row, memory_row, ncol = 1L) +
    plot_layout(
        guides = "keep"
    ) +
    plot_annotation(
        title = "Single-CPU PLS prediction workflows",
        subtitle = paste(
            "Ubuntu 22.04, Intel Core i7-13700, one OpenBLAS thread;",
            "matched prepared splits and fixed component contract"
        ),
        theme = theme(
            plot.title = element_text(face = "bold", size = 15),
            plot.subtitle = element_text(size = 9)
        )
    )

dir.create(dirname(args[[2L]]), recursive = TRUE, showWarnings = FALSE)
ggsave(args[[2L]], figure, width = 11.2, height = 7.3, units = "in",
       dpi = 300, bg = "white")
ggsave(args[[3L]], figure, width = 11.2, height = 7.3, units = "in",
       device = cairo_pdf, bg = "white")
