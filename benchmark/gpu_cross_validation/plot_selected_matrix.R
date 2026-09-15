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
    "tcga_pan_cancer", "nmr", "imagenet"
)
dataset_labels <- c(
    "CBMC CITE-seq", "CCLE", "CIFAR-100", "GTEx v8", "MetRef", "PRISM",
    "Retina", "Tabula Muris", "TCGA-BRCA", "TCGA-HNSC methyl.",
    "TCGA Pan-Cancer", "NMR", "ImageNet"
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
    } else if (identical(value, "cv_over_k_fit_predict")) {
        "CV / repeated fits"
    } else {
        "CV / fit + prediction"
    }
    if (identical(value, "cv_over_fit_predict")) {
        frame$fill_value <- log2(frame[[value]])
        fill_scale <- scale_fill_gradient2(
            low = "#2166ac", mid = "#f7f7f7", high = "#b2182b",
            midpoint = log2(10), limits = log2(c(1, 100)),
            oob = scales::squish, na.value = "#d9d9d9",
            breaks = log2(c(1, 2, 5, 10, 20, 50, 100)),
            labels = c("1x", "2x", "5x", "10x", "20x", "50x", "100x"),
            name = legend_title
        )
    } else {
        frame$fill_value <- log2(frame[[value]])
        fill_scale <- scale_fill_gradient2(
            low = "#b2182b", mid = "#f7f7f7", high = "#2166ac",
            midpoint = 0, limits = log2(c(1 / 16, 64)),
            oob = scales::squish, na.value = "#d9d9d9",
            breaks = log2(c(1 / 16, 1 / 4, 1, 4, 16, 64)),
            labels = c("0.06x", "0.25x", "1x", "4x", "16x", "64x"),
            name = legend_title
        )
    }
    ggplot(frame, aes(x = method, y = dataset, fill = fill_value)) +
        geom_tile(color = "white", linewidth = 0.65) +
        geom_text(aes(label = label), size = 2.65) +
        fill_scale +
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
    draw_panel(cuda, "cpu_over_accelerator", "A  Linux CPU and CUDA",
        "Intel CPU time / NVIDIA CUDA time") +
    draw_panel(metal, "cpu_over_accelerator", "B  Mac CPU and Metal",
        "Apple M3 CPU time / hybrid Metal time", show_y = FALSE)
) +
    plot_layout(guides = "collect") +
    plot_annotation(
        title = "CPU-to-GPU runtime ratio for ten-fold cross-validation",
        subtitle = paste(
            "Complete float32 workflows; five fresh processes with fixed",
            "folds, seeds and component counts"
        ),
        theme = theme(
            plot.title = element_text(face = "bold", size = 14),
            plot.subtitle = element_text(size = 9)
        )
    ) & theme(legend.position = "bottom")
ggsave(file.path(output_dir, "supp_gpu_cv_accelerator_benefit.png"),
    figure_accelerator, width = 11.6, height = 7.3, dpi = 320)
ggsave(file.path(output_dir, "supp_gpu_cv_accelerator_benefit.pdf"),
    figure_accelerator, width = 11.6, height = 7.3, device = cairo_pdf)

figure_accelerator_cmpb <- draw_panel(
    cuda, "cpu_over_accelerator", "Linux CPU and NVIDIA CUDA",
    "Intel CPU time / NVIDIA CUDA time"
) +
    plot_annotation(
        title = "CPU-to-CUDA runtime ratio for ten-fold cross-validation",
        subtitle = paste(
            "Complete float32 workflows; five fresh processes with fixed",
            "folds, seeds and component counts"
        )
    ) & theme(legend.position = "bottom")
ggsave(file.path(output_dir, "supp_gpu_cv_accelerator_benefit_cmpb.png"),
    figure_accelerator_cmpb, width = 7.4, height = 7.3, dpi = 320)
ggsave(file.path(output_dir, "supp_gpu_cv_accelerator_benefit_cmpb.pdf"),
    figure_accelerator_cmpb, width = 7.4, height = 7.3, device = cairo_pdf)

figure_accelerator_jss <- draw_panel(
    metal, "cpu_over_accelerator", "Mac CPU and Metal",
    "Apple M3 CPU time / hybrid Metal time"
) +
    plot_annotation(
        title = "CPU-to-Metal runtime ratio for ten-fold cross-validation",
        subtitle = paste(
            "Complete float32 workflows; five fresh processes with fixed",
            "folds, seeds and component counts"
        )
    ) & theme(legend.position = "bottom")
ggsave(file.path(output_dir, "jss_metal_cv_accelerator_benefit.png"),
    figure_accelerator_jss, width = 7.4, height = 7.3, dpi = 320)
ggsave(file.path(output_dir, "jss_metal_cv_accelerator_benefit.pdf"),
    figure_accelerator_jss, width = 7.4, height = 7.3, device = cairo_pdf)

