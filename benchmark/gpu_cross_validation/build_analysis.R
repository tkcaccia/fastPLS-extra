#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 2L) {
    stop("Usage: build_analysis.R RAW_DIRECTORY OUTPUT_DIRECTORY")
}

raw_dir <- normalizePath(args[[1L]], mustWork = TRUE)
output_dir <- args[[2L]]
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

read_result <- function(path) {
    value <- read.csv(path, check.names = FALSE)
    value$source_file <- basename(path)
    if (!"workload" %in% names(value)) value$workload <- "cv"
    value
}

paths <- list.files(raw_dir, pattern = "\\.csv$", full.names = TRUE)
raw <- do.call(rbind, lapply(paths, read_result))
raw <- raw[raw$status == "ok" & is.finite(raw$elapsed_sec), , drop = FALSE]

summarize_rows <- function(part) {
    computer <- if (startsWith(part$source_file[[1L]], "mac_")) {
        "Apple M3"
    } else if (startsWith(part$source_file[[1L]], "linux_")) {
        "Intel i7-13700 / NVIDIA RTX 5060 Ti"
    } else {
        "unspecified"
    }
    data.frame(
        source_file = part$source_file[[1L]],
        computer = computer,
        implementation = part$implementation[[1L]],
        task = sub("_masked$", "", sub(
            "_task\\.rds$", "", part$task[[1L]]
        )),
        backend = part$backend[[1L]],
        precision = part$precision[[1L]],
        method = part$method[[1L]],
        classifier = part$classifier[[1L]],
        workload = part$workload[[1L]],
        selection_metric = part$selection_metric[[1L]],
        folds = part$folds[[1L]],
        component_grid = part$ncomp[[1L]],
        repetitions = nrow(part),
        median_sec = median(part$elapsed_sec),
        q1_sec = unname(quantile(part$elapsed_sec, 0.25)),
        q3_sec = unname(quantile(part$elapsed_sec, 0.75)),
        best_ncomp = paste(sort(unique(part$best_ncomp)), collapse = ";"),
        metric_min = min(part$best_metric),
        metric_max = max(part$best_metric),
        fold_signatures = length(unique(part$fold_signature)),
        prediction_signatures = length(unique(part$prediction_signature)),
        groups_preserved = all(part$groups_preserved),
        stringsAsFactors = FALSE
    )
}

summary <- do.call(rbind, lapply(split(raw, raw$source_file), summarize_rows))
summary <- summary[order(summary$task, summary$backend,
                         summary$classifier, summary$workload), ]
write.csv(
    summary, file.path(output_dir, "cv_runtime_summary.csv"), row.names = FALSE
)

lookup <- function(pattern) {
    hit <- summary[grepl(pattern, summary$source_file), , drop = FALSE]
    if (nrow(hit) != 1L) return(NULL)
    hit
}

ablation <- do.call(rbind, lapply(c("metal", "cuda"), function(backend) {
    prefix <- if (backend == "metal") "mac_metal" else "linux_cuda"
    do.call(rbind, lapply(c("argmax", "lda"), function(classifier) {
        baseline <- lookup(paste0("^", prefix, "_(cv_)?baseline_", classifier))
        candidate <- lookup(paste0("^", prefix, "_(cv_)?candidate_", classifier))
        if (is.null(baseline) || is.null(candidate)) return(NULL)
        data.frame(
            backend = backend,
            classifier = classifier,
            baseline_median_sec = baseline$median_sec,
            combined_path_median_sec = candidate$median_sec,
            speedup = baseline$median_sec / candidate$median_sec,
            metric_difference = candidate$metric_min - baseline$metric_min,
            identical_fold_signature =
                baseline$fold_signatures == 1L && candidate$fold_signatures == 1L,
            identical_prediction_signature =
                baseline$prediction_signatures == 1L &&
                candidate$prediction_signatures == 1L &&
                identical(
                    unique(raw$prediction_signature[
                        grepl(paste0("^", prefix, "_(cv_)?baseline_", classifier),
                              raw$source_file)
                    ]),
                    unique(raw$prediction_signature[
                        grepl(paste0("^", prefix, "_(cv_)?candidate_", classifier),
                              raw$source_file)
                    ])
                ),
            stringsAsFactors = FALSE
        )
    }))
}))
write.csv(
    ablation, file.path(output_dir, "cv_path_ablation_summary.csv"),
    row.names = FALSE
)

datasets <- c("metref", "retina", "cifar", "nmr")
accelerators <- c("metal", "cuda")
comparison <- do.call(rbind, lapply(datasets, function(dataset) {
    do.call(rbind, lapply(accelerators, function(accelerator) {
        machine <- if (accelerator == "metal") "mac" else "linux"
        cv <- lookup(paste0("^", machine, "_", accelerator, "_", dataset, "_cv"))
        one <- lookup(paste0("^", machine, "_", accelerator, "_", dataset,
                             "_onefold"))
        cpu <- lookup(paste0("^", machine, "_cpu_", dataset, "_cv"))
        if (is.null(cv)) return(NULL)
        data.frame(
            dataset = dataset,
            computer = cv$computer,
            backend = accelerator,
            repetitions = cv$repetitions,
            cv_median_sec = cv$median_sec,
            cv_q1_sec = cv$q1_sec,
            cv_q3_sec = cv$q3_sec,
            one_fold_median_sec = if (is.null(one)) NA_real_ else one$median_sec,
            cv_to_one_fold_ratio = if (is.null(one)) NA_real_ else {
                cv$median_sec / one$median_sec
            },
            same_host_cpu_cv_median_sec = if (is.null(cpu)) NA_real_ else {
                cpu$median_sec
            },
            cpu_to_accelerator_ratio = if (is.null(cpu)) NA_real_ else {
                cpu$median_sec / cv$median_sec
            },
            best_ncomp = cv$best_ncomp,
            metric_name = cv$selection_metric,
            metric_min = cv$metric_min,
            metric_max = cv$metric_max,
            deterministic_folds = cv$fold_signatures == 1L,
            deterministic_predictions = cv$prediction_signatures == 1L,
            groups_preserved = cv$groups_preserved,
            stringsAsFactors = FALSE
        )
    }))
}))
write.csv(
    comparison, file.path(output_dir, "cv_comparison_summary.csv"),
    row.names = FALSE
)

cat("Wrote", nrow(summary), "runtime summaries,", nrow(ablation),
    "path ablations, and", nrow(comparison), "CV comparisons.\n")
