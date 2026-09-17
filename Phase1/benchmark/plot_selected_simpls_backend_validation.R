#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 3L) {
    stop(
        paste(
            "Usage: plot_selected_simpls_backend_validation.R",
            "CUDA_PAIRED METAL_PAIRED OUT_PREFIX"
        ),
        call. = FALSE
    )
}

suppressPackageStartupMessages({
    library(ggplot2)
    library(patchwork)
})

read_pairs <- function(path, accelerator) {
    values <- read.csv(path, check.names = FALSE, stringsAsFactors = FALSE)
    values <- values[
        values$method == "simpls" & values$accelerator == accelerator,
        ,
        drop = FALSE
    ]
    values$accelerator_label <- if (accelerator == "cuda") {
        "NVIDIA CUDA"
    } else {
        "Apple Metal"
    }
    values
}

values <- rbind(
    read_pairs(args[[1L]], "cuda"),
    read_pairs(args[[2L]], "metal")
)

dataset_labels <- c(
    cbmc_citeseq = "CBMC CITE-seq",
    ccle = "CCLE",
    cifar100 = "CIFAR-100",
    gtex_v8 = "GTEx v8",
    metref = "MetRef",
    prism = "PRISM",
    retina = "Retina",
    tabula = "Tabula Muris",
    tcga_brca = "TCGA-BRCA",
    tcga_hnsc_methylation = "TCGA-HNSC methylation",
    tcga_pan_cancer = "TCGA Pan-Cancer"
)
values$dataset_label <- factor(
    unname(dataset_labels[values$dataset]),
    levels = unname(dataset_labels)
)
values$accelerator_label <- factor(
    values$accelerator_label,
    levels = c("NVIDIA CUDA", "Apple Metal")
)
values$runtime_ratio <- values$cpu_total_sec / values$accelerator_total_sec
values$memory_ratio <- values$cpu_incremental_rss_mb /
    values$accelerator_incremental_rss_mb
values$relative_metric_difference <- abs(values$metric_delta) /
    pmax(abs(values$metric_cpu), .Machine$double.eps)
values$relative_metric_difference <- pmax(
    values$relative_metric_difference,
    .Machine$double.eps
)

heat_panel <- function(data, field, title, label_function, limits = NULL) {
    plot_data <- data[is.finite(data[[field]]), , drop = FALSE]
    plot_data$plot_value <- plot_data[[field]]
    plot_data$cell_label <- label_function(plot_data$plot_value)
    plot <- ggplot(
        plot_data,
        aes(dataset_label, accelerator_label, fill = plot_value)
    ) +
        geom_tile(color = "white", linewidth = 0.8) +
        geom_text(aes(label = cell_label), size = 2.8) +
        labs(title = title, x = NULL, y = NULL) +
        theme_minimal(base_size = 9) +
        theme(
            panel.grid = element_blank(),
            plot.title = element_text(face = "bold", size = 10),
            axis.text.x = element_text(angle = 35, hjust = 1, size = 7.5),
            axis.text.y = element_text(size = 8),
            legend.position = "right"
        )
    if (field %in% c("runtime_ratio", "memory_ratio")) {
        plot <- plot + scale_fill_gradient2(
            low = "#B9363E",
            mid = "#F5F0E6",
            high = "#2166AC",
            midpoint = 1,
            trans = "log10",
            name = "CPU / accelerator"
        )
    } else if (field == "prediction_agreement") {
        plot <- plot + scale_fill_gradient(
            low = "#F1B6A8",
            high = "#1B7837",
            limits = limits,
            name = "Agreement"
        )
    } else {
        plot <- plot + scale_fill_gradient(
            low = "#F7FBFF",
            high = "#CB181D",
            trans = "log10",
            name = "Relative difference"
        )
    }
    plot
}

runtime_plot <- heat_panel(
    values,
    "runtime_ratio",
    "A  CPU/accelerator runtime ratio",
    function(x) sprintf("%.2fx", x)
)
memory_plot <- heat_panel(
    values,
    "memory_ratio",
    "B  CPU/accelerator incremental-RSS ratio",
    function(x) sprintf("%.2fx", x)
)
agreement_plot <- heat_panel(
    values,
    "prediction_agreement",
    "C  Prediction agreement with matched CPU fit",
    function(x) sprintf("%.4f", x),
    limits = c(min(values$prediction_agreement, na.rm = TRUE), 1)
)
metric_plot <- heat_panel(
    values,
    "relative_metric_difference",
    "D  Relative predictive-metric difference",
    function(x) format(x, digits = 2, scientific = TRUE)
)

combined <- (runtime_plot / memory_plot / agreement_plot / metric_plot) +
    plot_annotation(
        title = "Selected SIMPLS-rSVD workflows across CPU and accelerator backends",
        subtitle = paste(
            "Matched split and component count; all values use fastPLS 0.99.39",
            "and three isolated repetitions"
        ),
        theme = theme(
            plot.title = element_text(face = "bold", size = 14),
            plot.subtitle = element_text(size = 10)
        )
    )

out_prefix <- args[[3L]]
dir.create(dirname(out_prefix), recursive = TRUE, showWarnings = FALSE)
ggsave(paste0(out_prefix, ".png"), combined, width = 12, height = 10, dpi = 320)
ggsave(paste0(out_prefix, ".pdf"), combined, width = 12, height = 10)
write.csv(
    values[, c(
        "package_version", "accelerator", "dataset", "method", "ncomp",
        "runtime_ratio", "memory_ratio", "prediction_agreement",
        "relative_metric_difference"
    )],
    paste0(out_prefix, "_plotted_values.csv"),
    row.names = FALSE
)
