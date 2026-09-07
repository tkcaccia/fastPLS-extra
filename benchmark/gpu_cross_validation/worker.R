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
required <- c("library", "task", "output", "backend")
missing <- required[!vapply(required, function(name) {
    is.character(args[[name]]) && nzchar(args[[name]])
}, logical(1L))]
if (length(missing)) stop("Missing --", paste(missing, collapse = ", --"))
value <- function(name, default) args[[name]] %||% default

.libPaths(unique(c(args$library, .libPaths())))
suppressPackageStartupMessages(library(fastPLS))
task_path <- normalizePath(args$task, mustWork = TRUE)
task <- readRDS(task_path)

data_scope <- match.arg(value("data_scope", "train"), c("train", "all"))
if (!is.null(task$X)) {
    Xsource <- task$X
    Y <- task$Y
} else if (identical(data_scope, "train")) {
    Xsource <- task$Xtrain
    Y <- task$Ytrain
} else {
    Xsource <- rbind(task$Xtrain, task$Xtest)
    Y <- if (is.factor(task$Ytrain) || is.character(task$Ytrain)) {
        levels <- levels(factor(task$Ytrain))
        factor(
            c(as.character(task$Ytrain), as.character(task$Ytest)),
            levels = levels
        )
    } else {
        rbind(task$Ytrain, task$Ytest)
    }
}
if (is.null(Xsource) || is.null(Y)) {
    stop("Task does not contain usable X and Y data.")
}

classification <- is.factor(Y) || is.character(Y)
if (classification) Y <- factor(Y)
precision <- match.arg(value("precision", "float32"), c("float32", "float64"))
backend <- match.arg(args$backend, c("cpu", "cuda", "metal"))
if (backend == "metal" && precision != "float32") {
    stop("Metal CV supports float32 only; no fallback is permitted.")
}
fastPLS:::.fastpls_require_backend_available(backend, "GPU CV audit")

if (precision == "float32") {
    X <- if (inherits(Xsource, "float32")) Xsource else {
        float::fl(as.matrix(Xsource))
    }
    if (!classification) {
        Y <- if (inherits(Y, "float32")) Y else float::fl(as.matrix(Y))
    }
} else {
    X <- if (inherits(Xsource, "float32")) float::dbl(Xsource) else {
        as.matrix(Xsource)
    }
    if (!classification) {
        Y <- if (inherits(Y, "float32")) float::dbl(Y) else as.matrix(Y)
    }
}

constrain_name <- value("constrain_field", "constrain")
constrain <- task[[constrain_name]]
if (is.null(constrain) && identical(data_scope, "train")) {
    constrain <- task[[paste0(constrain_name, "_train")]]
}
if (is.null(constrain)) constrain <- seq_len(nrow(X))
if (length(constrain) != nrow(X)) {
    stop("The selected constraint field does not have one value per CV row.")
}

ncomp <- as.integer(strsplit(value("ncomp", "10"), ",", fixed = TRUE)[[1L]])
kfold <- as.integer(value("kfold", "10"))
seed <- as.integer(value("seed", "123"))
method <- match.arg(value("method", "simpls"),
    c("plssvd", "simpls", "opls", "kernelpls"))
classifier <- match.arg(value("classifier", "argmax"), c("argmax", "lda"))
implementation <- value("implementation", "current")
replicate <- as.integer(value("replicate", "1"))
selection_metric <- value(
    "selection_metric", if (classification) "accuracy" else "rmsd"
)
context_mode <- match.arg(value("context_mode", "cold"), c("cold", "warm"))
workload <- match.arg(value("workload", "cv"), c("cv", "one_fold"))

fold_response <- if (classification) Y else {
    if (inherits(Y, "float32")) float::dbl(Y)[, 1L] else as.matrix(Y)[, 1L]
}
fold <- fastPLS:::.make_single_cv_folds(
    fold_response, as.integer(as.factor(constrain)), kfold, seed
)
groups_preserved <- all(vapply(
    split(fold, constrain),
    function(group_fold) length(unique(group_fold)) == 1L,
    logical(1L)
))
if (!groups_preserved) stop("Constraint groups were split across folds.")

run_workload <- function() {
    if (identical(workload, "cv")) {
        return(pls.single.cv(
            X, Y, constrain = constrain, ncomp = ncomp, kfold = kfold,
            method = method, backend = backend, classifier = classifier,
            fit = FALSE, seed = seed, selection_metric = selection_metric
        ))
    }
    held_out <- sort(unique(fold))[[1L]]
    test <- which(fold == held_out)
    train <- which(fold != held_out)
    pls(
        X[train, , drop = FALSE],
        if (classification) Y[train] else Y[train, , drop = FALSE],
        X[test, , drop = FALSE],
        if (classification) Y[test] else Y[test, , drop = FALSE],
        ncomp = ncomp, method = method, backend = backend,
        classifier = classifier, fit = FALSE, seed = seed,
        return_variance = FALSE
    )
}
if (identical(context_mode, "warm")) invisible(run_workload())

