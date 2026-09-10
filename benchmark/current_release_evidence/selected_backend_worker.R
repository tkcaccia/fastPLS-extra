#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 13L) {
    stop(paste(
        "Usage: selected_backend_worker.R LIB TASK FAMILY BACKEND NCOMP",
        paste(
            "REPLICATE OUTPUT READY GO SOURCE_ID PRECISION",
            "EXPECTED_VERSION CLASSIFIER"
        )
    ), call. = FALSE)
}

library_path <- args[[1L]]
task_path <- args[[2L]]
family <- args[[3L]]
backend <- args[[4L]]
ncomp <- as.integer(args[[5L]])
replicate_id <- as.integer(args[[6L]])
output <- args[[7L]]
ready <- args[[8L]]
go <- args[[9L]]
source_id <- args[[10L]]
precision <- args[[11L]]
expected_version <- args[[12L]]
classifier <- match.arg(args[[13L]], c("argmax", "lda"))

.libPaths(unique(c(library_path, .libPaths())))
suppressPackageStartupMessages(library(fastPLS))
resolved_library <- normalizePath(find.package("fastPLS"), mustWork = TRUE)
requested_library <- normalizePath(library_path, mustWork = TRUE)
if (!startsWith(resolved_library, paste0(requested_library, .Platform$file.sep))) {
    stop("fastPLS was loaded outside the requested library", call. = FALSE)
}
if (!identical(as.character(packageVersion("fastPLS")), expected_version)) {
    stop(
        "selected backend benchmark requires fastPLS ", expected_version,
        call. = FALSE
    )
}
`%||%` <- function(left, right) {
    if (is.null(left) || !length(left)) right else left
}

task <- readRDS(task_path)
required <- c("Xtrain", "Ytrain", "Xtest", "Ytest")
if (!is.list(task) || !all(required %in% names(task))) {
    stop("Prepared task is missing a required matrix or response", call. = FALSE)
}
if (identical(task$dataset, "tabula")) {
    labels <- c(as.character(task$Ytrain), as.character(task$Ytest))
    expected_counts <- c(
        droplet_Bladder = 2500L, droplet_Heart_and_Aorta = 624L,
        droplet_Kidney = 2777L, droplet_Limb_Muscle = 4536L,
        droplet_Liver = 1845L, droplet_Lung = 5449L,
        droplet_Mammary_Gland = 4478L, droplet_Marrow = 3651L,
        droplet_Spleen = 9552L, droplet_Thymus = 1429L,
        droplet_Tongue = 7537L, droplet_Trachea = 11269L,
        facs_Aorta = 406L, facs_Bladder = 1355L,
        facs_Brain_Myeloid = 4455L, `facs_Brain_Non-Myeloid` = 3372L,
        facs_Diaphragm = 870L, facs_Fat = 4955L, facs_Heart = 4364L,
        facs_Kidney = 519L, facs_Large_Intestine = 3708L,
        facs_Limb_Muscle = 1090L, facs_Liver = 585L, facs_Lung = 1716L,
        facs_Mammary_Gland = 2402L, facs_Marrow = 5021L,
        facs_Pancreas = 1536L, facs_Skin = 2303L, facs_Spleen = 1697L,
        facs_Thymus = 1349L, facs_Tongue = 1402L,
        facs_Trachea = 1350L
    )
    observed_counts <- table(labels)
    tabula_valid <- length(labels) == 100102L && task$p == 50L &&
        length(unique(labels)) == 32L && !anyNA(labels) &&
        !any(!nzchar(trimws(labels))) && identical(
            as.integer(observed_counts[names(expected_counts)]),
            unname(expected_counts)
        )
    if (!tabula_valid) {
        stop(
            paste(
                "Tabula Muris benchmark requires the verified",
                "100,102-cell, 32-class PCA50 task."
            ),
            call. = FALSE
        )
    }
}
classification <- is.factor(task$Ytrain)
to_float <- function(value) {
    if (inherits(value, "float32")) value else float::fl(as.matrix(value))
}
to_double <- function(value) {
    if (inherits(value, "float32")) float::dbl(value) else as.matrix(value)
}
if (precision == "float32") {
    task$Xtrain <- to_float(task$Xtrain)
    task$Xtest <- to_float(task$Xtest)
    if (!classification) {
        task$Ytrain <- to_float(task$Ytrain)
        task$Ytest <- to_float(task$Ytest)
    }
} else if (precision == "float64") {
    task$Xtrain <- to_double(task$Xtrain)
    task$Xtest <- to_double(task$Xtest)
    if (!classification) {
        task$Ytrain <- to_double(task$Ytrain)
        task$Ytest <- to_double(task$Ytest)
    }
} else {
    stop("precision must be float32 or float64", call. = FALSE)
}

