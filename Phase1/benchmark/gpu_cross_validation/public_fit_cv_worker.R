#!/usr/bin/env Rscript

`%||%` <- function(left, right) {
    if (is.null(left) || !length(left)) right else left
}

parse_args <- function(values = commandArgs(trailingOnly = TRUE)) {
    result <- list()
    for (entry in values) {
        if (!startsWith(entry, "--")) next
        fields <- strsplit(substring(entry, 3L), "=", fixed = TRUE)[[1L]]
        result[[gsub("-", "_", fields[[1L]], fixed = TRUE)]] <-
            paste(fields[-1L], collapse = "=")
    }
    result
}

args <- parse_args()
required <- c("library", "task", "output", "backend", "workload")
missing <- required[!vapply(required, function(name) {
    is.character(args[[name]]) && nzchar(args[[name]])
}, logical(1L))]
if (length(missing)) stop("Missing --", paste(missing, collapse = ", --"))
value <- function(name, default) args[[name]] %||% default

.libPaths(unique(c(args$library, .libPaths())))
suppressPackageStartupMessages(library(fastPLS))
loaded_path <- normalizePath(find.package("fastPLS"), mustWork = TRUE)
requested_path <- normalizePath(args$library, mustWork = TRUE)
if (!startsWith(loaded_path, paste0(requested_path, .Platform$file.sep))) {
    stop("fastPLS was loaded outside the requested library")
}

task_path <- normalizePath(args$task, mustWork = TRUE)
workload <- match.arg(args$workload, c("fit_predict", "cv"))
task <- readRDS(task_path)
if (!all(c("Xtrain", "Xtest") %in% names(task)) &&
        all(c("Xtrain_rds", "Xtest_rds") %in% names(task))) {
    task$Xtrain <- readRDS(task$Xtrain_rds)
    if (identical(workload, "fit_predict")) {
        task$Xtest <- readRDS(task$Xtest_rds)
    }
}
required_task <- c("Xtrain", "Ytrain")
if (identical(workload, "fit_predict")) {
    required_task <- c(required_task, "Xtest", "Ytest")
}
if (!all(required_task %in% names(task))) {
    stop("Task must contain training and test predictors and responses")
}
task$dataset <- value("dataset_id", task$dataset %||%
    sub("_task\\.rds$", "", basename(task_path)))

precision <- match.arg(value("precision", "float32"),
    c("float32", "float64"))
backend <- match.arg(args$backend, c("cpu", "cuda", "metal"))
method <- match.arg(value("method", "simpls"),
    c("plssvd", "simpls", "opls", "kernelpls"))
classifier <- match.arg(value("classifier", "argmax"), c("argmax", "lda"))
kernel <- match.arg(value("kernel", "linear"), c("linear", "rbf", "poly"))
ncomp <- as.integer(strsplit(value("ncomp", "10"), ",", fixed = TRUE)[[1L]])
kfold <- as.integer(value("kfold", "10"))
seed <- as.integer(value("seed", "123"))
replicate <- as.integer(value("replicate", "1"))
n.cores <- as.integer(value("n.cores", "1"))
north <- as.integer(value("north", "1"))

options(n.cores = n.cores)
fastPLS:::.fastpls_require_backend_available(
    backend, "fit-versus-cross-validation benchmark"
)
classification <- is.factor(task$Ytrain) || is.character(task$Ytrain)
if (classification) {
    task$Ytrain <- droplevels(factor(task$Ytrain))
    if (identical(workload, "fit_predict")) {
        task$Ytest <- factor(task$Ytest, levels = levels(task$Ytrain))
    }
}

as_float <- function(x) {
    if (inherits(x, "float32")) x else float::fl(as.matrix(x))
}
as_double <- function(x) {
    if (inherits(x, "float32")) float::dbl(x) else as.matrix(x)
}
if (identical(precision, "float32")) {
    task$Xtrain <- as_float(task$Xtrain)
    if (identical(workload, "fit_predict")) {
        task$Xtest <- as_float(task$Xtest)
    }
    if (!classification) {
        task$Ytrain <- as_float(task$Ytrain)
        if (identical(workload, "fit_predict")) {
            task$Ytest <- as_float(task$Ytest)
        }
    }
} else {
    task$Xtrain <- as_double(task$Xtrain)
    if (identical(workload, "fit_predict")) {
        task$Xtest <- as_double(task$Xtest)
    }
    if (!classification) {
        task$Ytrain <- as_double(task$Ytrain)
        if (identical(workload, "fit_predict")) {
            task$Ytest <- as_double(task$Ytest)
        }
    }
}

constrain <- task$constrain_train %||% task$constrain %||%
    seq_len(nrow(task$Xtrain))
if (length(constrain) != nrow(task$Xtrain)) {
    stop("constrain must contain one value per training observation")
}
selection <- if (classification) "accuracy" else "RMSD"

