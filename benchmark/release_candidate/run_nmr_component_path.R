#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
argument <- function(name, default = NULL) {
    prefix <- paste0("--", name, "=")
    hit <- args[startsWith(args, prefix)]
    if (!length(hit)) return(default)
    substring(hit[[length(hit)]], nchar(prefix) + 1L)
}

task_path <- normalizePath(argument("task"), mustWork = TRUE)
library_path <- normalizePath(argument("library"), mustWork = TRUE)
output_path <- argument("output")
backend <- match.arg(argument("backend", "cuda"), c("cpu", "cuda", "metal"))
precision <- match.arg(argument("precision", "float32"), c("float32", "float64"))
method <- match.arg(argument("method", "simpls"), c("plssvd", "simpls"))
components <- as.integer(strsplit(
    argument("components", "5,10,20,30,40,50,75,100,125,150,165"),
    ",", fixed = TRUE
)[[1L]])
seeds <- as.integer(strsplit(
    argument("seeds", "7,29,123"), ",", fixed = TRUE
)[[1L]])
source_id <- argument("source-id", "unrecorded")
if (!nzchar(output_path) || anyNA(components) || anyNA(seeds)) {
    stop("--output, --components, and --seeds must be valid")
}

.libPaths(unique(c(library_path, .libPaths())))
suppressPackageStartupMessages(library(fastPLS))
resolved_library <- normalizePath(find.package("fastPLS"), mustWork = TRUE)
if (!startsWith(resolved_library, paste0(library_path, .Platform$file.sep))) {
    stop("Loaded fastPLS outside the requested library: ", resolved_library)
}

task <- readRDS(task_path)
to_double <- function(value) {
    if (inherits(value, "float32")) value <- float::dbl(value)
    value <- as.matrix(value)
    storage.mode(value) <- "double"
    value
}
if (precision == "float32") {
    task$Xtrain <- float::fl(as.matrix(task$Xtrain))
    task$Ytrain <- float::fl(as.matrix(task$Ytrain))
    task$Xtest <- float::fl(as.matrix(task$Xtest))
} else {
    task$Xtrain <- to_double(task$Xtrain)
    task$Ytrain <- to_double(task$Ytrain)
    task$Xtest <- to_double(task$Xtest)
}
observed <- to_double(task$Ytest)
training_mean <- colMeans(to_double(task$Ytrain))
q2_denominator <- sum(sweep(observed, 2L, training_mean, "-")^2)

prediction_at <- function(prediction, component, index) {
    key <- paste0("ncomp=", component)
    if (is.list(prediction)) {
        value <- if (key %in% names(prediction)) prediction[[key]] else prediction[[index]]
    } else if (length(dim(prediction)) == 3L) {
        value <- prediction[, , index, drop = TRUE]
    } else {
        value <- prediction
    }
    to_double(value)
}

rows <- list()
position <- 0L
for (seed in seeds) {
    gc(full = TRUE)
    set.seed(seed)
    fit_seconds <- unname(system.time({
        model <- pls(
            task$Xtrain,
            task$Ytrain,
            ncomp = components,
            method = method,
            backend = backend,
            scaling = "centering",
            fit = FALSE,
            return_variance = FALSE,
            return_loadings = FALSE,
            seed = seed
        )
    })[["elapsed"]])
    prediction_seconds <- unname(system.time({
        prediction <- predict(model, task$Xtest, backend = backend)$Ypred
    })[["elapsed"]])
    refresh_block <- model$diagnostics$resident_controls$refresh_block
    for (index in seq_along(components)) {
        estimate <- prediction_at(prediction, components[[index]], index)
        residual <- estimate - observed
        position <- position + 1L
        rows[[position]] <- data.frame(
            package_version = as.character(packageVersion("fastPLS")),
            package_library = resolved_library,
            source_id = source_id,
            backend = backend,
            precision = precision,
            method = method,
            seed = seed,
            ncomp = components[[index]],
            max_ncomp = max(components),
            refresh_block = refresh_block,
            fit_seconds = fit_seconds,
            prediction_seconds = prediction_seconds,
            total_seconds = fit_seconds + prediction_seconds,
            RMSD = sqrt(mean(residual^2)),
            Q2 = 1 - sum(residual^2) / q2_denominator,
            stringsAsFactors = FALSE
        )
    }
}

result <- do.call(rbind, rows)
dir.create(dirname(output_path), recursive = TRUE, showWarnings = FALSE)
write.csv(result, output_path, row.names = FALSE)
print(result)
