#!/usr/bin/env Rscript

suppressPackageStartupMessages({
    library(ggplot2)
    library(patchwork)
})

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 4L) {
    stop(
        paste(
            "Usage: build_figures.R LINUX_FLOAT32 LINUX_FLOAT64",
            "MAC_FLOAT32 MAC_FLOAT64"
        ),
        call. = FALSE
    )
}

dataset_order <- c(
    "ccle", "cifar100", "gtex_v8", "metref", "retina", "tabula",
    "tcga_brca", "tcga_hnsc_methylation", "tcga_pan_cancer",
    "cbmc_citeseq", "prism", "nmr", "imagenet"
)
dataset_labels <- c(
    ccle = "CCLE", cifar100 = "CIFAR-100", gtex_v8 = "GTEx v8",
    metref = "MetRef", retina = "Retina", tabula = "Tabula Muris",
    tcga_brca = "TCGA-BRCA",
    tcga_hnsc_methylation = "TCGA-HNSC methylation",
    tcga_pan_cancer = "TCGA Pan-Cancer",
    cbmc_citeseq = "CBMC CITE-seq", prism = "PRISM", nmr = "NMR",
    imagenet = "ImageNet/DINOv2"
)
family_order <- c("plssvd", "simpls", "opls", "kernelpls")
family_labels <- c(
    plssvd = "PLS-SVD", simpls = "SIMPLS", opls = "OPLS",
    kernelpls = "linear kernel PLS"
)

read_runs <- function(path, platform, precision) {
    value <- read.csv(path, check.names = FALSE, na.strings = c("", "NA"))
    value$platform <- platform
    value$precision <- precision
    value
}

linux32 <- read_runs(args[[1L]], "Linux", "float32")
linux64 <- read_runs(args[[2L]], "Linux", "float64")
mac32 <- read_runs(args[[3L]], "macOS", "float32")
mac64 <- read_runs(args[[4L]], "macOS", "float64")

linux32 <- linux32[linux32$backend %in% c("cpu", "cuda"), ]
linux64 <- linux64[linux64$backend %in% c("cpu", "cuda"), ]
mac32 <- mac32[mac32$backend == "cpu", ]
mac64 <- mac64[mac64$backend == "cpu", ]
runs <- rbind(linux32, linux64, mac32, mac64)

if (any(runs$status != "success")) {
    stop("Every matched precision run must complete successfully.", call. = FALSE)
}
run_keys <- c(
    "platform", "backend", "dataset", "family", "requested_ncomp",
    "precision", "replicate"
)
if (anyDuplicated(runs[run_keys])) {
    stop("Duplicate matched precision runs were detected.", call. = FALSE)
}

keys <- c(
    "platform", "backend", "dataset", "family", "requested_ncomp",
    "precision"
)
groups <- split(runs, interaction(runs[keys], drop = TRUE))
summary <- do.call(rbind, lapply(groups, function(block) {
    completed <- block[block$status == "success", , drop = FALSE]
    if (!nrow(completed)) {
        return(data.frame(
            platform = block$platform[[1L]], backend = block$backend[[1L]],
            dataset = block$dataset[[1L]], family = block$family[[1L]],
            ncomp = block$requested_ncomp[[1L]],
            precision = block$precision[[1L]], repetitions = 0L,
            total_sec_median = NA_real_, peak_rss_mib_median = NA_real_,
            metric_name = block$metric_name[[1L]], metric_median = NA_real_
        ))
    }
    data.frame(
        platform = completed$platform[[1L]],
        backend = completed$backend[[1L]],
        dataset = completed$dataset[[1L]],
        family = completed$family[[1L]],
        ncomp = completed$requested_ncomp[[1L]],
        precision = completed$precision[[1L]],
        repetitions = nrow(completed),
        total_sec_median = median(completed$total_sec),
        peak_rss_mib_median = median(completed$peak_rss_mib),
        metric_name = completed$metric_name[[1L]],
        metric_median = median(completed$metric_value),
        stringsAsFactors = FALSE
    )
}))

single <- summary[summary$precision == "float32", ]
double <- summary[summary$precision == "float64", ]
pair_keys <- c(
    "platform", "backend", "dataset", "family", "ncomp", "metric_name"
)
paired <- merge(
    single, double, by = pair_keys,
    suffixes = c("_float32", "_float64"), all = TRUE
)
paired$runtime_ratio <- paired$total_sec_median_float64 /
    paired$total_sec_median_float32
paired$absolute_peak_rss_ratio <- paired$peak_rss_mib_median_float32 /
    paired$peak_rss_mib_median_float64
paired$metric_difference <- paired$metric_median_float32 -
    paired$metric_median_float64

expected_cells <- length(dataset_order) * length(family_order) * 3L
if (nrow(paired) != expected_cells ||
        any(paired$repetitions_float32 != 3L) ||
        any(paired$repetitions_float64 != 3L)) {
    stop(
        "The precision panel is incomplete or has an invalid repetition count.",
        call. = FALSE
    )
}

output_dir <- dirname(normalizePath(args[[2L]], mustWork = TRUE))
write.csv(
    summary, file.path(output_dir, "precision_selected_summary.csv"),
    row.names = FALSE, na = ""
)
write.csv(
    paired, file.path(output_dir, "precision_selected_ratios.csv"),
    row.names = FALSE, na = ""
)

