#!/usr/bin/env Rscript

# Compare fresh rank-one rSVD controls on the current masked NMR task. Input
# conversion happens before timing so precision comparisons cover fitting and
# prediction rather than representation conversion.

args <- commandArgs(trailingOnly = TRUE)
value <- function(name, default = NULL) {
    prefix <- paste0("--", name, "=")
    hit <- args[startsWith(args, prefix)]
    if (!length(hit)) {
        return(default)
    }
    substring(hit[[length(hit)]], nchar(prefix) + 1L)
}
`%||%` <- function(left, right) {
    if (is.null(left) || !length(left)) right else left
}

task_path <- normalizePath(value("task"), mustWork = TRUE)
output_path <- value("output", "nmr_power_audit.csv")
library_path <- value("library", "")
source_id <- value("source-id", "unrecorded")
backend <- match.arg(value("backend", "cpu"), c("cpu", "cuda", "metal"))
precision <- match.arg(value("precision", "float32"), c("float32", "float64"))
controls <- match.arg(value("controls", "automatic"), c("automatic", "explicit"))
families <- strsplit(
    value("families", "plssvd,simpls"), ",", fixed = TRUE
)[[1L]]
powers <- as.integer(strsplit(value("powers", "1,2"), ",", fixed = TRUE)[[1L]])
seeds <- as.integer(strsplit(value("seeds", "7,29,123"), ",", fixed = TRUE)[[1L]])
ncomp <- as.integer(value("ncomp", "50"))
oversample <- as.integer(value("oversample", "12"))

if (!nzchar(library_path)) stop("--library is required")
.libPaths(unique(c(library_path, .libPaths())))
suppressPackageStartupMessages(library(fastPLS))
resolved_library <- normalizePath(find.package("fastPLS"), mustWork = TRUE)
requested_library <- normalizePath(library_path, mustWork = TRUE)
if (!startsWith(resolved_library, paste0(requested_library, .Platform$file.sep))) {
    stop("Loaded fastPLS outside the requested library: ", resolved_library)
}
if (backend == "cuda" && !isTRUE(has_cuda())) {
    stop("CUDA is unavailable")
}
if (backend == "metal" && !isTRUE(has_metal())) {
    stop("Metal is unavailable")
}
if (backend == "metal" && precision == "float64") {
    stop("Metal has no native float64 route")
}

task <- readRDS(task_path)
if (precision == "float32") {
    task$Xtrain <- float::fl(as.matrix(task$Xtrain))
    task$Ytrain <- float::fl(as.matrix(task$Ytrain))
    task$Xtest <- float::fl(as.matrix(task$Xtest))
    task$Ytest <- float::fl(as.matrix(task$Ytest))
} else {
    task$Xtrain <- as.matrix(task$Xtrain)
    task$Ytrain <- as.matrix(task$Ytrain)
    task$Xtest <- as.matrix(task$Xtest)
    task$Ytest <- as.matrix(task$Ytest)
}

prediction_matrix <- function(object) {
    prediction <- object$Ypred
    if (is.list(prediction)) {
        prediction <- prediction[[length(prediction)]]
    }
    if (length(dim(prediction)) == 3L) {
        prediction <- prediction[, , dim(prediction)[[3L]], drop = FALSE]
        dim(prediction) <- dim(prediction)[1:2]
    }
    if (inherits(prediction, "float32")) {
        prediction <- float::dbl(prediction)
    }
    as.matrix(prediction)
}

observed <- if (inherits(task$Ytest, "float32")) {
    float::dbl(task$Ytest)
} else {
    task$Ytest
}
training_response_mean <- colMeans(if (inherits(task$Ytrain, "float32")) {
    float::dbl(task$Ytrain)
} else {
    task$Ytrain
})
centered_observed <- sweep(observed, 2L, training_response_mean, "-")
rows <- list()
index <- 0L
for (family in families) {
    active_powers <- if (identical(controls, "automatic")) NA_integer_ else powers
    for (power in active_powers) {
        for (seed in seeds) {
            index <- index + 1L
            gc(full = TRUE)
            set.seed(seed)
            fit_seconds <- unname(system.time({
                arguments <- list(
                    Xtrain = task$Xtrain,
                    Ytrain = task$Ytrain,
                    ncomp = ncomp,
                    method = family,
                    backend = backend,
                    classifier = "argmax",
                    scaling = "centering",
                    fit = FALSE,
                    return_variance = FALSE,
                    seed = seed
                )
                if (identical(controls, "explicit")) {
                    arguments$oversample <- oversample
                    arguments$power <- power
                }
                model <- do.call(pls, arguments)
            })[["elapsed"]])
            prediction_seconds <- unname(system.time({
                prediction <- predict(
                    model,
                    task$Xtest,
                    backend = backend
                )
            })[["elapsed"]])
            predicted <- prediction_matrix(prediction)
            residual <- predicted - observed
            diagnostics <- model$diagnostics$rsvd
            internal <- attr(model, "fastPLS_internal", exact = TRUE)
            index_controls <- model$diagnostics$resident_controls
            index_controls <- index_controls %||% list()
            index_controls$effective_oversample <-
                index_controls$effective_oversample %||% diagnostics$oversample
            index_controls$effective_power <-
                index_controls$effective_power %||% diagnostics$power
            index_controls$refresh_block <-
                index_controls$refresh_block %||% 1L
            rows[[index]] <- data.frame(
                package_version = as.character(packageVersion("fastPLS")),
                package_library = resolved_library,
                source_id = source_id,
                dataset = task$dataset,
                family = family,
                backend = backend,
                precision = precision,
                ncomp = ncomp,
                control_mode = controls,
                control_profile = diagnostics$control_profile %||% NA_character_,
                requested_oversample = if (identical(controls, "explicit")) {
                    oversample
                } else {
                    diagnostics$requested_oversample %||% NA_integer_
                },
                requested_power = if (identical(controls, "explicit")) {
                    power
                } else {
                    diagnostics$requested_power %||% NA_integer_
                },
                effective_oversample = index_controls$effective_oversample,
                effective_power = index_controls$effective_power,
                refresh_block = index_controls$refresh_block,
                seed = seed,
                fit_sec = fit_seconds,
                prediction_sec = prediction_seconds,
                total_sec = fit_seconds + prediction_seconds,
                RMSD = sqrt(mean(residual^2)),
                Q2 = 1 - sum(residual^2) / sum(centered_observed^2),
                gpu_resident = isTRUE(internal$gpu_resident),
                execution_route = model$diagnostics$residency$route %||%
                    "CPU",
                algorithm_variant = model$diagnostics$algorithm_variant %||%
                    NA_character_,
                status = "success",
                stringsAsFactors = FALSE
            )
            rm(model, prediction, predicted, residual)
        }
    }
}

result <- do.call(rbind, rows)
dir.create(dirname(output_path), recursive = TRUE, showWarnings = FALSE)
write.csv(result, output_path, row.names = FALSE)
print(result)
