#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 3L) {
    stop(
        "Usage: plot_pls_package_comparison_current.R SUMMARY STATUS OUT_PREFIX",
        call. = FALSE
    )
}

summary_file <- args[[1L]]
status_file <- args[[2L]]
out_prefix <- args[[3L]]

suppressPackageStartupMessages({
    library(ggplot2)
    library(patchwork)
})

summary <- read.csv(summary_file, check.names = FALSE, stringsAsFactors = FALSE)
status <- read.csv(status_file, check.names = FALSE, stringsAsFactors = FALSE)
repetition_counts <- sort(unique(status$reps_attempted[is.finite(status$reps_attempted)]))
repetition_label <- if (length(repetition_counts)) {
    paste(repetition_counts, collapse = "/")
} else {
    "recorded"
}

method_labels <- c(
    fastPLS_simpls_cpu_irlba = "fastPLS SIMPLS / argmax",
    fastPLS_simpls_cpu_irlba_lda = "fastPLS SIMPLS / LDA",
    pls_simpls_fit = "pls / SIMPLS",
    plsgenomics_pls_lda = "plsgenomics / PLS-LDA",
    mdatools_plsda_or_pls = "mdatools / PLS-DA",
    plsdepot_simpls = "plsdepot / SIMPLS",
    pcv_simpls = "pcv / SIMPLS",
    chemometrics_pls_eigen = "chemometrics / PLS eigen",
    mixOmics_plsda = "mixOmics / PLS-DA",
    spls_splsda = "spls / sPLS-DA"
)
dataset_labels <- c(
    ccle = "CCLE",
    cifar100 = "CIFAR-100",
    gtex_v8 = "GTEx v8",
    metref = "MetRef",
    retina = "Retina",
    tabula = "Tabula Muris",
    tcga_brca = "TCGA-BRCA",
    tcga_hnsc_methylation = "TCGA-HNSC methyl.",
    tcga_pan_cancer = "TCGA Pan-Cancer"
)

grid <- expand.grid(
    method_id = names(method_labels),
    dataset = names(dataset_labels),
    stringsAsFactors = FALSE
)
keep_summary <- summary[summary$method_id %in% names(method_labels) &
    summary$dataset %in% names(dataset_labels), , drop = FALSE]
keep_status <- status[status$method_id %in% names(method_labels) &
    status$dataset %in% names(dataset_labels), , drop = FALSE]

data <- merge(grid, keep_summary, by = c("method_id", "dataset"), all.x = TRUE)
data <- merge(
    data,
    keep_status[, c("method_id", "dataset", "reps_attempted", "reps_ok",
                    "n_timeout", "n_error", "n_skipped")],
    by = c("method_id", "dataset"), all.x = TRUE, suffixes = c("", "_status")
)
data$method_label <- factor(
    unname(method_labels[data$method_id]),
    levels = rev(unname(method_labels))
)
data$dataset_label <- factor(
    unname(dataset_labels[data$dataset]),
    levels = unname(dataset_labels)
)
data$status_label <- ifelse(
    is.finite(data$median_metric), "",
    ifelse(data$n_timeout > 0, "TO", ifelse(data$n_error > 0, "ERR", "NE"))
)
data$time_sec <- data$median_time_ms / 1000

tile_plot <- function(value, label, title, palette, trans = "identity", limits = NULL) {
    ggplot(data, aes(dataset_label, method_label, fill = .data[[value]])) +
        geom_tile(color = "white", linewidth = 0.65) +
        geom_text(aes(label = ifelse(nzchar(status_label), status_label, .data[[label]])),
                  size = 2.35, color = "black") +
        scale_fill_gradient(
            low = palette[[1L]], high = palette[[2L]], trans = trans,
            limits = limits, na.value = "#D9D9D9", name = NULL
        ) +
        labs(title = title, x = NULL, y = NULL) +
        theme_minimal(base_size = 9) +
        theme(
            panel.grid = element_blank(),
            plot.title = element_text(face = "bold", size = 10.5),
            axis.text.x = element_text(angle = 28, hjust = 1, size = 7.6),
            axis.text.y = element_text(size = 7.5),
            legend.position = "right",
            plot.margin = margin(3, 4, 3, 4)
        )
}

data$accuracy_label <- ifelse(is.finite(data$median_accuracy),
                              sprintf("%.3f", data$median_accuracy), "")
data$time_label <- ifelse(is.finite(data$time_sec),
                          ifelse(data$time_sec < 10, sprintf("%.2f", data$time_sec),
                                 sprintf("%.0f", data$time_sec)), "")
data$rss_label <- ifelse(is.finite(data$median_peak_host_rss_mb),
                         sprintf("%.0f", data$median_peak_host_rss_mb), "")

p_accuracy <- tile_plot(
    "median_accuracy", "accuracy_label", "A  Held-out accuracy",
    c("#EAF2F8", "#2166AC"), limits = c(0.6, 1)
)
p_time <- tile_plot(
    "time_sec", "time_label", "B  Total fitting plus prediction time (s)",
    c("#FFF5EB", "#CB181D"), trans = "log10"
)
p_memory <- tile_plot(
    "median_peak_host_rss_mb", "rss_label", "C  Complete-process peak host RSS (MiB)",
    c("#EDF8E9", "#006D2C"), trans = "log10"
)

combined <- p_accuracy / p_time / p_memory +
    plot_annotation(
        title = "Single-CPU SIMPLS classification workflows",
        subtitle = paste0(
            "fastPLS 0.99.39 and independent R implementations; float64 inputs, one effective BLAS thread,\n",
            "fixed splits and dataset-specific component counts; ",
            repetition_label, " fresh processes per completed method-dataset pair"
        ),
        caption = "NE, not evaluated; TO, timeout; ERR, execution error."
    ) &
    theme(
        plot.title = element_text(face = "bold", size = 14),
        plot.subtitle = element_text(size = 9.5),
        plot.caption = element_text(size = 8, hjust = 0)
    )

dir.create(dirname(out_prefix), recursive = TRUE, showWarnings = FALSE)
ggsave(paste0(out_prefix, ".png"), combined, width = 9.2, height = 13.0, dpi = 320)
ggsave(paste0(out_prefix, ".pdf"), combined, width = 9.2, height = 13.0)
write.csv(data, paste0(out_prefix, "_plotted_values.csv"), row.names = FALSE)
