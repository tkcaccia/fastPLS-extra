#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 2L) {
    stop("Usage: summarize_figure1.R RAW_CSV SUMMARY_CSV", call. = FALSE)
}

raw <- read.csv(args[[1L]], check.names = FALSE)
keys <- c("dataset", "method", "classifier", "backend", "precision", "ncomp")
groups <- split(raw, interaction(raw[keys], drop = TRUE, lex.order = TRUE))
summary <- do.call(rbind, lapply(groups, function(value) {
    result <- value[1L, keys, drop = FALSE]
    result$repetitions <- nrow(value)
    result$successful <- sum(value$status == "success")
    result$accuracy <- median(value$accuracy, na.rm = TRUE)
    result$balanced_accuracy <- median(value$balanced_accuracy, na.rm = TRUE)
    result$correct <- median(value$correct, na.rm = TRUE)
    result$test_total <- median(value$test_total, na.rm = TRUE)
    result$median_fit_sec <- median(value$fit_sec, na.rm = TRUE)
    result$median_prediction_sec <- median(value$prediction_sec, na.rm = TRUE)
    result$median_total_sec <- median(value$total_sec, na.rm = TRUE)
    result$q1_total_sec <- unname(quantile(value$total_sec, 0.25, na.rm = TRUE))
    result$q3_total_sec <- unname(quantile(value$total_sec, 0.75, na.rm = TRUE))
    result$median_peak_rss_mib <- median(value$peak_rss_mib, na.rm = TRUE)
    result$median_incremental_peak_rss_mib <- median(
        value$incremental_peak_rss_mib,
        na.rm = TRUE
    )
    result
}))
rownames(summary) <- NULL
summary <- summary[order(summary$dataset, summary$method,
                         summary$classifier), , drop = FALSE]
write.csv(summary, args[[2L]], row.names = FALSE)
