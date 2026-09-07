#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 2L) {
    stop("Usage: summarize.R input.csv output.csv")
}
raw <- read.csv(args[[1L]], check.names = FALSE)
keys <- c(
    "package_version", "implementation", "task", "backend", "precision",
    "method", "classifier", "ncomp", "selection_metric", "data_scope",
    "context_mode", "workload"
)
groups <- interaction(raw[keys], drop = TRUE, lex.order = TRUE)
summaries <- lapply(split(raw, groups), function(part) {
    first <- part[1L, keys, drop = FALSE]
    cbind(
        first,
        data.frame(
            repetitions = nrow(part),
            completed = sum(is.finite(part$elapsed_sec)),
            median_sec = median(part$elapsed_sec, na.rm = TRUE),
            q1_sec = quantile(part$elapsed_sec, 0.25, na.rm = TRUE),
            q3_sec = quantile(part$elapsed_sec, 0.75, na.rm = TRUE),
            median_incremental_rss_mib = median(
                part$final_minus_baseline_rss_mib, na.rm = TRUE
            ),
            median_output_mib = median(part$output_mib, na.rm = TRUE),
            selected_components = paste(sort(unique(part$best_ncomp)), collapse = ";"),
            metric_range = paste(range(part$best_metric, na.rm = TRUE), collapse = ";"),
            all_groups_preserved = all(part$groups_preserved),
            fold_signatures = length(unique(part$fold_signature)),
            prediction_signatures = length(unique(
                part$prediction_signature[part$status == "ok"]
            )),
            statuses = paste(sort(unique(part$status)), collapse = ";"),
            errors = paste(unique(stats::na.omit(part$error)), collapse = "; "),
            stringsAsFactors = FALSE
        )
    )
})
write.csv(do.call(rbind, summaries), args[[2L]], row.names = FALSE)
