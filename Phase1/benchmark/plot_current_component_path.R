#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 3L) {
    stop(
        paste(
            "Usage: plot_current_component_path.R",
            "COMPONENT_PATH_RAW ACCELERATOR OUTPUT_DIR"
        ),
        call. = FALSE
    )
}

raw_path <- args[[1L]]
accelerator <- tolower(args[[2L]])
output_dir <- args[[3L]]
if (!accelerator %in% c("cuda", "metal")) {
    stop("ACCELERATOR must be 'cuda' or 'metal'.", call. = FALSE)
}
if (!requireNamespace("ggplot2", quietly = TRUE)) {
    stop("The renderer requires ggplot2.", call. = FALSE)
}

dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
raw <- read.csv(raw_path, stringsAsFactors = FALSE, check.names = FALSE)
raw <- raw[raw$status == "success", , drop = FALSE]
if (!nrow(raw)) {
    stop("The component-path file contains no successful rows.", call. = FALSE)
}

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
raw$Backend <- ifelse(
    raw$backend_requested == "cpu",
    if (accelerator == "cuda") "Linux CPU" else "macOS CPU",
    if (accelerator == "cuda") "NVIDIA CUDA" else "Apple Metal"
)
raw$Backend <- factor(
    raw$Backend,
    levels = if (accelerator == "cuda") {
        c("Linux CPU", "NVIDIA CUDA")
    } else {
        c("macOS CPU", "Apple Metal")
    }
)

quantiles <- function(values) {
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

make_summary <- function(data, value_column, measure) {
    groups <- unique(data[c("dataset", "task_type", "Family", "Backend", "ncomp")])
    rows <- lapply(seq_len(nrow(groups)), function(index) {
        group <- groups[index, , drop = FALSE]
        keep <- data$dataset == group$dataset &
            data$Family == group$Family &
            data$Backend == group$Backend &
            data$ncomp == group$ncomp
        statistics <- quantiles(data[[value_column]][keep])
        data.frame(
            group,
            Measure = measure,
            median = statistics[["median"]],
            lower = statistics[["lower"]],
            upper = statistics[["upper"]],
            stringsAsFactors = FALSE
        )
    })
    do.call(rbind, rows)
}

metric_rows <- make_summary(raw, "metric_value", "Predictive metric")
metric_rows$Measure <- ifelse(
    metric_rows$task_type == "classification",
    "Held-out accuracy",
    "Held-out RMSD"
)
plot_data <- rbind(
    metric_rows,
    make_summary(raw, "total_sec", "Fit + prediction time (s)"),
    make_summary(
        raw,
        "incremental_peak_rss_mb",
        "Incremental peak host RSS (MiB)"
    )
)
plot_data$Measure <- factor(
    plot_data$Measure,
    levels = c(
        "Held-out accuracy",
        "Held-out RMSD",
        "Fit + prediction time (s)",
        "Incremental peak host RSS (MiB)"
    )
)

theme_publication <- function() {
    ggplot2::theme_bw(base_size = 10) +
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
            strip.text = ggplot2::element_text(face = "bold", size = 9),
            legend.position = "bottom",
            legend.title = ggplot2::element_blank(),
            axis.title = ggplot2::element_text(face = "bold"),
            plot.title = ggplot2::element_text(face = "bold", size = 12),
            plot.subtitle = ggplot2::element_text(size = 8.5)
        )
}

pdf_path <- file.path(
    output_dir,
    paste0("component_paths_", accelerator, ".pdf")
)
grDevices::pdf(pdf_path, width = 8.2, height = 8.8, onefile = TRUE)
for (dataset in unique(raw$dataset)) {
    values <- plot_data[plot_data$dataset == dataset, , drop = FALSE]
    figure <- ggplot2::ggplot(
        values,
        ggplot2::aes(x = ncomp, y = median, colour = Family, group = Family)
    ) +
        ggplot2::geom_ribbon(
            ggplot2::aes(ymin = lower, ymax = upper, fill = Family),
            alpha = 0.12,
            colour = NA
        ) +
        ggplot2::geom_line(linewidth = 0.65) +
        ggplot2::geom_point(size = 1.6) +
        ggplot2::facet_grid(Measure ~ Backend, scales = "free_y") +
        ggplot2::scale_colour_manual(values = family_palette, drop = FALSE) +
        ggplot2::scale_fill_manual(values = family_palette, drop = FALSE) +
        ggplot2::labs(
            title = paste0(
                dataset_labels[[dataset]],
                ": component-dependent predictive and computational behavior"
            ),
            subtitle = paste(
                "Medians and interquartile ranges from five fresh processes;",
                "rSVD uses automatic controls and a fresh initialization"
            ),
            x = "Number of PLS components",
            y = NULL
        ) +
        theme_publication()
    print(figure)
    ggplot2::ggsave(
        file.path(output_dir, paste0("component_path_", dataset, "_", accelerator,
                                    ".png")),
        figure,
        width = 8.2,
        height = 8.8,
        dpi = 320,
        bg = "white"
    )
}
grDevices::dev.off()

correlation_data <- rbind(
    transform(raw, measure = "predictive_metric", value = metric_value),
    transform(raw, measure = "total_sec", value = total_sec),
    transform(
        raw,
        measure = "incremental_peak_host_rss_mib",
        value = incremental_peak_rss_mb
    )
)
keys <- unique(correlation_data[c(
    "dataset", "task_type", "method", "backend_requested", "measure"
)])
correlations <- lapply(seq_len(nrow(keys)), function(index) {
    key <- keys[index, , drop = FALSE]
    keep <- rep(TRUE, nrow(correlation_data))
    for (column in names(key)) {
        keep <- keep & correlation_data[[column]] == key[[column]][[1L]]
    }
    values <- correlation_data[keep, , drop = FALSE]
    complete <- is.finite(values$ncomp) & is.finite(values$value)
    coefficient <- if (sum(complete) >= 3L &&
        length(unique(values$ncomp[complete])) >= 2L) {
        suppressWarnings(cor(
            values$ncomp[complete],
            values$value[complete],
            method = "spearman"
        ))
    } else {
        NA_real_
    }
    data.frame(
        key,
        n_observations = sum(complete),
        n_component_values = length(unique(values$ncomp[complete])),
        spearman_rho = coefficient,
        stringsAsFactors = FALSE
    )
})
correlations <- do.call(rbind, correlations)
write.csv(
    correlations,
    file.path(output_dir, paste0("component_path_correlations_", accelerator,
                                 ".csv")),
    row.names = FALSE
)
write.csv(
    plot_data,
    file.path(output_dir, paste0("component_path_plot_data_", accelerator,
                                 ".csv")),
    row.names = FALSE
)

message("Component-path figures written to ", output_dir)
