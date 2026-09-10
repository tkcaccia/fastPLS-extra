#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 2L) {
    stop("Usage: plot_selected_matrix.R <summary-dir> <output-dir>")
}
suppressPackageStartupMessages({
    library(ggplot2)
    library(patchwork)
})

dataset_levels <- c(
    "cbmc_citeseq", "ccle", "cifar100", "gtex_v8", "metref", "prism",
    "retina", "tabula", "tcga_brca", "tcga_hnsc_methylation",
    "tcga_pan_cancer"
)
dataset_labels <- c(
    "CBMC CITE-seq", "CCLE", "CIFAR-100", "GTEx v8", "MetRef", "PRISM",
    "Retina", "Tabula Muris", "TCGA-BRCA", "TCGA-HNSC methyl.",
    "TCGA Pan-Cancer"
)
method_levels <- c("plssvd", "simpls", "opls", "kernelpls")
method_labels <- c("PLS-SVD", "SIMPLS", "OPLS", "Linear kernel PLS")

prepare_panel <- function(frame, platform, backend, value) {
    panel <- frame[frame$platform == platform & frame$backend == backend, ]
    grid <- expand.grid(
        dataset = dataset_levels,
        method = method_levels,
        stringsAsFactors = FALSE
    )
    keep <- intersect(names(panel), c(
        "dataset", "method", value, "status", "status_cv", "status_one"
    ))
    panel <- merge(grid, panel[keep], by = c("dataset", "method"), all.x = TRUE)
    panel$dataset <- factor(panel$dataset,
        levels = rev(dataset_levels), labels = rev(dataset_labels))
    panel$method <- factor(panel$method,
        levels = method_levels, labels = method_labels)
    status_column <- intersect(c("status", "status_cv", "status_one"),
        names(panel))
    failed <- rep(FALSE, nrow(panel))
    if (length(status_column)) {
        failed <- !is.na(panel[[status_column[[1L]]]]) &
            panel[[status_column[[1L]]]] == "error"
    }
    panel$label <- ifelse(
        is.finite(panel[[value]]), sprintf("%.2fx", panel[[value]]),
        ifelse(failed, "ERR", "NE")
    )
    panel
}

draw_panel <- function(frame, value, title, subtitle, show_y = TRUE) {
    legend_title <- if (identical(value, "cpu_over_accelerator")) {
        "CPU / accelerator"
    } else {
        "10 x one fold / CV"
    }
    ggplot(frame, aes(x = method, y = dataset, fill = .data[[value]])) +
        geom_tile(color = "white", linewidth = 0.65) +
        geom_text(aes(label = label), size = 2.65) +
        scale_fill_gradient2(
            low = "#b2182b", mid = "#f7f7f7", high = "#2166ac",
            midpoint = 1, trans = "log2", limits = c(1 / 16, 16),
            oob = scales::squish, na.value = "#d9d9d9",
            breaks = c(1 / 16, 1 / 4, 1, 4, 16),
            labels = c("0.06x", "0.25x", "1x", "4x", "16x"),
            name = legend_title
        ) +
        labs(title = title, subtitle = subtitle, x = NULL, y = NULL) +
        theme_minimal(base_size = 9) +
        theme(
            axis.text.x = element_text(angle = 28, hjust = 1),
            axis.text.y = if (show_y) element_text() else element_blank(),
            panel.grid = element_blank(),
            plot.title = element_text(face = "bold", size = 10.5),
            plot.subtitle = element_text(size = 8),
            legend.position = "bottom",
            legend.key.width = grid::unit(2.2, "cm")
        )
}

summary_dir <- normalizePath(args[[1L]], mustWork = TRUE)
output_dir <- normalizePath(args[[2L]], mustWork = FALSE)
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

accelerator <- read.csv(file.path(
    summary_dir, "gpu_cv_cpu_accelerator_comparison.csv"
), stringsAsFactors = FALSE)
cuda <- prepare_panel(accelerator, "linux_nvidia", "cuda",
    "cpu_over_accelerator")
metal <- prepare_panel(accelerator, "mac_apple_silicon", "metal",
    "cpu_over_accelerator")
figure_accelerator <- (
    draw_panel(cuda, "cpu_over_accelerator", "A  CUDA cross-validation",
        "Same-host CPU time / CUDA time") +
    draw_panel(metal, "cpu_over_accelerator", "B  Metal cross-validation",
        "Same-host CPU time / Metal time", show_y = FALSE)
) +
    plot_layout(guides = "collect") +
    plot_annotation(
        title = "GPU backend benefit for ten-fold cross-validation",
        theme = theme(plot.title = element_text(face = "bold", size = 14))
    ) & theme(legend.position = "bottom")
ggsave(file.path(output_dir, "supp_gpu_cv_accelerator_benefit.png"),
    figure_accelerator, width = 11.6, height = 7.3, dpi = 320)
ggsave(file.path(output_dir, "supp_gpu_cv_accelerator_benefit.pdf"),
    figure_accelerator, width = 11.6, height = 7.3, device = cairo_pdf)

naive <- read.csv(file.path(
    summary_dir, "gpu_cv_naive_kfold_comparison.csv"
), stringsAsFactors = FALSE)
panels <- list(
    draw_panel(
        prepare_panel(naive, "linux_nvidia", "cpu", "naive_over_cv"),
        "naive_over_cv", "A  Linux CPU",
        "10 x one-fold fit and prediction / complete CV"
    ),
    draw_panel(
        prepare_panel(naive, "linux_nvidia", "cuda", "naive_over_cv"),
        "naive_over_cv", "B  NVIDIA CUDA",
        "10 x one-fold fit and prediction / complete CV", show_y = FALSE
    ),
    draw_panel(
        prepare_panel(naive, "mac_apple_silicon", "cpu", "naive_over_cv"),
        "naive_over_cv", "C  Mac CPU",
        "10 x one-fold fit and prediction / complete CV"
    ),
    draw_panel(
        prepare_panel(naive, "mac_apple_silicon", "metal", "naive_over_cv"),
        "naive_over_cv", "D  Apple Metal",
        "10 x one-fold fit and prediction / complete CV", show_y = FALSE
    )
)
figure_naive <- wrap_plots(panels, ncol = 2, guides = "collect") +
    plot_annotation(
        title = "Complete cross-validation versus repeated fitting and prediction",
        theme = theme(plot.title = element_text(face = "bold", size = 14))
    ) & theme(legend.position = "bottom")
ggsave(file.path(output_dir, "supp_gpu_cv_vs_repeated_fit.png"),
    figure_naive, width = 11.6, height = 12.0, dpi = 320)
ggsave(file.path(output_dir, "supp_gpu_cv_vs_repeated_fit.pdf"),
    figure_naive, width = 11.6, height = 12.0, device = cairo_pdf)
