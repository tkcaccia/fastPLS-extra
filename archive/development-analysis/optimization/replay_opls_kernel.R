#!/usr/bin/env Rscript
# Replay every recorded fastPLS OPLS/kernel endpoint and fold, not references.
args <- commandArgs(trailingOnly = TRUE)
arg <- function(name, default = "") {
    hit <- args[startsWith(args, paste0("--", name, "="))]
    if (length(hit)) sub(paste0("--", name, "="), "", hit[[1L]], fixed = TRUE) else default
}
root <- normalizePath(arg("root", "."), mustWork = TRUE)
baseline <- arg("baseline")
if (nzchar(baseline)) baseline <- normalizePath(baseline, mustWork = TRUE)
output <- arg("out")
if (!nzchar(output)) stop("--out is required")
library <- Sys.getenv("FASTPLS_BENCH_LIB")
if (!nzchar(library) || grepl("frozen", library, ignore.case = TRUE)) stop("Use a current candidate library")
.libPaths(unique(c(library, .libPaths())))
suppressPackageStartupMessages(library(fastPLS))
stopifnot(normalizePath(find.package("fastPLS")) == normalizePath(file.path(library, "fastPLS")))
script <- sub("^--file=", "", grep("^--file=", commandArgs(), value = TRUE)[[1L]])
source(file.path(dirname(normalizePath(script)), "replay_helpers.R"))
helpers <- new.env(parent = .GlobalEnv)
helpers$seed <- 123L
load_replay_functions(file.path(root, "benchmark/benchmark_opls_kernel_estimator_validation.R"),
    c("make_cases", "make_folds", "subset_case"), helpers)
cases <- helpers$make_cases()
names(cases) <- vapply(cases, `[[`, "", "name")
load_replay_settings(file.path(root, "benchmark/benchmark_opls_kernel_setting_reliability.R"), helpers)
stored <- replay_setting_grid(cases, helpers$opls_settings, helpers$kernel_settings)
folds <- NULL
if (nzchar(baseline)) {
    previous <- read.csv(file.path(baseline, "opls_kernel_settings/opls_kernel_setting_reliability_raw.csv"))
    folds <- read.csv(file.path(baseline, "opls_kernel_settings/opls_kernel_setting_selection_fold_raw.csv"))
    if (nrow(previous) != 66L || nrow(folds) != 1540L) stop("The stored setting panel is incomplete")
    for (index in seq_len(nrow(stored))) {
        matched <- replay_stored_match(stored[index, , drop = FALSE], previous,
            c("case", "family", "setting", "ncomp", "n_train", "n_test", "p", "q"))
        stored[index, c("fast_metric", "reference_metric", "status")] <-
            matched[, c("fast_metric", "reference_metric", "status")]
    }
}
if (nrow(stored) != 66L) stop("The source-defined panel is not the expected 66 cases")
selected_cases <- strsplit(arg("cases", paste(names(cases), collapse = ",")), ",", fixed = TRUE)[[1L]]
if (!all(selected_cases %in% names(cases))) stop("Unknown case requested")
stored <- stored[stored$case %in% selected_cases, , drop = FALSE]
dir.create(output, recursive = TRUE, showWarnings = FALSE)
dir.create(file.path(output, "predictions"), showWarnings = FALSE)
writeLines(c(paste0("package: ", packageVersion("fastPLS")), paste0("library: ", library),
    paste0("cases: ", paste(selected_cases, collapse = ",")),
    "External estimators and frozen fastPLS: not executed",
    paste0("Stored metric table: ", if (nzchar(baseline)) baseline else "not loaded; comparison will be local"),
    "Reference prediction and coefficient vectors: not available",
    "Timing: descriptive current fit/prediction time, not an external timing comparison",
    "gasoline is loaded only as a dataset from the pls package"), file.path(output, "manifest.txt"))
endpoints <- fold_rows <- selections <- list()
write.csv(stored, file.path(output, "setting_manifest.csv"), row.names = FALSE)
for (i in seq_len(nrow(stored))) {
    row <- stored[i, , drop = FALSE]
    case <- cases[[row$case]]
    stopifnot(nrow(case$x_train) == row$n_train, nrow(case$x_test) == row$n_test,
        ncol(case$x_train) == row$p, case$ncomp == row$ncomp)
    message(sprintf("[%d/%d] %s/%s/%s", i, nrow(stored), row$case, row$family, row$setting))
    result <- replay_case_fit(case, row)
    keys <- row[c("case", "family", "setting", "task", "ncomp", "north", "kernel", "gamma", "degree", "coef0")]
    endpoints[[i]] <- replay_result_row(keys, result, row)
    replay_write_rows(endpoints, file.path(output, "endpoint_replay.csv"))
    if (!is.null(result$prediction)) saveRDS(list(observed = case$y_test,
        prediction = result$prediction, settings = keys),
        file.path(output, "predictions", paste0(i, ".rds")))
    assignment <- helpers$make_folds(case)
    local_folds <- list()
    for (component in seq_len(case$ncomp)) {
        for (fold in sort(unique(assignment))) {
            id <- data.frame(family = row$family, setting = row$setting,
                case = row$case, task = row$task, component = component, fold = fold)
            previous <- if (is.null(folds)) data.frame(fast_metric = NA_real_,
                reference_metric = NA_real_, status = "not_loaded") else
                replay_stored_match(id, folds, c("family", "setting", "case", "component", "fold"))
            subcase <- helpers$subset_case(case, which(assignment != fold),
                which(assignment == fold), component)
            current <- replay_case_fit(subcase, row)
            local_folds[[length(local_folds) + 1L]] <- replay_result_row(id, current, previous)
        }
    }
    values <- do.call(rbind, local_folds)
    fold_rows[[i]] <- values
    replay_write_rows(fold_rows, file.path(output, "fold_replay.csv"))
    complete <- all(values$status == "success") && all(is.finite(values$candidate_metric))
    candidate_selected <- frozen_selected <- reference_selected <- NA_integer_
    if (complete) {
        path <- aggregate(candidate_metric ~ component, values, mean)
        select <- if (identical(case$task, "classification")) which.max else which.min
        candidate_selected <- path$component[select(path$candidate_metric)]
        if (!is.null(folds)) {
            saved_path <- aggregate(cbind(frozen_fastpls_metric,
                stored_external_metric) ~ component, values, mean)
            frozen_selected <- saved_path$component[select(saved_path$frozen_fastpls_metric)]
            reference_selected <- saved_path$component[select(saved_path$stored_external_metric)]
        }
    }
    selections[[i]] <- data.frame(case = row$case, family = row$family,
        setting = row$setting, candidate_selected = candidate_selected,
        frozen_selected = frozen_selected, stored_external_selected = reference_selected,
        failed_fits = sum(values$status != "success"), complete = complete)
    replay_write_rows(selections, file.path(output, "selection_replay.csv"))
}
