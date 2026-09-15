#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 4L) {
    stop(
        "Usage: export_nmr_figure3_predictions.R LIB TASK PLATFORM OUTPUT_DIR",
        call. = FALSE
    )
}

library_path <- normalizePath(args[[1L]], mustWork = TRUE)
task_path <- normalizePath(args[[2L]], mustWork = TRUE)
platform <- match.arg(args[[3L]], c("linux", "mac"))
output_dir <- args[[4L]]
expected_version <- Sys.getenv("FASTPLS_EXPECTED_VERSION", unset = "0.99.66")

.libPaths(unique(c(library_path, .libPaths())))
suppressPackageStartupMessages(library(fastPLS))
if (!identical(as.character(packageVersion("fastPLS")), expected_version)) {
    stop("Expected fastPLS ", expected_version, ".", call. = FALSE)
}
if (platform == "linux" && !isTRUE(has_cuda())) {
    stop("CUDA is unavailable; no CPU fallback is permitted.", call. = FALSE)
}
if (platform == "mac" && !isTRUE(has_metal())) {
    stop("Metal is unavailable; no CPU fallback is permitted.", call. = FALSE)
}

task <- readRDS(task_path)
required <- c("Xtrain", "Ytrain", "Xtest", "Ytest")
if (!all(required %in% names(task))) {
    stop("The NMR task is incomplete.", call. = FALSE)
}
to_float <- function(value) {
    if (inherits(value, "float32")) value else float::fl(as.matrix(value))
}
Xtrain <- to_float(task$Xtrain)
Xtest <- to_float(task$Xtest)
Ytrain <- to_float(task$Ytrain)
Ytest <- to_float(task$Ytest)
rm(task)
invisible(gc(full = TRUE))

specifications <- data.frame(
    family = rep(c("plssvd", "simpls"), each = 2L),
    backend = rep(if (platform == "linux") c("cpu", "cuda") else c("cpu", "metal"), 2L),
    ncomp = rep(c(100L, 50L), each = 2L),
    stringsAsFactors = FALSE
)
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

for (index in seq_len(nrow(specifications))) {
    specification <- specifications[index, ]
    message(
        "Exporting ", specification$family, "/", specification$backend,
        " at ", specification$ncomp, " components"
    )
    fit <- suppressWarnings(pls(
        Xtrain,
        Ytrain,
        ncomp = specification$ncomp,
        method = specification$family,
        backend = specification$backend,
        fit = FALSE,
        proj = FALSE,
        return_variance = FALSE,
        return_loadings = FALSE,
        seed = 123L
    ))
    prediction <- predict(fit, Xtest, backend = specification$backend)$Ypred
    if (is.list(prediction)) prediction <- prediction[[length(prediction)]]
    if (length(dim(prediction)) == 3L) {
        prediction <- prediction[, , dim(prediction)[[3L]], drop = TRUE]
    }
    if (inherits(prediction, "float32")) prediction <- float::dbl(prediction)
    observed <- float::dbl(Ytest)
    prediction <- as.matrix(prediction)
    observed <- as.matrix(observed)
    if (!identical(dim(prediction), dim(observed))) {
        stop("Prediction dimensions do not match the held-out response.")
    }

    internal <- attr(fit, "fastPLS_internal", exact = TRUE)
    route <- fit$diagnostics$residency$route
    if (is.null(route) || !length(route)) route <- internal$execution_route
    route_matches <- switch(
        specification$backend,
        cpu = grepl("CPU", route, ignore.case = TRUE) &&
            !grepl("CUDA|Metal", route, ignore.case = TRUE),
        cuda = grepl("CUDA", route, ignore.case = TRUE),
        metal = grepl("Metal", route, ignore.case = TRUE),
        FALSE
    )
    if (!isTRUE(route_matches)) {
        stop(
            "Requested ", specification$backend,
            " but the fit reported route '", route, "'."
        )
    }

    retain_spectrum <- platform == "linux" &&
        specification$family == "simpls" && specification$backend == "cpu"
    result <- list(
        package_version = as.character(packageVersion("fastPLS")),
        source_id = "3854e369c1f0cd615e58b968b7721efb4b2a3146",
        platform = platform,
        family = specification$family,
        backend = specification$backend,
        precision = "float32",
        ncomp = specification$ncomp,
        seed = 123L,
        execution_route = route,
        per_sample_rmsd = sqrt(rowMeans((observed - prediction)^2)),
        per_response_rmsd = sqrt(colMeans((observed - prediction)^2)),
        observed = if (retain_spectrum) observed else NULL,
        predicted = if (retain_spectrum) prediction else NULL,
        diagnostics = fit$diagnostics
    )
    stem <- paste("nmr", specification$family, specification$backend,
                  paste0("k", specification$ncomp), sep = "_")
    saveRDS(result, file.path(output_dir, paste0(stem, "_prediction.rds")),
            compress = FALSE)
    rm(fit, prediction, observed, result)
    invisible(gc(full = TRUE))
}
