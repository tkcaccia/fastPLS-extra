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

# Figure 4 focuses on the SIMPLS-family route. The complete four-family
# endpoint comparison remains available in the supplementary source table.
data <- data[data$method == "simpls", , drop = FALSE]
if (!nrow(data)) stop("No successful SIMPLS ImageNet rows were found.", call. = FALSE)

data$classifier_label <- factor(
    data$classifier,
    levels = c("argmax", "lda"),
    labels = c("Argmax", "LDA")
)
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
        classifier = data$classifier_label,
        ncomp = data$ncomp_requested,
        metric = "Top-1", accuracy = data$top1_accuracy
    ),
    data.frame(
        classifier = data$classifier_label,
        ncomp = data$ncomp_requested,
        metric = "Top-5", accuracy = data$top5_accuracy
    )
)
accuracy$metric <- factor(
    accuracy$metric,
    levels = c("Top-1", "Top-5")
)

summary_rows <- unique(data[c(
    "classifier", "classifier_label", "fit_predict_time_sec",
    "top5_prediction_time_sec", "total_time_sec", "process_peak_rss_mb",
    "gpu_peak_mb"
)])

runtime <- rbind(
    data.frame(
        classifier = summary_rows$classifier_label,
        stage = "Fit",
        seconds = summary_rows$fit_predict_time_sec
    ),
    data.frame(
        classifier = summary_rows$classifier_label,
        stage = "Top-5 prediction",
        seconds = summary_rows$top5_prediction_time_sec
    )
)
runtime$stage <- factor(runtime$stage, levels = c("Top-5 prediction", "Fit"))

memory <- rbind(
    data.frame(
        classifier = summary_rows$classifier_label,
        location = "Host process RSS",
        gib = summary_rows$process_peak_rss_mb / 1024
    ),
    data.frame(
        classifier = summary_rows$classifier_label,
        location = "CUDA device",
        gib = summary_rows$gpu_peak_mb / 1024
    )
)
memory$location <- factor(
    memory$location,
    levels = c("Host process RSS", "CUDA device")
)

metric_colors <- c("Top-1" = "#0072B2", "Top-5" = "#D55E00")
stage_colors <- c("Fit" = "#0072B2", "Top-5 prediction" = "#E69F00")
memory_colors <- c("Host process RSS" = "#009E73", "CUDA device" = "#CC79A7")
base_theme <- theme_bw(base_size = 10) +
    theme(
        panel.grid.minor = element_blank(),
        panel.grid.major.x = element_line(color = "#E5E7EB", linewidth = 0.35),
        panel.grid.major.y = element_line(color = "#D1D5DB", linewidth = 0.35),
        legend.title = element_blank(),
        legend.position = "bottom"
    )

accuracy_plot <- ggplot(
    accuracy,
    aes(
        ncomp,
        accuracy,
        color = metric,
        linetype = classifier,
        shape = classifier,
        group = interaction(metric, classifier)
    )
) +
    geom_line(linewidth = 0.9) +
    geom_point(
        size = 2.4,
        stroke = 0.6
    ) +
    scale_color_manual(values = metric_colors) +
    scale_linetype_manual(values = c("Argmax" = "solid", "LDA" = "dashed")) +
    scale_shape_manual(values = c("Argmax" = 16, "LDA" = 17)) +
    scale_x_continuous(
        breaks = c(50, seq(200, 1000, 200)),
        expand = expansion(mult = c(0.015, 0.025))
    ) +
    scale_y_continuous(
        labels = scales::label_percent(accuracy = 1),
        expand = expansion(mult = c(0.06, 0.08))
    ) +
    labs(
        title = "A  SIMPLS-family predictive accuracy",
        x = "Number of PLS components",
        y = "Held-out accuracy"
    ) +
    base_theme +
    theme(
        plot.title = element_text(face = "bold", size = 11),
        axis.title = element_text(size = 10),
        axis.text = element_text(size = 8.5)
    )

runtime_plot <- ggplot(runtime, aes(classifier, seconds, fill = stage)) +
    geom_col(width = 0.66) +
    geom_text(
        data = transform(summary_rows, total = total_time_sec),
        aes(classifier_label, total, label = sprintf("%.2f s", total)),
        inherit.aes = FALSE,
        vjust = -0.35,
        size = 3.2
    ) +
    scale_fill_manual(values = stage_colors) +
    scale_y_continuous(expand = expansion(mult = c(0, 0.12))) +
    labs(
        title = "B  Complete runtime",
        x = NULL,
        y = "Elapsed time (s)"
    ) +
    base_theme +
    theme(plot.title = element_text(face = "bold", size = 11))

memory_plot <- ggplot(memory, aes(classifier, gib, fill = location)) +
    geom_col(position = position_dodge(width = 0.72), width = 0.64) +
    geom_text(
        aes(label = sprintf("%.2f", gib)),
        position = position_dodge(width = 0.72),
        vjust = -0.35,
        size = 3.1
    ) +
    scale_fill_manual(values = memory_colors) +
    scale_y_continuous(expand = expansion(mult = c(0, 0.12))) +
    labs(
        title = "C  Peak memory",
        x = NULL,
        y = "Peak memory (GiB)"
    ) +
    base_theme +
    theme(plot.title = element_text(face = "bold", size = 11))

combined <- accuracy_plot + runtime_plot + memory_plot +
    plot_layout(widths = c(1.7, 1, 1), guides = "collect") +
    plot_annotation(
        title = "ImageNet/DINOv2 classification with the SIMPLS-family estimator",
        subtitle = paste0(
            paste(unique(data$precision), collapse = "/"), " ",
            toupper(paste(unique(data$backend), collapse = "/")),
            "; rSVD ", control_label, "; seed ",
            paste(unique(data$seed), collapse = "/"), "\n",
            split_label, "; one maximal fit per prediction head"
        ),
        theme = theme(
            plot.title = element_text(face = "bold", size = 13),
            plot.subtitle = element_text(size = 9.5)
        )
    ) &
    theme(legend.position = "bottom")

dir.create(dirname(out_prefix), recursive = TRUE, showWarnings = FALSE)
ggsave(paste0(out_prefix, ".png"), combined, width = 10.4, height = 4.8, dpi = 320)
ggsave(paste0(out_prefix, ".pdf"), combined, width = 10.4, height = 4.8)
write.csv(data, paste0(out_prefix, "_plotted_values.csv"), row.names = FALSE)