complete_grid <- expand.grid(
    platform_backend = c("Linux CPU", "Linux CUDA", "macOS CPU"),
    dataset = dataset_order,
    family = family_order,
    stringsAsFactors = FALSE
)
paired$platform_backend <- paste(
    paired$platform, toupper(paired$backend)
)
plot_data <- merge(
    complete_grid, paired,
    by = c("platform_backend", "dataset", "family"), all.x = TRUE
)

theme_publication <- function() {
    theme_minimal(base_size = 9, base_family = "Helvetica") +
        theme(
            plot.title = element_text(face = "bold", size = 10),
            plot.subtitle = element_text(size = 8.2),
            axis.text = element_text(colour = "grey15"),
            axis.text.x = element_text(angle = 25, hjust = 1),
            panel.grid = element_blank(),
            legend.position = "bottom",
            legend.title = element_text(face = "bold")
        )
}

ratio_panel <- function(data, panel, field, title, subtitle, fill_limit) {
    current <- data[data$platform_backend == panel, , drop = FALSE]
    current$dataset_label <- factor(
        current$dataset, levels = rev(dataset_order),
        labels = rev(unname(dataset_labels[dataset_order]))
    )
    current$family_label <- factor(
        current$family, levels = family_order,
        labels = unname(family_labels[family_order])
    )
    current$value <- current[[field]]
    current$label <- ifelse(
        is.finite(current$value), sprintf("%.2fx", current$value), "NE"
    )
    ggplot(current, aes(family_label, dataset_label, fill = log2(value))) +
        geom_tile(colour = "white", linewidth = 0.55) +
        geom_text(aes(label = label), size = 2.25) +
        scale_fill_gradient2(
            low = "#B2182B", mid = "#F7F7F7", high = "#2166AC",
            midpoint = 0, limits = c(-fill_limit, fill_limit),
            oob = scales::squish, na.value = "#D9D9D9", name = "log2 ratio"
        ) +
        labs(title = title, subtitle = subtitle, x = NULL, y = NULL) +
        theme_publication()
}

runtime_fill_limit <- max(abs(log2(plot_data$runtime_ratio)), na.rm = TRUE)
memory_fill_limit <- max(
    abs(log2(plot_data$absolute_peak_rss_ratio)), na.rm = TRUE
)

runtime_panels <- list(
    ratio_panel(
        plot_data, "Linux CPU", "runtime_ratio", "A  Linux CPU",
        "float64/float32 total runtime; values above 1 favour float32",
        runtime_fill_limit
    ),
    ratio_panel(
        plot_data, "Linux CUDA", "runtime_ratio", "B  Linux CUDA",
        "float64/float32 total runtime; values above 1 favour float32",
        runtime_fill_limit
    ),
    ratio_panel(
        plot_data, "macOS CPU", "runtime_ratio", "C  macOS CPU",
        "float64/float32 total runtime; values above 1 favour float32",
        runtime_fill_limit
    ),
    plot_spacer()
)
runtime <- wrap_plots(runtime_panels, ncol = 2, guides = "collect") +
    plot_annotation(
        title = "Float32 runtime effect across selected PLS workloads",
        subtitle = paste(
            "Matched inputs, component counts and predictions;",
            "medians of three fresh processes"
        )
    ) & theme(legend.position = "bottom")

memory_panels <- list(
    ratio_panel(
        plot_data, "Linux CPU", "absolute_peak_rss_ratio", "A  Linux CPU",
        "float32/float64 absolute peak RSS; values below 1 favour float32",
        memory_fill_limit
    ),
    ratio_panel(
        plot_data, "Linux CUDA", "absolute_peak_rss_ratio", "B  Linux CUDA",
        "float32/float64 absolute peak RSS; values below 1 favour float32",
        memory_fill_limit
    ),
    ratio_panel(
        plot_data, "macOS CPU", "absolute_peak_rss_ratio", "C  macOS CPU",
        "float32/float64 absolute peak RSS; values below 1 favour float32",
        memory_fill_limit
    ),
    plot_spacer()
)
memory <- wrap_plots(memory_panels, ncol = 2, guides = "collect") +
    plot_annotation(
        title = "Float32 absolute peak process-memory effect",
        subtitle = paste(
            "Matched inputs, component counts and predictions;",
            "medians of three fresh processes"
        )
    ) & theme(legend.position = "bottom")

ggsave(
    file.path(output_dir, "figureS17_precision_runtime_ratio.png"), runtime,
    width = 11, height = 9.3, units = "in", dpi = 320, bg = "white"
)
ggsave(
    file.path(output_dir, "figureS17_precision_runtime_ratio.pdf"), runtime,
    width = 11, height = 9.3, units = "in", device = cairo_pdf, bg = "white"
)
ggsave(
    file.path(output_dir, "figureS18_precision_absolute_rss_ratio.png"),
    memory, width = 11, height = 9.3, units = "in", dpi = 320, bg = "white"
)
ggsave(
    file.path(output_dir, "figureS18_precision_absolute_rss_ratio.pdf"),
    memory, width = 11, height = 9.3, units = "in", device = cairo_pdf,
    bg = "white"
)
