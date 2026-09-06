#!/usr/bin/env Rscript

# Rerun only component-path workers listed in a contamination manifest.
# Original outputs remain untouched; corrected aggregate tables are written to
# a separate directory so the replacement is fully auditable.

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 3L) {
    stop(
        paste(
            "Usage: rerun_component_path_manifest.R",
            "ORIGINAL_DIR MANIFEST OUT_DIR"
        ),
        call. = FALSE
    )
}

benchmark_lib <- Sys.getenv("FASTPLS_BENCH_LIB", "")
if (nzchar(benchmark_lib)) {
    .libPaths(unique(c(benchmark_lib, .libPaths())))
}
suppressPackageStartupMessages(library(fastPLS))

original_dir <- normalizePath(args[[1L]], mustWork = TRUE)
manifest_path <- normalizePath(args[[2L]], mustWork = TRUE)
out_dir <- normalizePath(args[[3L]], mustWork = FALSE)
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

script_arg <- commandArgs()[grep("^--file=", commandArgs())]
script_path <- normalizePath(sub("^--file=", "", script_arg[[1L]]))
repo_dir <- normalizePath(file.path(dirname(script_path), ".."))
worker <- file.path(repo_dir, "benchmark", "metal_validation", "metal_worker.R")

manifest <- trimws(readLines(manifest_path, warn = FALSE))
manifest <- unique(manifest[nzchar(manifest)])
run_ids <- sub("_result[.]rds$", "", basename(manifest))
if (!length(run_ids)) {
    stop("The contamination manifest is empty.", call. = FALSE)
}

config_path <- file.path(original_dir, "configurations.rds")
configs <- readRDS(config_path)
config_ids <- vapply(configs, `[[`, character(1L), "run_id")
missing_ids <- setdiff(run_ids, config_ids)
if (length(missing_ids)) {
    stop(
        "Configurations are missing for: ",
        paste(head(missing_ids, 10L), collapse = ", "),
        if (length(missing_ids) > 10L) " ..." else "",
        call. = FALSE
    )
}
configs <- configs[match(run_ids, config_ids)]

parse_peak_rss <- function(path) {
    if (!file.exists(path)) {
        return(NA_real_)
    }
    lines <- readLines(path, warn = FALSE)
    hit <- grep("maximum resident set size", tolower(lines), value = TRUE)
    if (!length(hit)) {
        return(NA_real_)
    }
    value <- suppressWarnings(as.numeric(gsub("[^0-9]", "", tail(hit, 1L))))
    if (!is.finite(value)) {
        return(NA_real_)
    }
    if (identical(Sys.info()[["sysname"]], "Darwin")) {
        value / 1024^2
    } else {
        value / 1024
    }
}

bind_rows <- function(frames) {
    columns <- unique(unlist(lapply(frames, names), use.names = FALSE))
    normalized <- lapply(frames, function(frame) {
        missing <- setdiff(columns, names(frame))
        for (column in missing) {
            frame[[column]] <- NA
        }
        frame[columns]
    })
    do.call(rbind, normalized)
}

time_flag <- if (identical(Sys.info()[["sysname"]], "Darwin")) "-l" else "-v"
rows <- vector("list", length(configs))
for (index in seq_along(configs)) {
    config <- configs[[index]]
    config_file <- file.path(out_dir, paste0(config$run_id, "_config.rds"))
    result_file <- file.path(out_dir, paste0(config$run_id, "_result.rds"))
    stdout_file <- file.path(out_dir, paste0(config$run_id, ".out"))
    time_file <- file.path(out_dir, paste0(config$run_id, ".time"))

    if (!file.exists(result_file)) {
        saveRDS(config, config_file)
        cat(sprintf("[%d/%d] %s\n", index, length(configs), config$run_id))
        status <- system2(
            "/usr/bin/time",
            c(
                time_flag,
                file.path(R.home("bin"), "Rscript"),
                worker,
                config_file,
                result_file
            ),
            stdout = stdout_file,
            stderr = time_file
        )
        unlink(config_file)
        if (!file.exists(result_file)) {
            failure <- data.frame(
                run_id = config$run_id,
                experiment = config$experiment,
                dataset = config$dataset,
                task_type = config$task_type,
                method = config$method,
                backend_requested = config$backend,
                svd_method = config$svd_method,
                classifier = config$classifier,
                precision = config$precision,
                ncomp = config$ncomp,
                seed = config$seed,
                replicate = config$replicate,
                status = "process_failed",
                error = paste("exit status", status),
                stringsAsFactors = FALSE
            )
            saveRDS(failure, result_file)
        }
    } else {
        cat(sprintf(
            "[%d/%d] %s [reused]\n",
            index,
            length(configs),
            config$run_id
        ))
    }

    row <- readRDS(result_file)
    if (identical(row$status, "success")) {
        # Explicit accelerator requests use strict dispatch; success proves
        # that the requested backend executed without a CPU fallback.
        row$backend_reported <- config$backend
    }
    row$peak_rss_mb <- parse_peak_rss(time_file)
    baseline_rss <- if (
        !is.null(row$baseline_rss_mb) &&
            length(row$baseline_rss_mb) == 1L
    ) {
        as.numeric(row$baseline_rss_mb)
    } else {
        NA_real_
    }
    row$incremental_peak_rss_mb <- if (
        is.finite(row$peak_rss_mb) && is.finite(baseline_rss)
    ) {
        max(0, row$peak_rss_mb - baseline_rss)
    } else {
        NA_real_
    }
    row$package_version <- as.character(packageVersion("fastPLS"))
    if (identical(row$status, "success") && config$backend != "cpu") {
        reported <- tolower(as.character(row$backend_reported))
        if (!identical(reported, config$backend)) {
            row$status <- "backend_mismatch"
            row$error <- paste0(
                "Requested ",
                config$backend,
                " but model reported ",
                reported,
                "; no fallback result accepted."
            )
        }
    }
    saveRDS(row, result_file)
    rows[[index]] <- row
    write.csv(row, sub("[.]rds$", ".csv", result_file), row.names = FALSE)
    if (index %% 10L == 0L || index == length(configs)) {
        write.csv(
            bind_rows(rows[seq_len(index)]),
            file.path(out_dir, "rerun_progress.csv"),
            row.names = FALSE
        )
    }
}

