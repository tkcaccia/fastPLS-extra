#!/usr/bin/env Rscript
# Candidate-only replay of the published SIMPLS task/seed/fold protocol.
# Stored external and frozen metrics are joined locally after execution.
args <- commandArgs(trailingOnly = TRUE)
arg <- function(name, default = "") {
    hit <- args[startsWith(args, paste0("--", name, "="))]
    if (length(hit)) sub(paste0("--", name, "="), "", hit[[1L]], fixed = TRUE) else default
}
root <- normalizePath(arg("root", "."), mustWork = TRUE)
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
helpers$root <- root
helpers$nmr_path <- normalizePath(arg("nmr"), mustWork = TRUE)
helpers$quick <- FALSE
sys.source(file.path(root, "benchmark/nmr_protocol_helpers.R"), envir = helpers)
definition <- file.path(root, "benchmark/benchmark_simpls_estimator_preservation.R")
load_replay_functions(definition, c("one_hot", "standardize_train_test",
    "make_synthetic_regression", "make_synthetic_classification", "prepare_breast",
    "prepare_colon", "prepare_metref", "prepare_nmr_subset", "with_validation_env",
    "make_folds", "slice_cube", "fast_prediction", "prediction_metric"), helpers)
probe <- helpers$fast_prediction(list(Ypred = array(0, c(2L, 2L, 1L))), 1L, 1L)
stopifnot(helpers$prediction_metric("regression", probe, matrix(0, 2L, 2L)) == 0)

# The source-defined data block has no estimator calls. Do not source the
# script: doing so would also execute the old external-comparator loop.
tasks <- load_simpls_replay_tasks(definition, helpers)
if (length(tasks) != 28L) stop("Expected all 28 source-defined tasks, found ", length(tasks))
requested <- strsplit(arg("tasks", paste(unique(vapply(tasks, `[[`, "", "dataset")), collapse = ",")), ",", fixed = TRUE)[[1L]]
if (!all(requested %in% vapply(tasks, `[[`, "", "dataset"))) stop("Unknown task requested")
tasks <- Filter(function(task) task$dataset %in% requested, tasks)
dir.create(output, recursive = TRUE, showWarnings = FALSE)
dir.create(file.path(output, "predictions"), showWarnings = FALSE)
manifest <- do.call(rbind, lapply(tasks, function(task) data.frame(
    dataset = task$dataset, source = task$source, task_type = task$task_type,
    condition = task$condition, seed = task$seed, n_train = nrow(task$Xtrain),
    n_test = nrow(task$Xtest), p = ncol(task$Xtrain), q = ncol(task$Ytrain),
    ncomp_grid = paste(task$ncomp_grid, collapse = ";"))))
write.csv(manifest, file.path(output, "task_manifest.csv"), row.names = FALSE)
writeLines(c(paste0("package: ", packageVersion("fastPLS")), paste0("library: ", library),
    "Only current fastPLS is fitted; frozen fastPLS and external estimators are not executed",
    "IRLBA and rSVD use the original source-defined output contract and folds",
    "rSVD oversample=32; power=5; seeds=1,7,19,43,123",
    "Timings are descriptive correctness-run measurements, not isolated publication timings",
    "Stored reference metrics are joined locally; their prediction vectors are unavailable"),
    file.path(output, "manifest.txt"))
if (identical(arg("prepare-only", "false"), "true")) quit(status = 0L)

fit_current <- function(task, solver, seed) {
    warnings <- character()
    begin <- proc.time()[["elapsed"]]
    fit <- tryCatch(withCallingHandlers(helpers$with_validation_env(fastPLS::pls(
        task$Xtrain, task$Ytrain, task$Xtest, task$Ytest,
        ncomp = sort(unique(task$ncomp_grid)), method = "simpls", backend = "cpu",
        svd.method = solver, oversample = 32L, power = 5L, scaling = "centering",
        fit = TRUE, return_variance = FALSE, return_loadings = TRUE, seed = seed
    )), warning = function(w) {
        warnings <<- c(warnings, conditionMessage(w))
        invokeRestart("muffleWarning")
    }), error = identity)
    list(fit = fit, elapsed = proc.time()[["elapsed"]] - begin,
        warnings = paste(unique(warnings), collapse = " | "))
}

