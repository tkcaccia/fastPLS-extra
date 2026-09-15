#!/usr/bin/env Rscript

suppressPackageStartupMessages({
    library(ggplot2)
    library(patchwork)
})

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 4L) {
    stop(
        paste(
            "Usage: build_figures.R MAC_CORE1 MAC_CORE4",
            "LINUX_CORE1 LINUX_CORE4"
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

read_runs <- function(path, platform, cores) {
    value <- read.csv(path, check.names = FALSE, na.strings = c("", "NA"))
    value$platform <- platform
    value$cores <- cores
    value
}

runs <- rbind(
    read_runs(args[[1L]], "Mac", 1L),
    read_runs(args[[2L]], "Mac", 4L),
    read_runs(args[[3L]], "Linux", 1L),
    read_runs(args[[4L]], "Linux", 4L)
)
if (any(runs$status != "success")) {
    stop("Every multicore benchmark row must complete successfully.")
}
if (any(runs$precision != "float32")) {
    stop("The multicore comparison requires matched float32 inputs.")
}

keys <- c("platform", "dataset", "family", "requested_ncomp", "cores")
groups <- split(runs, interaction(runs[keys], drop = TRUE))
summary <- do.call(rbind, lapply(groups, function(block) {
    data.frame(
        platform = block$platform[[1L]],
        dataset = block$dataset[[1L]],
        family = block$family[[1L]],
        ncomp = block$requested_ncomp[[1L]],
        cores = block$cores[[1L]],
        repetitions = nrow(block),
        total_sec_median = median(block$total_sec),
        total_sec_q1 = unname(quantile(block$total_sec, 0.25)),
        total_sec_q3 = unname(quantile(block$total_sec, 0.75)),
        peak_rss_mib_median = median(block$peak_rss_mib),
        peak_rss_mib_q1 = unname(quantile(block$peak_rss_mib, 0.25)),
        peak_rss_mib_q3 = unname(quantile(block$peak_rss_mib, 0.75)),
        metric_name = block$metric_name[[1L]],
        metric_median = median(block$metric_value),
        stringsAsFactors = FALSE
    )
}))

one <- summary[summary$cores == 1L, ]
four <- summary[summary$cores == 4L, ]
paired <- merge(
    one, four,
    by = c("platform", "dataset", "family", "ncomp", "metric_name"),
    suffixes = c("_one", "_four"), all = TRUE
)
if (anyNA(paired$total_sec_median_one) || anyNA(paired$total_sec_median_four)) {
    stop("A matched one-core or four-core cell is missing.")
}
paired$runtime_ratio <- paired$total_sec_median_one /
    paired$total_sec_median_four
paired$absolute_peak_rss_ratio <- paired$peak_rss_mib_median_four /
    paired$peak_rss_mib_median_one
paired$metric_difference <- paired$metric_median_four - paired$metric_median_one

output_dir <- dirname(normalizePath(args[[1L]], mustWork = TRUE))
write.csv(summary, file.path(output_dir, "multicore_selected_summary.csv"),
          row.names = FALSE, na = "")
write.csv(paired, file.path(output_dir, "multicore_selected_ratios.csv"),
          row.names = FALSE, na = "")

theme_publication <- function() {
    theme_minimal(base_size = 9, base_family = "Helvetica") +
        theme(
            plot.title = element_text(face = "bold", size = 11),
            plot.subtitle = element_text(size = 8.5),
            axis.text = element_text(colour = "grey15"),
            axis.text.x = element_text(angle = 25, hjust = 1),
            panel.grid = element_blank(),
            legend.position = "bottom",
            legend.title = element_text(face = "bold")
        )
}

ratio_panel <- function(data, platform, field, title, subtitle) {
    current <- data[data$platform == platform, , drop = FALSE]
    current$dataset_label <- factor(
        current$dataset, levels = rev(dataset_order),
        labels = rev(unname(dataset_labels[dataset_order]))
    )
    current$family_label <- factor(
        current$family, levels = family_order,
        labels = unname(family_labels[family_order])
    )
    current$value <- current[[field]]
    current$label <- sprintf("%.2fx", current$value)
    ggplot(current, aes(family_label, dataset_label, fill = log2(value))) +
        geom_tile(colour = "white", linewidth = 0.55) +
        geom_text(aes(label = label), size = 2.35) +
        scale_fill_gradient2(
            low = "#B2182B", mid = "#F7F7F7", high = "#2166AC",
            midpoint = 0, name = "log2 ratio"
        ) +
        labs(title = title, subtitle = subtitle, x = NULL, y = NULL) +
        theme_publication()
}

runtime <- ratio_panel(
    paired, "Linux", "runtime_ratio", "A  Linux CPU",
    "One-core/four-core total runtime; values above 1 favour four cores"
) + ratio_panel(
    paired, "Mac", "runtime_ratio", "B  Mac CPU",
    "One-core/four-core total runtime; values above 1 favour four cores"
) + plot_layout(guides = "collect") +
    plot_annotation(
        title = "Four-core runtime benefit across selected PLS workloads",
        subtitle = paste(
            "Matched float32 inputs, component counts and predictions;",
            "medians of three fresh processes"
        )
    ) & theme(legend.position = "bottom")

memory <- ratio_panel(
    paired, "Linux", "absolute_peak_rss_ratio", "A  Linux CPU",
    "Four-core/one-core absolute peak process RSS; values below 1 favour four cores"
) + ratio_panel(
    paired, "Mac", "absolute_peak_rss_ratio", "B  Mac CPU",
    "Four-core/one-core absolute peak process RSS; values below 1 favour four cores"
) + plot_layout(guides = "collect") +
    plot_annotation(
        title = "Four-core absolute peak process-memory ratio",
        subtitle = paste(
            "Matched float32 inputs, component counts and predictions;",
            "medians of three fresh processes"
        )
    ) & theme(legend.position = "bottom")

ggsave(file.path(output_dir, "figureS15_multicore_runtime_ratio.png"), runtime,
       width = 11, height = 7.4, units = "in", dpi = 320, bg = "white")
ggsave(file.path(output_dir, "figureS15_multicore_runtime_ratio.pdf"), runtime,
       width = 11, height = 7.4, units = "in", device = cairo_pdf, bg = "white")
ggsave(file.path(output_dir, "figureS16_multicore_absolute_rss_ratio.png"), memory,
       width = 11, height = 7.4, units = "in", dpi = 320, bg = "white")
ggsave(file.path(output_dir, "figureS16_multicore_absolute_rss_ratio.pdf"), memory,
       width = 11, height = 7.4, units = "in", device = cairo_pdf, bg = "white")