rerun <- bind_rows(rows)
write.csv(rerun, file.path(out_dir, "rerun_raw.csv"), row.names = FALSE)

original_raw <- read.csv(
    file.path(original_dir, "component_path_raw.csv"),
    stringsAsFactors = FALSE,
    check.names = FALSE
)
corrected <- bind_rows(list(
    original_raw[!original_raw$run_id %in% rerun$run_id, , drop = FALSE],
    rerun
))
corrected <- corrected[order(
    corrected$dataset,
    corrected$method,
    corrected$ncomp,
    corrected$backend_requested,
    corrected$replicate
), , drop = FALSE]
write.csv(
    corrected,
    file.path(out_dir, "component_path_raw_corrected.csv"),
    row.names = FALSE
)

group_columns <- c(
    "dataset", "task_type", "method", "backend_requested", "precision",
    "classifier", "svd_method", "ncomp"
)
missing_summary_columns <- setdiff(group_columns, names(corrected))
if (length(missing_summary_columns)) {
    stop(
        "Corrected component-path rows are missing summary columns: ",
        paste(missing_summary_columns, collapse = ", "),
        call. = FALSE
    )
}

finite_summary <- function(values, column, fun) {
    if (!column %in% names(values)) {
        return(NA_real_)
    }
    x <- suppressWarnings(as.numeric(values[[column]]))
    x <- x[is.finite(x)]
    if (length(x)) fun(x) else NA_real_
}

text_summary <- function(values, column, successful = TRUE) {
    if (!column %in% names(values)) {
        return("")
    }
    keep <- !is.na(values[[column]]) & nzchar(as.character(values[[column]]))
    if (successful) {
        keep <- keep & values$status == "success"
    }
    paste(unique(as.character(values[[column]][keep])), collapse = " | ")
}

keys <- unique(corrected[group_columns])
summary_rows <- lapply(seq_len(nrow(keys)), function(index) {
    key <- keys[index, , drop = FALSE]
    keep <- rep(TRUE, nrow(corrected))
    for (column in group_columns) {
        keep <- keep & corrected[[column]] == key[[column]][[1L]]
    }
    values <- corrected[keep, , drop = FALSE]
    ok <- !is.na(values$status) & values$status == "success"
    successful <- values[ok, , drop = FALSE]
    fresh <- if ("fresh_start" %in% names(successful)) {
        successful$fresh_start[!is.na(successful$fresh_start)]
    } else {
        logical()
    }
    data.frame(
        package_version = as.character(packageVersion("fastPLS")),
        key,
        n_ok = sum(ok),
        n_failed = sum(!ok),
        median_fit_sec = finite_summary(successful, "fit_sec", median),
        iqr_fit_sec = finite_summary(successful, "fit_sec", IQR),
        median_prediction_sec = finite_summary(
            successful, "prediction_sec", median
        ),
        iqr_prediction_sec = finite_summary(
            successful, "prediction_sec", IQR
        ),
        median_total_sec = finite_summary(successful, "total_sec", median),
        iqr_total_sec = finite_summary(successful, "total_sec", IQR),
        median_metric = finite_summary(successful, "metric_value", median),
        median_peak_rss_mb = finite_summary(
            successful, "peak_rss_mb", median
        ),
        median_incremental_rss_mb = finite_summary(
            successful, "incremental_peak_rss_mb", median
        ),
        control_profile = text_summary(successful, "control_profile"),
        oversample = finite_summary(successful, "oversample", max),
        power = finite_summary(successful, "power", max),
        direction_rule = text_summary(successful, "direction_rule"),
        fresh_start = if (length(fresh)) all(fresh %in% TRUE) else NA,
        errors = text_summary(values[!ok, , drop = FALSE], "error", FALSE),
        stringsAsFactors = FALSE,
        check.names = FALSE
    )
})
summary <- do.call(rbind, summary_rows)
write.csv(
    summary,
    file.path(out_dir, "component_path_summary.csv"),
    row.names = FALSE
)

writeLines(
    c(
        paste("created:", format(Sys.time(), tz = "UTC", usetz = TRUE)),
        paste("fastPLS:", as.character(packageVersion("fastPLS"))),
        paste("original_directory:", original_dir),
        paste("manifest:", manifest_path),
        paste("requested_reruns:", length(run_ids)),
        paste("completed_reruns:", nrow(rerun)),
        paste("successful_reruns:", sum(rerun$status == "success")),
        paste("failed_reruns:", sum(rerun$status != "success")),
        capture.output(sessionInfo())
    ),
    file.path(out_dir, "session_info.txt")
)

cat("Results:", normalizePath(out_dir), "\n")
