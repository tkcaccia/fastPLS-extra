#!/usr/bin/env Rscript

# Training-only NMR component-path validation. Every package candidate receives
# the same fixed folds; the external test set is never read during selection.

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
source_id <- argument("source-id", "unrecorded")
backend <- match.arg(argument("backend", "cuda"), c("cpu", "cuda", "metal"))
precision <- match.arg(argument("precision", "float32"), c("float32", "float64"))
method <- match.arg(argument("method", "simpls"), c("plssvd", "simpls"))
components <- sort(unique(as.integer(strsplit(
    argument("components", "5,10,15,20,25,32,40,50,64,75,100,125,150,165"),
    ",", fixed = TRUE
)[[1L]])))
kfold <- as.integer(argument("kfold", "5"))
fold_seed <- as.integer(argument("fold-seed", "20260906"))
model_seed <- as.integer(argument("model-seed", "123"))
rsvd_oversample <- as.integer(argument("rsvd-oversample", "12"))
rsvd_power <- as.integer(argument("rsvd-power", "1"))
quiet <- identical(tolower(argument("quiet", "false")), "true")
if (!nzchar(output_path) || anyNA(c(
        components, kfold, fold_seed, model_seed, rsvd_oversample, rsvd_power
    )) || any(components < 1L) || kfold < 2L) {
    stop("Output path, components, folds, seeds, and rSVD controls must be valid")
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
X <- to_double(task$Xtrain)
Y <- to_double(task$Ytrain)
set.seed(fold_seed)
fold <- sample(rep(seq_len(kfold), length.out = nrow(X)))

convert <- if (precision == "float32") {
    function(value) float::fl(as.matrix(value))
} else {
    to_double
}
rows <- vector("list", kfold * length(components))
position <- 0L
for (fold_id in seq_len(kfold)) {
    validation <- which(fold == fold_id)
    training <- which(fold != fold_id)
    Xtrain <- convert(X[training, , drop = FALSE])
    Ytrain <- convert(Y[training, , drop = FALSE])
    Xvalidation <- convert(X[validation, , drop = FALSE])
    observed <- Y[validation, , drop = FALSE]
    training_mean <- colMeans(Y[training, , drop = FALSE])
    denominator <- sum(sweep(observed, 2L, training_mean, "-")^2)

    gc(full = TRUE)
    fit_seconds <- unname(system.time({
        model <- pls(
            Xtrain,
            Ytrain,
            ncomp = components,
            method = method,
            backend = backend,
            scaling = "centering",
            fit = FALSE,
            return_variance = FALSE,
            return_loadings = FALSE,
            rsvd_oversample = rsvd_oversample,
            rsvd_power = rsvd_power,
            seed = model_seed + fold_id
        )
    })[["elapsed"]])
    prediction_seconds <- unname(system.time({
        prediction <- predict(model, Xvalidation, backend = backend)$Ypred
    })[["elapsed"]])
    if (!is.list(prediction) && length(dim(prediction)) == 3L) {
        prediction <- lapply(seq_len(dim(prediction)[[3L]]), function(index) {
            value <- prediction[, , index, drop = FALSE]
            dim(value) <- dim(value)[1:2]
            value
        })
    } else if (!is.list(prediction)) {
        prediction <- list(prediction)
    }
    for (index in seq_along(components)) {
        estimate <- prediction[[index]]
        if (inherits(estimate, "float32")) estimate <- float::dbl(estimate)
        estimate <- as.matrix(estimate)
        residual <- estimate - observed
        position <- position + 1L
        rows[[position]] <- data.frame(
            package_version = as.character(packageVersion("fastPLS")),
            package_library = resolved_library,
            source_id = source_id,
            backend = backend,
            precision = precision,
            method = method,
            fold_seed = fold_seed,
            model_seed = model_seed + fold_id,
            fold = fold_id,
            training_n = length(training),
            validation_n = length(validation),
            ncomp = components[[index]],
            max_ncomp = max(components),
            refresh_block = model$diagnostics$resident_controls$refresh_block,
            oversample = model$diagnostics$rsvd$oversample,
            power = model$diagnostics$rsvd$power,
            fit_seconds = fit_seconds,
            prediction_seconds = prediction_seconds,
            SSE = sum(residual^2),
            denominator = denominator,
            RMSD = sqrt(mean(residual^2)),
            Q2 = 1 - sum(residual^2) / denominator,
            stringsAsFactors = FALSE
        )
    }
    rm(model, prediction, Xtrain, Ytrain, Xvalidation)
}

result <- do.call(rbind, rows)
dir.create(dirname(output_path), recursive = TRUE, showWarnings = FALSE)
write.csv(result, output_path, row.names = FALSE)
if (!quiet) print(result)