metric_rows <- function(task, result, solver, seed, fold = NA_integer_) {
    grid <- sort(unique(task$ncomp_grid))
    do.call(rbind, lapply(seq_along(grid), function(index) {
        error <- if (inherits(result$fit, "error")) conditionMessage(result$fit) else ""
        metric <- NA_real_
        if (!nzchar(error)) {
            value <- tryCatch(helpers$prediction_metric(task$task_type,
                helpers$fast_prediction(result$fit, index, grid[index]),
                task$Ytest, task$labels_test), error = identity)
            if (inherits(value, "error")) error <- conditionMessage(value) else metric <- value
        }
        if (!nzchar(error) && !is.finite(metric)) error <- "nonfinite prediction metric"
        data.frame(dataset = task$dataset, source = task$source,
            task_type = task$task_type, condition = task$condition,
            seed = task$seed, solver = solver, randomized_seed = seed,
            rsvd_oversample = if (solver == "rsvd") 32L else NA_integer_,
            rsvd_power = if (solver == "rsvd") 5L else NA_integer_,
            ncomp = grid[index], n_train = nrow(task$Xtrain), n_test = nrow(task$Xtest),
            p = ncol(task$Xtrain), q = ncol(task$Ytrain), fold = fold,
            candidate_metric = metric, candidate_path_time_sec = result$elapsed,
            status = if (nzchar(error)) "error" else "success",
            warnings = result$warnings, error = error)
    }))
}

endpoints <- folds <- selections <- list()
runs <- data.frame(solver = c("irlba", rep("rsvd", 5L)),
    randomized_seed = c(NA_integer_, 1L, 7L, 19L, 43L, 123L))
for (task in tasks) {
    assignment <- helpers$make_folds(task)
    saveRDS(assignment, file.path(output, "predictions", paste0(task$dataset, "_", task$seed, "_folds.rds")))
    for (run in seq_len(nrow(runs))) {
        solver <- runs$solver[run]
        seed <- runs$randomized_seed[run]
        message(task$dataset, "/", task$seed, "/", solver, "/", seed)
        result <- fit_current(task, solver, seed)
        endpoints[[length(endpoints) + 1L]] <- metric_rows(task, result, solver, seed)
        replay_write_rows(endpoints, file.path(output, "endpoint_replay.csv"))
        if (!inherits(result$fit, "error")) saveRDS(list(
            observed = task$Ytest, labels = task$labels_test,
            prediction = result$fit$Ypred, coefficients = result$fit$B,
            scores = result$fit$Ttrain, projection = result$fit$R, loadings = result$fit$P),
            file.path(output, "predictions", paste0(task$dataset, "_", task$seed, "_", solver, "_", seed, ".rds")))
        if (!(task$source == "real" || task$seed == 101L)) next
        path <- list()
        for (fold in sort(unique(assignment))) {
            train <- which(assignment != fold)
            test <- which(assignment == fold)
            item <- task
            item$Xtrain <- task$Xtrain[train, , drop = FALSE]
            item$Ytrain <- task$Ytrain[train, , drop = FALSE]
            item$Xtest <- task$Xtrain[test, , drop = FALSE]
            item$Ytest <- task$Ytrain[test, , drop = FALSE]
            if (task$task_type == "classification") {
                item$labels_train <- droplevels(task$labels_train[train])
                item$labels_test <- factor(task$labels_train[test], levels = levels(task$labels_train))
            }
            path[[fold]] <- metric_rows(item, fit_current(item, solver, seed), solver, seed, fold)
        }
        values <- do.call(rbind, path)
        folds[[length(folds) + 1L]] <- values
        replay_write_rows(folds, file.path(output, "fold_replay.csv"))
        complete <- all(values$status == "success")
        selected <- selected_metric <- NA_real_
        if (complete) {
            curve <- aggregate(candidate_metric ~ ncomp, values, mean)
            choose <- if (task$task_type == "classification") which.max else which.min
            index <- choose(curve$candidate_metric)
            selected <- curve$ncomp[index]
            selected_metric <- curve$candidate_metric[index]
        }
        selections[[length(selections) + 1L]] <- data.frame(dataset = task$dataset,
            seed = task$seed, solver = solver, randomized_seed = seed,
            candidate_selected = selected, candidate_selected_metric = selected_metric,
            failed_fits = sum(tapply(values$status != "success", values$fold, any)),
            complete = complete)
        replay_write_rows(selections, file.path(output, "selection_replay.csv"))
    }
}
replay_check_completion(endpoints, folds, selections,
    sum(vapply(tasks, function(task) length(unique(task$ncomp_grid)), 0L)) * nrow(runs),
    sum(vapply(tasks, function(task) task$source == "real" || task$seed == 101L,
        FALSE)) * nrow(runs))
cat("All requested endpoint, fold, and selection measurements completed\n")
