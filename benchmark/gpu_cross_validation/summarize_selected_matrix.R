#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 3L) {
    stop("Usage: summarize_selected_matrix.R <linux-dir> <mac-dir> <output-dir>")
}

read_platform <- function(path, platform) {
    files <- list.files(path, pattern = "\\.csv$", recursive = TRUE,
        full.names = TRUE)
    files <- files[!grepl("configuration_manifest|summary|comparison", files)]
    rows <- lapply(files, function(file) {
        value <- tryCatch(read.csv(file, stringsAsFactors = FALSE),
            error = function(condition) NULL)
        if (is.null(value) || !nrow(value) || !"elapsed_sec" %in% names(value)) {
            return(NULL)
        }
        value$platform <- platform
        value$source_file <- basename(file)
        value
    })
    do.call(rbind, rows)
}

raw <- rbind(
    read_platform(args[[1L]], "linux_nvidia"),
    read_platform(args[[2L]], "mac_apple_silicon")
)
if (is.null(raw) || !nrow(raw)) stop("No result rows were found.")

raw$dataset <- sub("_task\\.rds$", "", raw$task)
raw$ok <- is.finite(raw$elapsed_sec) & raw$status != "error"
raw$control_profile <- "default_rsvd"
raw$oversample <- 32L
raw$power <- 5L
accelerated_family <- raw$method %in% c("simpls", "opls", "kernelpls")
massive_crosscov <- raw$p * raw$q * 4 > 512 * 1024^2
sparse_high_class <- !is.na(raw$classifier) & raw$q >= 32L & raw$n / raw$q <= 20
high_response <- is.na(raw$classifier) & raw$q >= 64L & raw$q / raw$n >= 0.2
raw$control_profile[accelerated_family] <- "ordinary_fast"
raw$control_profile[accelerated_family & high_response] <- "high_response_stable"
raw$oversample[accelerated_family & high_response] <- 48L
raw$power[accelerated_family & high_response] <- 6L
raw$control_profile[accelerated_family & sparse_high_class] <-
    "sparse_high_class_stable"
raw$oversample[accelerated_family & sparse_high_class] <- 64L
raw$power[accelerated_family & sparse_high_class] <- 7L
raw$control_profile[accelerated_family & massive_crosscov] <- "massive_rank_one"
raw$oversample[accelerated_family & massive_crosscov] <- 12L
raw$power[accelerated_family & massive_crosscov] <- 1L
raw$rsvd_seed <- 123L
keys <- c("platform", "dataset", "method", "backend", "workload",
    "precision", "ncomp", "folds", "control_profile", "oversample", "power",
    "rsvd_seed")
groups <- interaction(raw[keys], drop = TRUE, lex.order = TRUE)

summary_rows <- lapply(split(raw, groups), function(block) {
    elapsed <- block$elapsed_sec[block$ok]
    metrics <- block$best_metric[block$ok & is.finite(block$best_metric)]
    data.frame(
        platform = block$platform[[1L]],
        dataset = block$dataset[[1L]],
        method = block$method[[1L]],
        backend = block$backend[[1L]],
        workload = block$workload[[1L]],
        selection_metric = block$selection_metric[[1L]],
        precision = block$precision[[1L]],
        ncomp = block$ncomp[[1L]],
        folds = block$folds[[1L]],
        control_profile = block$control_profile[[1L]],
        oversample = block$oversample[[1L]],
        power = block$power[[1L]],
        rsvd_seed = block$rsvd_seed[[1L]],
        median_sec = if (length(elapsed)) median(elapsed) else NA_real_,
        q1_sec = if (length(elapsed)) unname(quantile(elapsed, 0.25)) else NA_real_,
        q3_sec = if (length(elapsed)) unname(quantile(elapsed, 0.75)) else NA_real_,
        median_metric = if (length(metrics)) median(metrics) else NA_real_,
        q1_metric = if (length(metrics)) {
            unname(quantile(metrics, 0.25))
        } else NA_real_,
        q3_metric = if (length(metrics)) {
            unname(quantile(metrics, 0.75))
        } else NA_real_,
        prediction_signatures = length(unique(
            block$prediction_signature[
                block$ok & !is.na(block$prediction_signature) &
                    nzchar(block$prediction_signature)
            ]
        )),
        completed = length(elapsed),
        attempted = nrow(block),
        status = if (length(elapsed) == nrow(block)) "success" else if (
            length(elapsed)) "partial" else "error",
        error = paste(unique(na.omit(block$error[nzchar(block$error)])), collapse = " | "),
        stringsAsFactors = FALSE
    )
})
summary <- do.call(rbind, summary_rows)

cv <- summary[summary$workload == "cv", ]
one <- summary[summary$workload == "one_fold", ]
pair_keys <- c("platform", "dataset", "method", "backend", "precision",
    "ncomp", "folds", "control_profile", "oversample", "power", "rsvd_seed")
naive <- merge(cv, one, by = pair_keys, suffixes = c("_cv", "_one"), all = TRUE)
naive$naive_kfold_sec <- naive$folds * naive$median_sec_one
naive$naive_over_cv <- naive$naive_kfold_sec / naive$median_sec_cv

cpu <- cv[cv$backend == "cpu", c("platform", "dataset", "method",
    "precision", "ncomp", "control_profile", "oversample", "power",
    "rsvd_seed", "median_sec", "median_metric")]
names(cpu)[[10L]] <- "cpu_cv_sec"
names(cpu)[[11L]] <- "cpu_metric"
gpu <- cv[cv$backend != "cpu", ]
accelerator <- merge(gpu, cpu,
    by = c("platform", "dataset", "method", "precision", "ncomp",
        "control_profile", "oversample", "power", "rsvd_seed"),
    all.x = TRUE)
accelerator$cpu_over_accelerator <- accelerator$cpu_cv_sec /
    accelerator$median_sec
accelerator$metric_difference <- accelerator$median_metric -
    accelerator$cpu_metric

dir.create(args[[3L]], recursive = TRUE, showWarnings = FALSE)
write.csv(raw, file.path(args[[3L]], "gpu_cv_raw_combined.csv"), row.names = FALSE)
write.csv(summary, file.path(args[[3L]], "gpu_cv_runtime_summary.csv"), row.names = FALSE)
write.csv(accelerator,
    file.path(args[[3L]], "gpu_cv_cpu_accelerator_comparison.csv"),
    row.names = FALSE)
write.csv(naive, file.path(args[[3L]], "gpu_cv_naive_kfold_comparison.csv"),
    row.names = FALSE)