rss_mib <- function() {
    value <- tryCatch(
        suppressWarnings(as.numeric(system(sprintf(
            "ps -o rss= -p %d 2>/dev/null", Sys.getpid()
        ), intern = TRUE))),
        error = function(condition) NA_real_
    )
    if (!length(value) || !is.finite(value[[1L]])) return(NA_real_)
    value[[1L]] / 1024
}
fingerprint <- function(object) {
    path <- tempfile(fileext = ".rds")
    on.exit(unlink(path), add = TRUE)
    saveRDS(object, path, version = 3L)
    unname(tools::md5sum(path))
}
pls_test_metric <- function(result, metric) {
    entries <- result$metrics$test
    if (is.null(entries) || !length(entries)) return(numeric())
    column <- switch(
        tolower(metric),
        rmsd = "RMSD",
        rmse = "RMSE",
        q2 = "Q2",
        r2 = "R2",
        metric
    )
    vapply(entries, function(entry) {
        values <- entry$metrics
        if (is.null(values) || !column %in% names(values)) return(NA_real_)
        as.numeric(values[[column]][[1L]])
    }, numeric(1L))
}
canonical_prediction <- function(object) {
    if (is.null(object)) return(NULL)
    if (is.factor(object)) return(as.character(object))
    if (is.list(object)) return(lapply(object, canonical_prediction))
    if (is.atomic(object)) {
        attributes(object) <- attributes(object)[intersect(
            names(attributes(object)), c("dim", "names", "dimnames")
        )]
    }
    object
}

gc(full = TRUE)
baseline_rss_mib <- rss_mib()
error_message <- NA_character_
result <- NULL
timing <- tryCatch(
    system.time(result <- run_workload()),
    error = function(condition) {
        error_message <<- conditionMessage(condition)
        c(user.self = NA_real_, sys.self = NA_real_, elapsed = NA_real_)
    }
)
final_rss_mib <- rss_mib()

if (is.null(result)) {
    metric_path <- NA_character_
    best_ncomp <- NA_integer_
    best_metric <- NA_real_
    prediction_signature <- NA_character_
    fold_signature <- fingerprint(fold)
    residency <- list()
    status <- "error"
    output_mib <- NA_real_
} else {
    if (identical(workload, "cv")) {
        metric_values <- result$selection_metrics$metric_value
        best_ncomp <- result$best_ncomp
        best_metric <- result$best_metric_value
    } else {
        metric_values <- if (classification) {
            result$accuracy
        } else if (identical(tolower(selection_metric), "q2")) {
            result$Q2Y
        } else {
            pls_test_metric(result, selection_metric)
        }
        best_index <- if (
            classification || identical(tolower(selection_metric), "q2")
        ) {
            which.max(metric_values)
        } else {
            which.min(metric_values)
        }
        best_ncomp <- ncomp[[best_index]]
        best_metric <- metric_values[[best_index]]
    }
    metric_path <- paste(signif(metric_values, 12L), collapse = ";")
    prediction_signature <- fingerprint(list(
        pred = canonical_prediction(result$pred),
        Ypred = canonical_prediction(result$Ypred),
        Q2Y = canonical_prediction(result$Q2Y),
        RMSD = canonical_prediction(result$RMSD)
    ))
    fold_signature <- fingerprint(result$fold %||% fold)
    residency <- if (identical(workload, "cv")) {
        result$residency %||% list()
    } else {
        result$diagnostics$residency %||% list()
    }
    status <- result$status %||% "ok"
    output_mib <- as.numeric(object.size(result)) / 1024^2
}

row <- data.frame(
    package_version = as.character(packageVersion("fastPLS")),
    implementation = implementation,
    task = basename(task_path),
    data_scope = data_scope,
    workload = workload,
    backend = backend,
    precision = precision,
    method = method,
    classifier = if (classification) classifier else NA_character_,
    n = nrow(X),
    p = ncol(X),
    q = if (classification) nlevels(Y) else ncol(Y),
    groups = length(unique(constrain)),
    folds = length(unique(fold)),
    ncomp = paste(ncomp, collapse = ";"),
    selection_metric = selection_metric,
    best_ncomp = best_ncomp,
    best_metric = best_metric,
    metric_path = metric_path,
    elapsed_sec = unname(timing[["elapsed"]]),
    user_sec = unname(timing[["user.self"]]),
    system_sec = unname(timing[["sys.self"]]),
    baseline_rss_mib = baseline_rss_mib,
    final_minus_baseline_rss_mib = final_rss_mib - baseline_rss_mib,
    output_mib = output_mib,
    context_mode = context_mode,
    fold_orchestration = residency$fold_orchestration %||% "host",
    metric_reduction = residency$metric_reduction %||% "host",
    groups_preserved = groups_preserved,
    fold_signature = fold_signature,
    prediction_signature = prediction_signature,
    status = status,
    error = error_message,
    replicate = replicate,
    stringsAsFactors = FALSE
)
write.table(
    row, args$output, sep = ",", row.names = FALSE,
    col.names = !file.exists(args$output), append = file.exists(args$output)
)
