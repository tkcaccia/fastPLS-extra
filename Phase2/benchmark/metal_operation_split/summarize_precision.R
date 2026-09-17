#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 4L) {
    stop(paste(
        "Usage: summarize_precision.R OLD_SUMMARY METAL_RAW",
        "OUTPUT_SUMMARY OUTPUT_FIGURE_STEM"
    ), call. = FALSE)
}

suppressPackageStartupMessages({
    library(ggplot2)
    library(patchwork)
})

old <- read.csv(normalizePath(args[[1L]], mustWork = TRUE),
    stringsAsFactors = FALSE)
raw <- read.csv(normalizePath(args[[2L]], mustWork = TRUE),
    stringsAsFactors = FALSE)
raw <- raw[raw$status == "success", , drop = FALSE]

groups <- split(raw, interaction(
    raw$dataset, raw$method, raw$backend, raw$precision,
    drop = TRUE, lex.order = TRUE
))
metal <- do.call(rbind, lapply(groups, function(block) {
    elapsed <- block$total_sec[is.finite(block$total_sec)]
    metric <- block$metric_value[is.finite(block$metric_value)]
    memory <- block$incremental_peak_rss_mib[
        is.finite(block$incremental_peak_rss_mib)
    ]
    data.frame(
        dataset = block$dataset[[1L]],
        method = block$method[[1L]],
        backend = block$backend[[1L]],
        precision = block$precision[[1L]],
        metric_name = block$metric_name[[1L]],
        ncomp_requested = block$ncomp_requested[[1L]],
        ncomp_effective = block$ncomp_effective[[1L]],
        repetitions = length(elapsed),
        median_total_sec = median(elapsed),
        q1_total_sec = unname(quantile(elapsed, 0.25)),
        q3_total_sec = unname(quantile(elapsed, 0.75)),
        median_metric = median(metric),
        median_incremental_peak_rss_mib = median(memory),
        stringsAsFactors = FALSE
    )
}))

summary <- rbind(
    old[old$backend != "metal", names(metal), drop = FALSE],
    metal
)
summary <- summary[order(
    summary$dataset, summary$method, summary$backend, summary$precision
), , drop = FALSE]
dir.create(dirname(args[[3L]]), recursive = TRUE, showWarnings = FALSE)
write.csv(summary, args[[3L]], row.names = FALSE)

pairs <- merge(
    summary[summary$backend == "cpu" & summary$precision == "float64", ],
    summary[summary$precision == "float32", ],
    by = c("dataset", "method"), suffixes = c("_float64", "_float32")
)
pairs$runtime_ratio <- pairs$median_total_sec_float64 /
    pairs$median_total_sec_float32
pairs$memory_ratio <- pairs$median_incremental_peak_rss_mib_float32 /
    pairs$median_incremental_peak_rss_mib_float64
pairs$metric_difference <- pairs$median_metric_float32 -
    pairs$median_metric_float64
pairs$comparison <- ifelse(
    pairs$backend_float32 == "metal", "Metal float32 / CPU float64",
    paste0(toupper(pairs$backend_float32), " float32 / CPU float64")
)
pairs$label <- paste(
    toupper(pairs$dataset), toupper(pairs$method), pairs$comparison, sep = "\n"
)

base_theme <- theme_minimal(base_size = 8) + theme(
    axis.text.x = element_text(angle = 45, hjust = 1, size = 6),
    panel.grid.minor = element_blank(), legend.position = "none"
)
p1 <- ggplot(pairs, aes(label, runtime_ratio, fill = comparison)) +
    geom_col() + geom_hline(yintercept = 1, linetype = 2) +
    labs(title = "A  Runtime", x = NULL, y = "float64 CPU / float32 route") +
    base_theme
p2 <- ggplot(pairs, aes(label, memory_ratio, fill = comparison)) +
    geom_col() + geom_hline(yintercept = 1, linetype = 2) +
    labs(title = "B  Incremental host memory", x = NULL,
        y = "float32 route / float64 CPU") + base_theme
p3 <- ggplot(pairs, aes(label, metric_difference, fill = comparison)) +
    geom_col() + geom_hline(yintercept = 0, linetype = 2) +
    labs(title = "C  Predictive metric difference", x = NULL,
        y = "float32 - float64") + base_theme
figure <- p1 / p2 / p3 + plot_annotation(
    title = "Matched float32 and float64 execution",
    subtitle = paste(
        "Conversion is excluded; Metal denotes the fixed CPU/Metal",
        "operation split and supports float32 only."
    )
)
stem <- args[[4L]]
dir.create(dirname(stem), recursive = TRUE, showWarnings = FALSE)
ggsave(paste0(stem, ".png"), figure, width = 10.2, height = 10.0,
    dpi = 320, bg = "white")
ggsave(paste0(stem, ".pdf"), figure, width = 10.2, height = 10.0,
    device = cairo_pdf, bg = "white")
