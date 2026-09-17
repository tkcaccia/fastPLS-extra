#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 2L) {
    stop("Usage: summarize.R RAW_CSV OUTPUT_DIRECTORY", call. = FALSE)
}

raw <- read.csv(args[[1L]], check.names = FALSE)
out <- args[[2L]]
dir.create(out, recursive = TRUE, showWarnings = FALSE)

groups <- split(raw, interaction(raw$workload, raw$requested_cores, drop = TRUE))
summary_rows <- lapply(groups, function(x) {
    data.frame(
        workload = x$workload[[1L]],
        task = x$task[[1L]],
        requested_cores = x$requested_cores[[1L]],
        active_openblas_threads = unique(x$active_openblas_threads)[[1L]],
        n_train = x$n_train[[1L]],
        n_test = x$n_test[[1L]],
        p = x$p[[1L]],
        q = x$q[[1L]],
        ncomp = x$ncomp[[1L]],
        rsvd_oversample = x$rsvd_oversample[[1L]],
        rsvd_power = x$rsvd_power[[1L]],
        seed = x$seed[[1L]],
        repetitions = nrow(x),
        median_sec = median(x$elapsed_sec),
        q1_sec = unname(quantile(x$elapsed_sec, 0.25)),
        q3_sec = unname(quantile(x$elapsed_sec, 0.75)),
        metric_name = x$metric_name[[1L]],
        metric_value = x$metric_value[[1L]],
        metric_range = max(x$metric_value) - min(x$metric_value),
        prediction_agreement = length(unique(x$prediction_signature)) == 1L,
        stringsAsFactors = FALSE
    )
})
summary <- do.call(rbind, summary_rows)
summary <- summary[order(summary$workload, summary$requested_cores), ]

baseline <- summary[summary$requested_cores == 1L, c("workload", "median_sec")]
names(baseline)[2L] <- "one_core_sec"
summary <- merge(summary, baseline, by = "workload", all.x = TRUE, sort = FALSE)
summary$speedup <- summary$one_core_sec / summary$median_sec
summary$parallel_efficiency <- summary$speedup / summary$requested_cores
summary <- summary[order(summary$workload, summary$requested_cores), ]

write.csv(summary, file.path(out, "multicore_scaling_summary.csv"), row.names = FALSE)

pdf(file.path(out, "multicore_scaling.pdf"), width = 7.2, height = 3.9)
op <- par(mar = c(5.2, 4.2, 1.2, 0.5), las = 1)
on.exit({par(op); dev.off()}, add = TRUE)
workloads <- unique(summary$workload)
cols <- c("#1B6CA8", "#D96C32", "#2E8B57")
plot(
    NA,
    xlim = c(1, 4),
    ylim = range(c(1, summary$speedup)),
    xlab = "Active OpenBLAS threads",
    ylab = "Speed-up relative to one thread",
    xaxt = "n"
)
axis(1, at = c(1, 2, 4))
abline(0, 1, lty = 3, col = "grey65")
for (i in seq_along(workloads)) {
    x <- summary[summary$workload == workloads[[i]], ]
    lines(x$requested_cores, x$speedup, type = "b", pch = 19, lwd = 1.5, col = cols[[i]])
}
legend("topleft", legend = workloads, col = cols, pch = 19, lwd = 1.5, bty = "n", cex = 0.8)
