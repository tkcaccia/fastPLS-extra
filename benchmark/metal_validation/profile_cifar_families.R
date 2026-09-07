#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
library_path <- args[[1L]]
task_path <- args[[2L]]
selection_path <- args[[3L]]
output_path <- args[[4L]]

.libPaths(unique(c(library_path, .libPaths())))
suppressPackageStartupMessages(library(fastPLS))
if (!has_metal()) stop("Metal is unavailable", call. = FALSE)

task <- readRDS(task_path)
selected <- read.csv(selection_path, stringsAsFactors = FALSE)
selected <- selected[selected$dataset == "cifar100", , drop = FALSE]
Xtrain <- float::fl(as.matrix(task$Xtrain))
Xtest <- float::fl(as.matrix(task$Xtest))
profile_seed <- as.integer(Sys.getenv("PROFILE_SEED", "123"))

run_once <- function(family, backend, replicate_id) {
    ncomp <- selected$selected_ncomp[selected$method == family]
    gc(full = TRUE)
    fit_elapsed <- system.time({
        fit <- pls(
            Xtrain,
            task$Ytrain,
            ncomp = ncomp,
            method = family,
            backend = backend,
            classifier = "argmax",
            fit = FALSE,
            proj = FALSE,
            return_variance = FALSE,
            return_loadings = FALSE,
            oversample = 32L,
            power = 5L,
            seed = profile_seed
        )
    })[["elapsed"]]
    prediction_elapsed <- system.time({
        predicted <- predict(fit, Xtest, backend = backend)$Ypred
    })[["elapsed"]]
    if (is.list(predicted)) predicted <- predicted[[length(predicted)]]
    data.frame(
        family = family,
        backend = backend,
        replicate = replicate_id,
        seed = profile_seed,
        ncomp = ncomp,
        fit_sec = fit_elapsed,
        prediction_sec = prediction_elapsed,
        total_sec = fit_elapsed + prediction_elapsed,
        accuracy = mean(as.character(predicted) == as.character(task$Ytest))
    )
}

families <- strsplit(
    Sys.getenv("PROFILE_FAMILIES", "plssvd,simpls,opls,kernelpls"),
    ",",
    fixed = TRUE
)[[1L]]
repetitions <- as.integer(Sys.getenv("PROFILE_REPETITIONS", "5"))
results <- do.call(rbind, lapply(families, function(family) {
    do.call(rbind, c(
        lapply(seq_len(repetitions), function(i) run_once(family, "metal", i)),
        lapply(seq_len(repetitions), function(i) run_once(family, "cpu", i))
    ))
}))
dir.create(dirname(output_path), recursive = TRUE, showWarnings = FALSE)
write.csv(results, output_path, row.names = FALSE)
print(results)
