#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 3L) {
    stop(
        paste(
            "Usage: build_figure2_with_cv.R",
            "FIGURE2_RATIOS.csv CV_COMPARISON.csv OUTPUT_DIR"
        ),
        call. = FALSE
    )
}

suppressPackageStartupMessages({
    library(ggplot2)
    library(patchwork)
})

ratio_path <- normalizePath(args[[1L]], mustWork = TRUE)
cv_path <- normalizePath(args[[2L]], mustWork = TRUE)
output_dir <- normalizePath(args[[3L]], mustWork = FALSE)
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

dataset_order <- c(
    "ccle", "cifar100", "gtex_v8", "metref", "retina", "tabula",
    "tcga_brca", "tcga_hnsc_methylation", "tcga_pan_cancer",
    "cbmc_citeseq", "prism", "nmr", "imagenet"
)
dataset_labels <- c(
    ccle = "CCLE", cifar100 = "CIFAR-100", gtex_v8 = "GTEx v8",
    metref = "MetRef", retina = "Retina", tabula = "Tabula Muris",
    tcga_brca = "TCGA-BRCA",
    tcga_hnsc_methylation = "TCGA-HNSC methyl.",
    tcga_pan_cancer = "TCGA Pan-Cancer",
    cbmc_citeseq = "CBMC CITE-seq", prism = "PRISM", nmr = "NMR",
    imagenet = "ImageNet/DINOv2"
)
family_order <- c("plssvd", "simpls", "opls", "kernelpls")
family_labels <- c(
    plssvd = "PLS-SVD", simpls = "SIMPLS-family", opls = "OPLS",
    kernelpls = "linear kernel PLS"
)

complete_grid <- function(data, family_column = "family") {
    names(data)[names(data) == family_column] <- "family"
    grid <- expand.grid(
        dataset = dataset_order,
        family = family_order,
        stringsAsFactors = FALSE
    )
    merge(grid, data, by = c("dataset", "family"), all.x = TRUE)
}

prepare_axes <- function(data) {
    data$dataset_label <- factor(
        data$dataset,
        levels = rev(dataset_order),
        labels = rev(unname(dataset_labels[dataset_order]))
    )
    data$family_label <- factor(
        data$family,
        levels = family_order,
        labels = unname(family_labels[family_order])
    )
    data
}

theme_panel <- function(show_y = TRUE) {
    theme_minimal(base_size = 7.2, base_family = "Helvetica") +
        theme(
            axis.text.x = element_text(angle = 28, hjust = 1, size = 6.5),
            axis.text.y = if (show_y) element_text(size = 6.5) else element_blank(),
            panel.grid = element_blank(),
            plot.title = element_text(face = "bold", size = 9),
            plot.subtitle = element_text(size = 6.8),
            legend.position = "bottom",
            legend.title = element_text(face = "bold", size = 6.5),
            legend.text = element_text(size = 6),
            legend.key.width = grid::unit(1.15, "cm"),
            plot.margin = margin(3, 5, 3, 3)
        )
}

ratio_panel <- function(data, value, title, subtitle, memory = FALSE,
                        show_y = TRUE) {
    data <- prepare_axes(complete_grid(data))
    data$value <- data[[value]]
    data$fill_value <- ifelse(
        is.finite(data$value) & data$value > 0,
        log2(data$value),
        NA_real_
    )
    data$label <- ifelse(
        is.finite(data$value) & data$value > 0,
        sprintf("%.2fx", data$value),
        "NE"
    )
    ggplot(data, aes(family_label, dataset_label, fill = fill_value)) +
        geom_tile(colour = "white", linewidth = 0.45) +
        geom_text(aes(label = label), size = 1.85) +
        scale_fill_gradient2(
            low = if (memory) "#2166ac" else "#b2182b",
            mid = "#f7f7f7",
            high = if (memory) "#b2182b" else "#2166ac",
            midpoint = 0,
            na.value = "#d9d9d9",
            name = if (memory) "log2 CUDA/CPU" else "log2 CPU/CUDA"
        ) +
        labs(title = title, subtitle = subtitle, x = NULL, y = NULL) +
        theme_panel(show_y)
}

