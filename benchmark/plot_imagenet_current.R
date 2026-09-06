#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 2L) {
    stop("Usage: plot_imagenet_current.R RESULTS_CSV OUT_PREFIX", call. = FALSE)
}

input <- args[[1L]]
out_prefix <- args[[2L]]

suppressPackageStartupMessages({
    library(ggplot2)
    library(patchwork)
})

data <- read.csv(input, check.names = FALSE, stringsAsFactors = FALSE)
data <- data[data$status == "success" & data$classifier %in% c("argmax", "lda"), ]
if (!nrow(data)) stop("No successful ImageNet rows were found.", call. = FALSE)

data$classifier_label <- factor(
    data$classifier,
    levels = c("argmax", "lda"),
    labels = c("Argmax", "LDA")
)

single_label <- function(values, label) {
    values <- unique(values[!is.na(values) & nzchar(as.character(values))])
    if (!length(values)) return(paste0(label, " not recorded"))
    paste0(label, " ", paste(values, collapse = "/"))
}

control_pairs <- unique(data.frame(
    oversample = data$effective_oversample,
    power = data$effective_power
))
control_pairs <- control_pairs[
    is.finite(control_pairs$oversample) & is.finite(control_pairs$power),
    ,
    drop = FALSE
]
control_label <- if (nrow(control_pairs)) {
    paste(
        apply(control_pairs, 1L, function(row) {
            sprintf("oversampling %d, power %d", row[[1L]], row[[2L]])
        }),
        collapse = "; "
    )
} else {
    "rSVD controls not recorded"
}

split_labels <- unique(data.frame(
    train_n = data$train_n,
    test_n = data$test_n
))
split_labels <- split_labels[
    is.finite(split_labels$train_n) & is.finite(split_labels$test_n),
    ,
    drop = FALSE
]
split_label <- if (nrow(split_labels)) {
    paste(
        apply(split_labels, 1L, function(row) {
            sprintf("%s training and %s held-out embeddings",
                    format(row[[1L]], big.mark = ",", scientific = FALSE),
                    format(row[[2L]], big.mark = ",", scientific = FALSE))
        }),
        collapse = "; "
    )
} else {
    "split size not recorded"
}

accuracy <- rbind(
    data.frame(
        classifier = data$classifier_label, ncomp = data$ncomp_requested,
        metric = "Top-1", accuracy = data$top1_accuracy
    ),
    data.frame(
        classifier = data$classifier_label, ncomp = data$ncomp_requested,
        metric = "Top-5", accuracy = data$top5_accuracy
    )
)
accuracy$metric <- factor(accuracy$metric, levels = c("Top-1", "Top-5"))

head_summary <- data[!duplicated(data$classifier), , drop = FALSE]
fit_time_column <- if ("fit_time_sec" %in% names(head_summary)) {
    "fit_time_sec"
} else {
    "fit_predict_time_sec"
}
time_data <- rbind(
    data.frame(
        classifier = head_summary$classifier_label,
        stage = "PLS fit",
        seconds = head_summary[[fit_time_column]]
    ),
    data.frame(
        classifier = head_summary$classifier_label,
        stage = "Top-5 prediction",
        seconds = head_summary$top5_prediction_time_sec
    )
)
memory_data <- rbind(
    data.frame(
        classifier = head_summary$classifier_label,
        memory = "Host RSS increment",
        gib = head_summary$incremental_peak_rss_mb / 1024
    ),
    data.frame(
        classifier = head_summary$classifier_label,
        memory = "GPU increment",
        gib = head_summary$gpu_incremental_peak_mb / 1024
    )
)

colors <- c("Argmax" = "#2166AC", "LDA" = "#B2182B")
base_theme <- theme_bw(base_size = 10) +
    theme(
        panel.grid.minor = element_blank(),
        plot.title = element_text(face = "bold", size = 10.5),
        legend.title = element_blank()
    )

panel_a <- ggplot(
    accuracy,
    aes(ncomp, accuracy, color = classifier, linetype = metric,
        shape = metric, group = interaction(classifier, metric))
) +
    geom_line(linewidth = 0.8) +
    geom_point(size = 2.0) +
    scale_color_manual(values = colors) +
    scale_linetype_manual(values = c("Top-1" = "solid", "Top-5" = "dashed")) +
    scale_shape_manual(values = c("Top-1" = 16, "Top-5" = 17)) +
    scale_x_continuous(breaks = seq(100, 1000, 100)) +
    labs(
        title = "A  Held-out classification across component prefixes",
        x = "Number of SIMPLS components",
        y = "Accuracy"
    ) +
    base_theme +
    theme(legend.position = "bottom")

panel_b <- ggplot(time_data, aes(classifier, seconds, fill = stage)) +
    geom_col(position = "stack", width = 0.62) +
    scale_fill_manual(values = c(
        "PLS fit" = "#4C78A8",
        "Top-5 prediction" = "#F2A541"
    )) +
    labs(
        title = "B  Runtime by classification head",
        x = NULL,
        y = "Time (s)"
    ) +
    base_theme +
    theme(legend.position = "bottom")

panel_c <- ggplot(memory_data, aes(classifier, gib, fill = memory)) +
    geom_col(position = position_dodge(width = 0.72), width = 0.62) +
    scale_fill_manual(values = c(
        "Host RSS increment" = "#59A14F",
        "GPU increment" = "#E15759"
    )) +
    labs(
        title = "C  Baseline-corrected peak memory",
        x = NULL,
        y = "Memory (GiB)"
    ) +
    base_theme +
    theme(legend.position = "bottom")

combined <- panel_a / (panel_b + panel_c) +
    plot_layout(heights = c(1.25, 1)) +
    plot_annotation(
        title = "ImageNet/DINOv2 embedding stress test",
        subtitle = paste0(
            single_label(data$loaded_package_version, "fastPLS"), "; ",
            paste(unique(data$precision), collapse = "/"), " ",
            toupper(paste(unique(data$backend), collapse = "/")),
            " SIMPLS-rSVD; ",
            control_label, "; ", single_label(data$seed, "seed"), "\n",
            split_label, "; one shared component path per head"
        )
    ) &
    theme(
        plot.title = element_text(face = "bold", size = 14),
        plot.subtitle = element_text(size = 9.5)
    )

dir.create(dirname(out_prefix), recursive = TRUE, showWarnings = FALSE)
ggsave(paste0(out_prefix, ".png"), combined, width = 8.2, height = 7.4, dpi = 320)
ggsave(paste0(out_prefix, ".pdf"), combined, width = 8.2, height = 7.4)
write.csv(data, paste0(out_prefix, "_plotted_values.csv"), row.names = FALSE)