rss_mib <- function() {
    as.numeric(ps::ps_memory_info(ps::ps_handle())[["rss"]]) / 1024^2
}
invisible(gc(full = TRUE))
writeLines(format(rss_mib(), digits = 15L), ready)
while (!file.exists(go)) Sys.sleep(0.01)

fit_time <- system.time({
    fit <- pls(
        task$Xtrain, task$Ytrain,
        ncomp = ncomp,
        method = family,
        backend = backend,
        classifier = classifier,
        kernel = "linear",
        north = 1L,
        fit = FALSE,
        proj = FALSE,
        return_variance = FALSE,
        return_loadings = FALSE,
        seed = 123L
    )
})[["elapsed"]]
prediction_time <- system.time({
    prediction <- predict(fit, task$Xtest, backend = backend)$Ypred
})[["elapsed"]]
if (is.list(prediction)) prediction <- prediction[[length(prediction)]]
if (length(dim(prediction)) == 3L) {
    prediction <- prediction[, , dim(prediction)[[3L]], drop = TRUE]
}
if (classification) {
    metric_name <- "accuracy"
    metric_value <- mean(as.character(prediction) == as.character(task$Ytest))
} else {
    if (inherits(prediction, "float32")) prediction <- float::dbl(prediction)
    observed <- task$Ytest
    if (inherits(observed, "float32")) observed <- float::dbl(observed)
    metric_name <- "RMSD"
    metric_value <- sqrt(mean((as.matrix(prediction) - as.matrix(observed))^2))
}
internal <- attr(fit, "fastPLS_internal", exact = TRUE)
controls <- fit$diagnostics$metal_operation_split
if (is.null(controls)) controls <- fit$diagnostics$resident_controls
if (is.null(controls)) controls <- fit$diagnostics$simpls
if (is.null(controls)) controls <- fit$diagnostics$rsvd
row <- data.frame(
    package_version = as.character(packageVersion("fastPLS")),
    package_library = resolved_library,
    source_id = source_id,
    dataset = task$dataset,
    family = family,
    backend = backend,
    precision = precision,
    classifier = classifier,
    ncomp = ncomp,
    seed = 123L,
    replicate = replicate_id,
    fit_sec = fit_time,
    prediction_sec = prediction_time,
    total_sec = fit_time + prediction_time,
    metric_name = metric_name,
    metric_value = metric_value,
    prefit_rss_mib = as.numeric(readLines(ready, warn = FALSE)[[1L]]),
    final_rss_mib = rss_mib(),
    execution_route = fit$diagnostics$residency$route %||%
        internal$resident_backend %||% "compiled CPU",
    refresh_block = controls$refresh_block %||%
        controls$candidate_block_size %||% NA_integer_,
    effective_oversample = controls$effective_oversample %||%
        controls$case_audit$max_effective_oversample %||%
        controls$oversample %||% NA_integer_,
    effective_power = controls$effective_power %||%
        controls$case_audit$max_effective_power %||%
        controls$power %||% NA_integer_,
    status = "success",
    stringsAsFactors = FALSE
)
dir.create(dirname(output), recursive = TRUE, showWarnings = FALSE)
write.csv(row, output, row.names = FALSE)