cv_panel <- function(data, backend, title, show_y = TRUE) {
    data <- data[
        data$platform == "linux_nvidia" & data$backend == backend,
        , drop = FALSE
    ]
    data <- prepare_axes(complete_grid(data, "method"))
    data$value <- data$cv_over_fit_predict
    data$fill_value <- ifelse(
        is.finite(data$value) & data$value > 0,
        log2(data$value),
        NA_real_
    )
    partial <- !is.na(data$status_cv) & data$status_cv == "partial"
    timed_out <- !is.na(data$status_cv) & data$status_cv == "timeout"
    failed <- !is.na(data$status_cv) & data$status_cv == "error"
    data$label <- ifelse(
        is.finite(data$value) & data$value > 0,
        paste0(sprintf("%.2fx", data$value), ifelse(partial, "*", "")),
        ifelse(timed_out, "TO", ifelse(failed, "ERR", "NE"))
    )
    ggplot(data, aes(family_label, dataset_label, fill = fill_value)) +
        geom_tile(colour = "white", linewidth = 0.45) +
        geom_text(aes(label = label), size = 1.85) +
        scale_fill_gradient2(
            low = "#2166ac", mid = "#f7f7f7", high = "#b2182b",
            midpoint = log2(10), limits = log2(c(0.25, 100)),
            oob = scales::squish, na.value = "#d9d9d9",
            breaks = log2(c(0.25, 0.5, 1, 2, 5, 10, 20, 50, 100)),
            labels = c(
                "0.25x", "0.5x", "1x", "2x", "5x", "10x", "20x",
                "50x", "100x"
            ),
            name = "CV / fit + prediction"
        ) +
        labs(
            title = title,
            subtitle = "10-fold CV / one full-training fit + test prediction",
            x = NULL,
            y = NULL
        ) +
        theme_panel(show_y)
}

ratios <- read.csv(ratio_path, stringsAsFactors = FALSE)
ratios <- ratios[
    ratios$accelerator == "CUDA" &
        ratios$platform == "Intel/NVIDIA workstation",
    , drop = FALSE
]
cv <- read.csv(cv_path, stringsAsFactors = FALSE)
if (!"classifier" %in% names(cv)) {
    stop("CV comparison must record the classification head.", call. = FALSE)
}
if (any(!cv$classifier %in% c("lda", "regression"))) {
    stop("Figure 2C-D require LDA classification and regression rows only.",
        call. = FALSE)
}

panels <- list(
    ratio_panel(
        ratios, "runtime_ratio", "A  Fitting and prediction runtime",
        "CPU time / CUDA time; values above 1 favour CUDA"
    ),
    ratio_panel(
        ratios, "host_memory_ratio", "B  Incremental host memory",
        "CUDA RSS increase / CPU RSS increase; values below 1 favour CUDA",
        memory = TRUE,
        show_y = FALSE
    ),
    cv_panel(cv, "cpu", "C  Linux CPU cross-validation"),
    cv_panel(cv, "cuda", "D  NVIDIA CUDA cross-validation", show_y = FALSE)
)

figure <- wrap_plots(panels, ncol = 2, guides = "keep") +
    plot_annotation(
        title = "Float32 CPU and CUDA execution across PLS workflows",
        subtitle = paste0(
            "Matched Intel Core i7-13700 and NVIDIA RTX 5060 Ti runs\n",
            "Panels A-B use argmax; panels C-D retain LDA scores; ",
            "* denotes incomplete repetitions"
        ),
        theme = theme(
            plot.title = element_text(face = "bold", size = 13),
            plot.subtitle = element_text(size = 8)
        )
    )

ggsave(
    file.path(output_dir, "figure2_backend_and_cv.png"),
    figure,
    width = 8.0,
    height = 10.0,
    units = "in",
    dpi = 360,
    bg = "white"
)
ggsave(
    file.path(output_dir, "figure2_backend_and_cv.pdf"),
    figure,
    width = 8.0,
    height = 10.0,
    units = "in",
    device = cairo_pdf,
    bg = "white"
)
