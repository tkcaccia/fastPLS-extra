#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 2L) {
    stop("Usage: summarize_figure1.R RAW_CSV SUMMARY_CSV", call. = FALSE)
}

raw <- read.csv(args[[1L]], check.names = FALSE)
keys <- c("dataset", "task_type", "method", "classifier", "backend",
          "precision", "ncomp_requested", "ncomp")
groups <- split(raw, interaction(raw[keys], drop = TRUE, lex.order = TRUE))
median_or_na <- function(value) {
    value <- value[is.finite(value)]
    if (length(value)) stats::median(value) else NA_real_
}
quantile_or_na <- function(value, probability) {
    value <- value[is.finite(value)]
    if (length(value)) {
        unname(stats::quantile(value, probability, names = FALSE))
    } else {
        NA_real_
    }
}
summary <- do.call(rbind, lapply(groups, function(value) {
    result <- value[1L, keys, drop = FALSE]
    result$package_version <- unique(value$package_version)[[1L]]
    result$platform <- unique(value$platform)[[1L]]
    result$blas <- unique(value$blas)[[1L]]
    result$blas_path <- unique(value$blas_path)[[1L]]
    result$repetitions <- nrow(value)
    result$successful <- sum(value$status == "success")
    result$accuracy <- median_or_na(value$accuracy)
    result$balanced_accuracy <- median_or_na(value$balanced_accuracy)
    result$rmsd <- median_or_na(value$rmsd)
    result$q2 <- median_or_na(value$q2)
    result$mae <- median_or_na(value$mae)
    result$correct <- median_or_na(value$correct)
    result$test_total <- median_or_na(value$test_total)
    result$median_fit_sec <- median_or_na(value$fit_sec)
    result$median_prediction_sec <- median_or_na(value$prediction_sec)
    result$median_total_sec <- median_or_na(value$total_sec)
    result$q1_total_sec <- quantile_or_na(value$total_sec, 0.25)
    result$q3_total_sec <- quantile_or_na(value$total_sec, 0.75)
    result$median_peak_rss_mib <- median_or_na(value$peak_rss_mib)
    result$median_incremental_peak_rss_mib <- median_or_na(
        value$incremental_peak_rss_mib
    )
    result
}))
rownames(summary) <- NULL
summary <- summary[order(summary$dataset, summary$method,
                         summary$classifier), , drop = FALSE]
write.csv(summary, args[[2L]], row.names = FALSE)
