args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 3L || length(args) > 4L) {
    stop(
        "usage: summarize.R LINUX.csv MACOS.csv WINDOWS.csv [OUTPUT_DIR]",
        call. = FALSE
    )
}

linux_path <- normalizePath(args[[1L]], mustWork = TRUE)
macos_path <- normalizePath(args[[2L]], mustWork = TRUE)
windows_path <- normalizePath(args[[3L]], mustWork = TRUE)
output_dir <- if (length(args) == 4L) args[[4L]] else dirname(linux_path)
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

summarize_runs <- function(path, platform) {
    values <- read.csv(path, stringsAsFactors = FALSE, check.names = FALSE)
    if (!"operation" %in% names(values)) {
        values$operation <- "sample_gram"
    }
    required <- c(
        "backend", "operation", "n", "q", "precision", "threads", "output",
        "total_seconds", "median_seconds", "mirror_seconds",
        "sampled_rel_l2_error", "max_abs_error", "max_symmetry_error",
        "incremental_peak_rss_bytes"
    )
    missing <- setdiff(required, names(values))
    if (length(missing)) {
        stop("missing columns in ", path, ": ", paste(missing, collapse = ", "))
    }
    groups <- interaction(
        values$backend, values$operation, values$n, values$q, values$precision,
        values$threads, values$output, drop = TRUE
    )
    rows <- lapply(split(values, groups), function(current) {
        data.frame(
            platform = platform,
            backend = current$backend[[1L]],
            operation = current$operation[[1L]],
            n = current$n[[1L]],
            q = current$q[[1L]],
            precision = current$precision[[1L]],
            threads = current$threads[[1L]],
            output = current$output[[1L]],
            fresh_processes = nrow(current),
            median_total_seconds = median(current$total_seconds),
            q1_total_seconds = unname(quantile(current$total_seconds, 0.25)),
            q3_total_seconds = unname(quantile(current$total_seconds, 0.75)),
            median_kernel_seconds = median(current$median_seconds),
            median_mirror_seconds = median(current$mirror_seconds),
            median_incremental_peak_rss_bytes = median(
                current$incremental_peak_rss_bytes
            ),
            maximum_sampled_relative_l2_error = max(
                current$sampled_rel_l2_error
            ),
            maximum_absolute_error = max(current$max_abs_error),
            maximum_symmetry_error = max(current$max_symmetry_error),
            stringsAsFactors = FALSE
        )
    })
    result <- do.call(rbind, rows)
    tolerance <- ifelse(result$precision == "float32", 5e-5, 1e-12)
    result$numerically_qualified <-
        is.finite(result$maximum_sampled_relative_l2_error) &
        result$maximum_sampled_relative_l2_error <= tolerance &
        result$maximum_symmetry_error == 0
    rownames(result) <- NULL
    result
}

linux <- summarize_runs(linux_path, "Linux Intel")
macos <- summarize_runs(macos_path, "macOS Apple Silicon")
windows <- summarize_runs(windows_path, "Windows Intel")
all_results <- rbind(linux, macos, windows)

qualified <- all_results[all_results$numerically_qualified, , drop = FALSE]
shape <- interaction(
    qualified$platform, qualified$operation, qualified$n, qualified$q,
    qualified$precision,
    qualified$output, drop = TRUE
)
best <- do.call(rbind, lapply(split(qualified, shape), function(current) {
    current[which.min(current$median_total_seconds), , drop = FALSE]
}))
rownames(best) <- NULL

write.csv(
    all_results,
    file.path(output_dir, "response_gram_backend_summary.csv"),
    row.names = FALSE
)
write.csv(
    best,
    file.path(output_dir, "response_gram_best_by_measured_shape.csv"),
    row.names = FALSE
)

cat("Summarized", nrow(all_results), "backend/shape/thread settings\n")
cat("Numerically qualified:", sum(all_results$numerically_qualified),
    "of", nrow(all_results), "\n")
cat("Output:", normalizePath(output_dir), "\n")
