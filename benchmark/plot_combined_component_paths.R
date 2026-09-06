#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 3L) {
    stop(
        paste(
            "Usage: plot_combined_component_paths.R",
            "CUDA_RAW METAL_RAW OUTPUT_DIR"
        ),
        call. = FALSE
    )
}
if (!requireNamespace("ggplot2", quietly = TRUE)) {
    stop("The renderer requires ggplot2.", call. = FALSE)
}

cuda_path <- args[[1L]]
metal_path <- args[[2L]]
output_dir <- args[[3L]]
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

read_platform <- function(path, platform, accelerator) {
    values <- read.csv(path, stringsAsFactors = FALSE, check.names = FALSE)
    values <- values[values$status == "success", , drop = FALSE]
    if (!nrow(values)) {
        stop(path, " contains no successful rows.", call. = FALSE)
    }
    if (!all(values$package_version == "0.99.39")) {
        stop(path, " contains a different fastPLS version.", call. = FALSE)
    }
    expected <- c("cpu", accelerator)
    if (!all(values$backend_requested %in% expected) ||
        any(values$backend_requested != values$backend_reported)) {
        stop(path, " violates the requested-backend contract.", call. = FALSE)
    }
    values$Platform <- platform
    values$Route <- ifelse(
        values$backend_requested == "cpu",
        "CPU",
        "Accelerator"
    )
    values
}

raw <- rbind(
    read_platform(cuda_path, "Linux workstation", "cuda"),
    read_platform(metal_path, "Apple M3 workstation", "metal")
)

family_labels <- c(
    plssvd = "PLS-SVD",
    simpls = "SIMPLS",
    opls = "OPLS",
    kernelpls = "Kernel PLS"
)
family_palette <- c(
    "PLS-SVD" = "#1B4965",
    "SIMPLS" = "#D1495B",
    "OPLS" = "#2A9D8F",
    "Kernel PLS" = "#E9A03B"
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
raw$Family <- factor(
    unname(family_labels[raw$method]),
    levels = unname(family_labels)
)
raw$Platform <- factor(
    raw$Platform,
    levels = c("Linux workstation", "Apple M3 workstation")
)
raw$Route <- factor(
    raw$Route,
    levels = c("CPU", "Accelerator")
)

summarize_value <- function(values) {
    values <- values[is.finite(values)]
    if (!length(values)) {
        return(c(median = NA_real_, lower = NA_real_, upper = NA_real_))
    }
    c(
        median = median(values),
        lower = unname(quantile(values, 0.25)),
        upper = unname(quantile(values, 0.75))
    )
}

make_summary <- function(value_column, measure) {
    keys <- unique(raw[c(
        "dataset", "task_type", "Family", "Platform", "Route", "ncomp"
    )])
    rows <- lapply(seq_len(nrow(keys)), function(index) {
        key <- keys[index, , drop = FALSE]
        keep <- rep(TRUE, nrow(raw))
        for (column in names(key)) {
            keep <- keep & raw[[column]] == key[[column]][[1L]]
        }
        statistics <- summarize_value(raw[[value_column]][keep])
        data.frame(
            key,
            Measure = measure,
            median = statistics[["median"]],
            lower = statistics[["lower"]],
            upper = statistics[["upper"]],
            stringsAsFactors = FALSE
        )
    })
    do.call(rbind, rows)
}

metric <- make_summary("metric_value", "Predictive metric")
metric$Measure <- ifelse(
    metric$task_type == "classification",
    "Held-out accuracy",
    "Held-out RMSD"
)
plot_data <- rbind(
    metric,
    make_summary("total_sec", "Fit + prediction time (s)"),
    make_summary("incremental_peak_rss_mb", "Incremental host RSS (MiB)")
)
plot_data$Measure <- factor(
    plot_data$Measure,
    levels = c(
        "Held-out accuracy",
        "Held-out RMSD",
        "Fit + prediction time (s)",
        "Incremental host RSS (MiB)"
    )
)
theme_publication <- function() {
    ggplot2::theme_bw(base_size = 9) +
        ggplot2::theme(
            panel.grid.minor = ggplot2::element_blank(),
            panel.grid.major = ggplot2::element_line(
                colour = "#E4E4E4",
                linewidth = 0.25
            ),
            strip.background = ggplot2::element_rect(
                fill = "#F2F0EA",
                colour = "#B8B8B8"
            ),
            strip.text = ggplot2::element_text(face = "bold", size = 7.5),
            legend.position = "bottom",
            legend.title = ggplot2::element_blank(),
            axis.title = ggplot2::element_text(face = "bold"),
            plot.title = ggplot2::element_text(face = "bold", size = 12),
            plot.subtitle = ggplot2::element_text(size = 8)
        )
}

for (dataset in names(dataset_labels)) {
    values <- plot_data[plot_data$dataset == dataset, , drop = FALSE]
    if (!nrow(values)) {
        stop("Missing component-path data for ", dataset, ".", call. = FALSE)
    }
    figure <- ggplot2::ggplot(
        values,
        ggplot2::aes(x = ncomp, y = median, colour = Family, group = Family)
    ) +
        ggplot2::geom_ribbon(
            ggplot2::aes(ymin = lower, ymax = upper, fill = Family),
            alpha = 0.12,
            colour = NA
        ) +
        ggplot2::geom_line(linewidth = 0.55) +
        ggplot2::geom_point(size = 1.25) +
        ggplot2::facet_grid(
            Platform + Measure ~ Route,
            scales = "free_y",
            drop = TRUE
        ) +
        ggplot2::scale_colour_manual(values = family_palette, drop = FALSE) +
        ggplot2::scale_fill_manual(values = family_palette, drop = FALSE) +
        ggplot2::labs(
            title = paste0(
                dataset_labels[[dataset]],
                ": component-dependent prediction and computation"
            ),
            subtitle = paste(
                "Medians and interquartile ranges from five isolated processes;",
                "accelerator denotes NVIDIA CUDA on Linux and Apple Metal on M3"
            ),
            x = "Number of PLS components",
            y = NULL
        ) +
        theme_publication()
    filename <- file.path(
        output_dir,
        paste0("component_path_", dataset, "_cpu_cuda_metal")
    )
    ggplot2::ggsave(
        paste0(filename, ".png"),
        figure,
        width = 8.0,
        height = 10.0,
        dpi = 320,
        bg = "white"
    )
    ggplot2::ggsave(
        paste0(filename, ".pdf"),
        figure,
        width = 8.0,
        height = 10.0,
        device = grDevices::cairo_pdf,
        bg = "white"
    )
}

write.csv(
    plot_data,
    file.path(output_dir, "component_path_cpu_cuda_metal_plot_data.csv"),
    row.names = FALSE
)
message("Combined component-path figures written to ", output_dir)
