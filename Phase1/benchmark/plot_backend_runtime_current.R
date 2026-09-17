#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 3L) {
    stop(
        "Usage: plot_backend_runtime_current.R CUDA_PAIRED METAL_PAIRED OUT_PREFIX",
        call. = FALSE
    )
}

cuda_file <- args[[1L]]
metal_file <- args[[2L]]
out_prefix <- args[[3L]]

suppressPackageStartupMessages({
    library(ggplot2)
    library(grid)
})

read_backend <- function(path, backend) {
    x <- read.csv(path, check.names = FALSE, stringsAsFactors = FALSE)
    x <- x[x$accelerator == backend, , drop = FALSE]
    x$backend_label <- if (backend == "cuda") "NVIDIA CUDA" else "Apple Metal"
    x
}

data <- rbind(
    read_backend(cuda_file, "cuda"),
    read_backend(metal_file, "metal")
)
data$backend_label <- factor(
    data$backend_label,
    levels = c("NVIDIA CUDA", "Apple Metal")
)
data <- data[is.finite(data$cpu_accelerator_ratio) &
    data$cpu_accelerator_ratio > 0, , drop = FALSE]

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
method_labels <- c(
    plssvd = "PLS-SVD",
    simpls = "SIMPLS",
    opls = "OPLS",
    kernelpls = "Kernel PLS"
)

data$dataset_label <- unname(dataset_labels[data$dataset])
data$method_label <- unname(method_labels[data$method])
data$dataset_label <- factor(
    data$dataset_label,
    levels = rev(unname(dataset_labels))
)
data$method_label <- factor(data$method_label, levels = unname(method_labels))
data$log2_ratio <- log2(data$cpu_accelerator_ratio)
data$ratio_label <- sprintf("%.2fx", data$cpu_accelerator_ratio)

limit <- max(abs(data$log2_ratio), na.rm = TRUE)
limit <- max(limit, 1)

plot <- ggplot(data, aes(method_label, dataset_label, fill = log2_ratio)) +
    geom_tile(color = "white", linewidth = 0.8) +
    geom_text(aes(label = ratio_label), size = 2.65, color = "black") +
    facet_wrap(~backend_label, nrow = 1L) +
    scale_fill_gradient2(
        low = "#B9363E", mid = "#F5F0E6", high = "#2166AC",
        midpoint = 0, limits = c(-limit, limit),
        name = "CPU / accelerator\nruntime ratio",
        breaks = log2(c(0.1, 0.25, 0.5, 1, 2, 4, 10)),
        labels = c("0.1x", "0.25x", "0.5x", "1x", "2x", "4x", "10x")
    ) +
    labs(
        title = "Runtime comparison across PLS families and accelerator backends",
        subtitle = paste(
            "Cell values are median CPU time divided by accelerator time;",
            "values above 1 favor the accelerator"
        ),
        x = NULL,
        y = NULL
    ) +
    coord_fixed(ratio = 0.52) +
    theme_minimal(base_size = 10) +
    theme(
        panel.grid = element_blank(),
        strip.text = element_text(face = "bold", size = 10.5),
        plot.title = element_text(face = "bold", size = 13),
        plot.subtitle = element_text(size = 9.5),
        axis.text.x = element_text(angle = 28, hjust = 1),
        axis.text.y = element_text(size = 8.5),
        legend.position = "right",
        plot.margin = margin(8, 8, 8, 8)
    ) +
    guides(fill = guide_colorbar(
        title.position = "top",
        barheight = unit(4.5, "cm"),
        barwidth = unit(0.45, "cm")
    ))

dir.create(dirname(out_prefix), recursive = TRUE, showWarnings = FALSE)
ggsave(paste0(out_prefix, ".png"), plot, width = 11, height = 7.5, dpi = 320)
ggsave(paste0(out_prefix, ".pdf"), plot, width = 11, height = 7.5)

write.csv(
    data[, c(
        "accelerator", "dataset", "method", "ncomp", "cpu_total_sec",
        "accelerator_total_sec", "cpu_accelerator_ratio", "metric_delta",
        "prediction_agreement", "cpu_incremental_rss_mb",
        "accelerator_incremental_rss_mb"
    )],
    paste0(out_prefix, "_plotted_values.csv"),
    row.names = FALSE
)
