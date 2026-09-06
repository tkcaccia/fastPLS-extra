#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 2L) {
    stop("Usage: plot_controlled_scaling_current.R INPUT.csv OUTPUT_PREFIX")
}

input <- normalizePath(args[[1L]], mustWork = TRUE)
output <- args[[2L]]
dir.create(dirname(output), recursive = TRUE, showWarnings = FALSE)

raw <- read.csv(input, stringsAsFactors = FALSE)
factor_labels <- c(
    n = "Observations (n)",
    p = "Predictors (p)",
    q = "Responses (q)",
    ncomp = "Components",
    prefix_count = "Requested prefixes",
    rank = "Effective rank",
    class_count = "Classes",
    crosscov_mb = "Cross-covariance (MiB)"
)

paired_columns <- c(
    "scenario_id", "factor_name", "factor_value", "total_sec_irlba",
    "total_sec_rsvd", "prediction_relative_error_rsvd"
)
if (all(paired_columns %in% names(raw))) {
    paired <- raw
} else {
    required_raw <- c(
        "status", "design_partition", "route", "scenario_id",
        "factor_name", "factor_value", "total_sec",
        "prediction_relative_error"
    )
    absent <- setdiff(required_raw, names(raw))
    if (length(absent)) {
        stop(
            "Controlled-scaling input has neither the raw nor paired schema. ",
            "Missing columns: ", paste(absent, collapse = ", "),
            call. = FALSE
        )
    }
    raw <- raw[
        raw$status == "success" &
            raw$design_partition == "one_factor" &
            raw$route %in% c("cpu_irlba_explicit", "cpu_rsvd_auto"),
        , drop = FALSE
    ]

    median_finite <- function(x) {
        x <- x[is.finite(x)]
        if (length(x)) median(x) else NA_real_
    }

    keys <- c("scenario_id", "factor_name", "factor_value", "route")
    groups <- split(raw, interaction(raw[keys], drop = TRUE, lex.order = TRUE))
    summary <- do.call(rbind, lapply(groups, function(x) {
        data.frame(
            scenario_id = x$scenario_id[[1L]],
            factor_name = x$factor_name[[1L]],
            factor_value = x$factor_value[[1L]],
            route = x$route[[1L]],
            total_sec = median_finite(x$total_sec),
            prediction_relative_error = median_finite(
                x$prediction_relative_error
            ),
            stringsAsFactors = FALSE
        )
    }))

    irlba <- summary[summary$route == "cpu_irlba_explicit", ]
    rsvd <- summary[summary$route == "cpu_rsvd_auto", ]
    paired <- merge(
        irlba, rsvd,
        by = c("scenario_id", "factor_name", "factor_value"),
        suffixes = c("_irlba", "_rsvd")
    )
}
paired$speed_ratio <- paired$total_sec_irlba / paired$total_sec_rsvd
paired$prediction_relative_error_rsvd <- pmax(
    paired$prediction_relative_error_rsvd,
    .Machine$double.eps,
    na.rm = TRUE
)
paired$factor_label <- factor(
    factor_labels[paired$factor_name],
    levels = unname(factor_labels)
)

library(ggplot2)
theme_publication <- theme_bw(base_size = 10) +
    theme(
        panel.grid.minor = element_blank(),
        strip.background = element_rect(fill = "#E8ECEF"),
        strip.text = element_text(face = "bold")
    )

panel_a <- ggplot(paired, aes(factor_value, speed_ratio)) +
    geom_hline(yintercept = 1, linetype = 2, colour = "#555555") +
    geom_line(colour = "#C4512B", linewidth = 0.55) +
    geom_point(shape = 21, fill = "#F4A261", colour = "#7A2E16", size = 2.2) +
    facet_wrap(~ factor_label, scales = "free_x", ncol = 4) +
    scale_x_log10() +
    scale_y_log10() +
    labs(
        title = "A  Runtime ratio",
        subtitle = "Values above 1 indicate faster rSVD execution",
        x = "Swept factor value",
        y = "IRLBA / rSVD total time"
    ) +
    theme_publication

panel_b <- ggplot(paired, aes(factor_value, prediction_relative_error_rsvd)) +
    geom_hline(yintercept = 0.01, linetype = 2, colour = "#555555") +
    geom_line(colour = "#1D5D84", linewidth = 0.55) +
    geom_point(shape = 21, fill = "#70B7D4", colour = "#153E56", size = 2.2) +
    facet_wrap(~ factor_label, scales = "free_x", ncol = 4) +
    scale_x_log10() +
    scale_y_log10() +
    labs(
        title = "B  Prediction agreement",
        subtitle = "Dashed line is the numerical-screening limit",
        x = "Swept factor value",
        y = "rSVD relative prediction error"
    ) +
    theme_publication

if (!requireNamespace("patchwork", quietly = TRUE)) {
    stop("The patchwork package is required to assemble the figure.")
}
figure <- panel_a / panel_b
ggsave(paste0(output, ".png"), figure, width = 9, height = 7, dpi = 300)
ggsave(paste0(output, ".pdf"), figure, width = 9, height = 7)

write.csv(
    paired,
    paste0(output, "_data.csv"),
    row.names = FALSE
)