rss_mib <- function() {
    as.numeric(ps::ps_memory_info(ps::ps_handle())[["rss"]]) / 1024^2
}
fingerprint <- function(object) {
    if (is.null(object)) return(NA_character_)
    path <- tempfile(fileext = ".rds")
    on.exit(unlink(path), add = TRUE)
    saveRDS(object, path, version = 3L)
    unname(tools::md5sum(path))
}
bounded_object <- function(object, limit = 4096L) {
    if (is.list(object) && !is.data.frame(object)) {
        return(lapply(object, bounded_object, limit = limit))
    }
    if (!is.atomic(object) || length(object) <= limit) return(object)
    index <- unique(round(seq(1L, length(object), length.out = limit)))
    list(dim = dim(object), length = length(object), values = object[index])
}

gc(full = TRUE)
baseline_rss <- rss_mib()
result <- NULL
elapsed <- system.time({
    if (identical(workload, "fit_predict")) {
        fit <- pls(
            task$Xtrain, task$Ytrain,
            ncomp = ncomp, method = method, backend = backend,
            classifier = classifier, kernel = kernel, north = north,
            fit = FALSE, proj = FALSE, return_variance = FALSE,
            return_loadings = FALSE, seed = seed, n.cores = n.cores
        )
        prediction <- predict(
            fit, task$Xtest,
            Ytest = if (classification) NULL else task$Ytest,
            backend = backend, raw_scores = classification,
            n.cores = n.cores
        )
        result <- list(fit = fit, prediction = prediction)
    } else {
        result <- pls.single.cv(
            task$Xtrain, task$Ytrain,
            ncomp = ncomp, constrain = constrain, kfold = kfold,
            method = method, backend = backend, classifier = classifier,
            kernel = kernel, north = north, fit = FALSE, seed = seed,
            selection = selection, n.cores = n.cores
        )
    }
})[["elapsed"]]
final_rss <- rss_mib()

if (identical(workload, "fit_predict")) {
    prediction <- result$prediction$Ypred
    if (is.list(prediction)) prediction <- prediction[[length(prediction)]]
    if (length(dim(prediction)) == 3L) {
        prediction <- prediction[, , dim(prediction)[[3L]], drop = TRUE]
    }
    if (classification) {
        metric_name <- "accuracy"
        metric <- mean(as.character(prediction) == as.character(task$Ytest))
    } else {
        observed <- as_double(task$Ytest)
        predicted <- as_double(prediction)
        metric_name <- "RMSD"
        metric <- sqrt(mean((predicted - observed)^2))
    }
    prediction_signature <- fingerprint(bounded_object(prediction))
    fold_signature <- NA_character_
    best_ncomp <- max(ncomp)
    route <- result$fit$diagnostics$residency$route %||%
        attr(result$fit, "fastPLS_internal", exact = TRUE)$execution_route %||%
        NA_character_
    output_mib <- as.numeric(object.size(result)) / 1024^2
} else {
    metric_name <- selection
    metric <- result$selection_metrics$metric_value[[result$best_index]]
    prediction_signature <- fingerprint(bounded_object(
        list(pred = result$pred, score = result$Ypred)
    ))
    fold_signature <- fingerprint(result$fold)
    best_ncomp <- result$best_ncomp
    route <- attr(result, "fastPLS_internal", exact = TRUE)$execution_route %||%
        result$diagnostics$residency$route %||% NA_character_
    output_mib <- as.numeric(object.size(result)) / 1024^2
}

row <- data.frame(
    package_version = as.character(packageVersion("fastPLS")),
    package_path = loaded_path,
    source_id = value("source_id", "unrecorded"),
    dataset = task$dataset,
    task = basename(task_path),
    workload = workload,
    backend = backend,
    precision = precision,
    method = method,
    classifier = if (classification) classifier else NA_character_,
    kernel = if (identical(method, "kernelpls")) kernel else NA_character_,
    north = if (identical(method, "opls")) north else NA_integer_,
    n = nrow(task$Xtrain),
    test_n = if (identical(workload, "fit_predict")) {
        nrow(task$Xtest)
    } else {
        NA_integer_
    },
    p = ncol(task$Xtrain),
    q = if (classification) nlevels(task$Ytrain) else ncol(task$Ytrain),
    folds = kfold,
    requested_ncomp = paste(ncomp, collapse = ";"),
    best_ncomp = best_ncomp,
    selection = selection,
    metric_name = metric_name,
    metric_value = metric,
    elapsed_sec = unname(elapsed),
    baseline_rss_mib = baseline_rss,
    final_rss_mib = final_rss,
    output_mib = output_mib,
    fold_signature = fold_signature,
    prediction_signature = prediction_signature,
    execution_route = route,
    seed = seed,
    n.cores = n.cores,
    replicate = replicate,
    status = "success",
    stringsAsFactors = FALSE
)
dir.create(dirname(args$output), recursive = TRUE, showWarnings = FALSE)
write.csv(row, args$output, row.names = FALSE)
print(row)
