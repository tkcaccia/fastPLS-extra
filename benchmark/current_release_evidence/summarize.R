#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 3L) {
    stop("Usage: summarize.R PRECISION_RAW SOLVER_RAW OUTPUT_DIR", call. = FALSE)
}
out <- args[[3L]]
dir.create(out, recursive = TRUE, showWarnings = FALSE)

summarize_groups <- function(data, keys) {
    parts <- split(data, interaction(data[keys], drop = TRUE, lex.order = TRUE))
    do.call(rbind, lapply(parts, function(x) {
        row <- x[1L, keys, drop = FALSE]
        row$repetitions <- nrow(x)
        row$median_total_sec <- median(x$total_sec)
        row$q1_total_sec <- unname(quantile(x$total_sec, 0.25))
        row$q3_total_sec <- unname(quantile(x$total_sec, 0.75))
        row$median_metric <- median(x$metric_value)
        row$median_incremental_peak_rss_mib <- median(x$incremental_peak_rss_mib)
        row
    }))
}

precision <- read.csv(args[[1L]], check.names = FALSE)
component_keys <- if (all(c("ncomp_requested", "ncomp_effective") %in%
                          names(precision))) {
    c("ncomp_requested", "ncomp_effective")
} else {
    "ncomp"
}
precision_summary <- summarize_groups(
    precision,
    c("dataset", "method", "backend", "precision", "metric_name",
      component_keys)
)
write.csv(precision_summary, file.path(out, "precision_summary.csv"), row.names = FALSE)

solver <- read.csv(args[[2L]], check.names = FALSE)
names(solver)[names(solver) == "RMSD"] <- "metric_value"
solver$metric_name <- "RMSD"
solver_summary <- summarize_groups(
    solver,
    c("shape", "family", "solver", "metric_name", "ncomp")
)
write.csv(solver_summary, file.path(out, "solver_summary.csv"), row.names = FALSE)
