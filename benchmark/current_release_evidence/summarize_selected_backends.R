#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 2L) {
    stop("Usage: summarize_selected_backends.R RAW.csv OUTPUT_DIR", call. = FALSE)
}

raw <- read.csv(normalizePath(args[[1L]], mustWork = TRUE), check.names = FALSE)
output_dir <- normalizePath(args[[2L]], mustWork = FALSE)
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

required <- c(
    "dataset", "family", "backend", "precision", "ncomp", "replicate",
    "fit_sec", "prediction_sec", "total_sec", "metric_name", "metric_value",
    "incremental_peak_rss_mib", "effective_oversample", "effective_power",
    "seed", "execution_route", "status"
)
missing <- setdiff(required, names(raw))
if (length(missing)) {
    stop("Missing required columns: ", paste(missing, collapse = ", "))
}

summarize_group <- function(x) {
    data.frame(
        dataset = x$dataset[[1L]],
        family = x$family[[1L]],
        backend = x$backend[[1L]],
        precision = x$precision[[1L]],
        ncomp = x$ncomp[[1L]],
        metric_name = x$metric_name[[1L]],
        repetitions = nrow(x),
        median_fit_sec = median(x$fit_sec),
        median_prediction_sec = median(x$prediction_sec),
        median_total_sec = median(x$total_sec),
        q1_total_sec = unname(quantile(x$total_sec, 0.25)),
        q3_total_sec = unname(quantile(x$total_sec, 0.75)),
        median_metric = median(x$metric_value),
        median_incremental_peak_rss_mib = median(x$incremental_peak_rss_mib),
        effective_oversample = paste(unique(x$effective_oversample),
                                     collapse = "/"),
        effective_power = paste(unique(x$effective_power), collapse = "/"),
        seed = paste(unique(x$seed), collapse = "/"),
        execution_route = paste(unique(x$execution_route), collapse = "; "),
        completed = sum(x$status == "success"),
        failed = sum(x$status != "success"),
        stringsAsFactors = FALSE
    )
}

keys <- interaction(
    raw$dataset, raw$family, raw$backend, raw$precision, raw$ncomp,
    drop = TRUE, lex.order = TRUE
)
summary <- do.call(rbind, lapply(split(raw, keys), summarize_group))
summary <- summary[order(summary$dataset, summary$family, summary$backend), ]
write.csv(summary, file.path(output_dir, "selected_backend_summary.csv"),
          row.names = FALSE)

cpu <- summary[summary$backend == "cpu", ]
metal <- summary[summary$backend == "metal", ]
pair_keys <- c("dataset", "family", "precision", "ncomp", "metric_name")
paired <- merge(cpu, metal, by = pair_keys, suffixes = c("_cpu", "_metal"))
paired$runtime_ratio_cpu_over_metal <-
    paired$median_total_sec_cpu / paired$median_total_sec_metal
paired$memory_ratio_metal_over_cpu <-
    paired$median_incremental_peak_rss_mib_metal /
        paired$median_incremental_peak_rss_mib_cpu
paired$metric_difference_metal_minus_cpu <-
    paired$median_metric_metal - paired$median_metric_cpu
paired$absolute_metric_difference <- abs(paired$metric_difference_metal_minus_cpu)
paired <- paired[order(paired$dataset, paired$family), ]
write.csv(paired, file.path(output_dir, "selected_backend_paired.csv"),
          row.names = FALSE)

print(summary, row.names = FALSE)
print(paired[, c(
    "dataset", "family", "ncomp", "runtime_ratio_cpu_over_metal",
    "metric_difference_metal_minus_cpu", "memory_ratio_metal_over_cpu"
)], row.names = FALSE)