naive <- read.csv(file.path(
    summary_dir, "gpu_cv_fit_predict_comparison.csv"
), stringsAsFactors = FALSE)
panels <- list(
    draw_panel(
        prepare_panel(naive, "linux_nvidia", "cpu", "cv_over_fit_predict"),
        "cv_over_fit_predict", "A  Linux CPU",
        "Ten-fold CV time / one fit plus test prediction"
    ),
    draw_panel(
        prepare_panel(naive, "linux_nvidia", "cuda", "cv_over_fit_predict"),
        "cv_over_fit_predict", "B  NVIDIA CUDA",
        "Ten-fold CV time / one fit plus test prediction", show_y = FALSE
    ),
    draw_panel(
        prepare_panel(naive, "mac_apple_silicon", "cpu", "cv_over_fit_predict"),
        "cv_over_fit_predict", "C  Mac CPU",
        "Ten-fold CV time / one fit plus test prediction"
    ),
    draw_panel(
        prepare_panel(naive, "mac_apple_silicon", "metal", "cv_over_fit_predict"),
        "cv_over_fit_predict", "D  Apple Metal",
        "Ten-fold CV time / one fit plus test prediction", show_y = FALSE
    )
)
figure_naive <- wrap_plots(panels, ncol = 2, guides = "collect") +
    plot_annotation(
        title = "Ten-fold cross-validation cost relative to fitting and prediction",
        subtitle = paste(
            "Score-matched float32 workflows; classification uses argmax and",
            "regression uses continuous predictions"
        ),
        theme = theme(
            plot.title = element_text(face = "bold", size = 14),
            plot.subtitle = element_text(size = 9)
        )
    ) & theme(legend.position = "bottom")
ggsave(file.path(output_dir, "supp_gpu_cv_vs_fit_prediction.png"),
    figure_naive, width = 11.6, height = 12.0, dpi = 320)
ggsave(file.path(output_dir, "supp_gpu_cv_vs_fit_prediction.pdf"),
    figure_naive, width = 11.6, height = 12.0, device = cairo_pdf)

figure_naive_cmpb <- wrap_plots(panels[1:2], ncol = 2, guides = "collect") +
    plot_annotation(
        title = "Ten-fold cross-validation cost on Linux CPU and CUDA",
        subtitle = paste(
            "Score-matched float32 workflows; classification uses argmax and",
            "regression uses continuous predictions"
        )
    ) & theme(legend.position = "bottom")
ggsave(file.path(output_dir, "supp_gpu_cv_vs_fit_prediction_cmpb.png"),
    figure_naive_cmpb, width = 11.6, height = 6.2, dpi = 320)
ggsave(file.path(output_dir, "supp_gpu_cv_vs_fit_prediction_cmpb.pdf"),
    figure_naive_cmpb, width = 11.6, height = 6.2, device = cairo_pdf)

figure_naive_jss <- wrap_plots(panels[3:4], ncol = 2, guides = "collect") +
    plot_annotation(
        title = "Ten-fold cross-validation cost on Mac CPU and Metal",
        subtitle = paste(
            "Score-matched float32 workflows; classification uses argmax and",
            "regression uses continuous predictions"
        )
    ) & theme(legend.position = "bottom")
ggsave(file.path(output_dir, "jss_metal_cv_vs_fit_prediction.png"),
    figure_naive_jss, width = 11.6, height = 6.2, dpi = 320)
ggsave(file.path(output_dir, "jss_metal_cv_vs_fit_prediction.pdf"),
    figure_naive_jss, width = 11.6, height = 6.2, device = cairo_pdf)

efficiency_panels <- list(
    draw_panel(
        prepare_panel(naive, "linux_nvidia", "cpu",
            "cv_over_k_fit_predict"),
        "cv_over_k_fit_predict", "A  Linux CPU",
        "Ten-fold CV time / ten full fits plus test predictions"
    ),
    draw_panel(
        prepare_panel(naive, "linux_nvidia", "cuda",
            "cv_over_k_fit_predict"),
        "cv_over_k_fit_predict", "B  NVIDIA CUDA",
        "Ten-fold CV time / ten full fits plus test predictions",
        show_y = FALSE
    ),
    draw_panel(
        prepare_panel(naive, "mac_apple_silicon", "cpu",
            "cv_over_k_fit_predict"),
        "cv_over_k_fit_predict", "C  Mac CPU",
        "Ten-fold CV time / ten full fits plus test predictions"
    ),
    draw_panel(
        prepare_panel(naive, "mac_apple_silicon", "metal",
            "cv_over_k_fit_predict"),
        "cv_over_k_fit_predict", "D  Apple Metal",
        "Ten-fold CV time / ten full fits plus test predictions",
        show_y = FALSE
    )
)
figure_efficiency <- wrap_plots(
    efficiency_panels, ncol = 2, guides = "collect"
) +
    plot_annotation(
        title = "Ten-fold cross-validation relative to ten repeated workflows",
        subtitle = paste(
            "Values below one indicate that compiled cross-validation is",
            "faster than ten full-data fits and fixed-test predictions"
        ),
        theme = theme(
            plot.title = element_text(face = "bold", size = 14),
            plot.subtitle = element_text(size = 9)
        )
    ) & theme(legend.position = "bottom")
ggsave(file.path(output_dir, "supp_gpu_cv_efficiency_vs_ten_fits.png"),
    figure_efficiency, width = 11.6, height = 12.0, dpi = 320)
ggsave(file.path(output_dir, "supp_gpu_cv_efficiency_vs_ten_fits.pdf"),
    figure_efficiency, width = 11.6, height = 12.0, device = cairo_pdf)
