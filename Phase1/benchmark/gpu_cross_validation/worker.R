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
classifier <- strsplit(
    value("classifier", "argmax"), ",", fixed = TRUE
)[[1L]]
classifier <- unique(vapply(
    classifier,
    match.arg,
    character(1L),
    choices = c("argmax", "lda")
))
kernel <- match.arg(value("kernel", "linear"), c("linear", "rbf", "poly"))
north <- as.integer(value("north", "1"))
implementation <- value("implementation", "current")
replicate <- as.integer(value("replicate", "1"))
selection_metric <- value(
    "selection_metric", if (classification) "accuracy" else "rmsd"
)
context_mode <- match.arg(value("context_mode", "cold"), c("cold", "warm"))
workload <- match.arg(value("workload", "cv"), c("cv", "one_fold"))
fold_cache <- match.arg(value("fold_cache", "on"), c("on", "off"))
if (identical(workload, "one_fold") && length(classifier) > 1L) {
    stop("Multiple classifiers are supported only for --workload=cv.")
}

# Benchmark-only ablation. The public API always uses the optimized default.
fold_cache_value <- if (identical(fold_cache, "on")) "1" else "0"
Sys.setenv(
    FASTPLS_CV_FOLD_GRAM_CACHE = fold_cache_value,
    FASTPLS_CV_FOLD_CROSSCOV_CACHE = fold_cache_value,
    FASTPLS_CV_CLASS_SUM_CACHE = fold_cache_value
)

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

held_out <- test <- train <- NULL
if (identical(workload, "one_fold")) {
    held_out <- sort(unique(fold))[[1L]]
    test <- which(fold == held_out)
    train <- which(fold != held_out)
}

run_workload <- function() {
    if (identical(workload, "cv")) {
        return(pls.single.cv(
            X, Y, constrain = constrain, ncomp = ncomp, kfold = kfold,
            method = method, backend = backend, classifier = classifier,
            kernel = kernel, north = north, fit = FALSE, seed = seed,
            selection_metric = selection_metric
        ))
    }
    pls(
        X[train, , drop = FALSE],
        if (classification) Y[train] else Y[train, , drop = FALSE],
        X[test, , drop = FALSE],
        ncomp = ncomp, method = method, backend = backend,
        classifier = classifier, kernel = kernel, north = north,
        fit = FALSE, seed = seed,
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
bounded_fingerprint_object <- function(object, limit = 4096L) {
    if (is.list(object) && !is.data.frame(object)) {
        return(lapply(object, bounded_fingerprint_object, limit = limit))
    }
    if (!is.numeric(object) || length(object) <= limit) return(object)
    index <- unique(round(seq(1L, length(object), length.out = limit)))
    list(
        dim = dim(object),
        length = length(object),
        sample = as.numeric(object[index])
    )
}
canonical_prediction <- function(object, digits = NULL) {
    if (is.null(object)) return(NULL)
    if (is.factor(object)) return(as.character(object))
    if (is.list(object)) {
        return(lapply(
            object,
            canonical_prediction,
            digits = digits
        ))
    }
    if (is.numeric(object) && !is.null(digits)) {
        object[] <- signif(object, digits)
    }
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
    numerical_prediction_signature <- NA_character_
    fold_signature <- fingerprint(fold)
    residency <- list()
    status <- "error"
    output_mib <- NA_real_
    classifier_best_ncomp <- NA_character_
    classifier_best_metric <- NA_character_
} else {
    if (identical(workload, "cv")) {
        metric_values <- result$selection_metrics$metric_value
        best_ncomp <- result$best_ncomp
        best_metric <- result$best_metric_value
    } else {
        predictions <- result$Ypred
        if (!is.list(predictions)) predictions <- list(predictions)
        if (length(predictions) != length(ncomp)) {
            stop("One-fold prediction path does not match ncomp.")
        }
        if (classification) {
            metric_values <- vapply(predictions, function(prediction) {
                mean(as.character(prediction) == as.character(Y[test]))
            }, numeric(1L))
        } else {
            observed <- if (inherits(Y, "float32")) {
                float::dbl(Y[test, , drop = FALSE])
            } else {
                as.matrix(Y[test, , drop = FALSE])
            }
            training <- if (inherits(Y, "float32")) {
                float::dbl(Y[train, , drop = FALSE])
            } else {
                as.matrix(Y[train, , drop = FALSE])
            }
            center <- colMeans(training)
            denominator <- sum(sweep(observed, 2L, center, "-")^2)
            metric_values <- vapply(predictions, function(prediction) {
                predicted <- if (inherits(prediction, "float32")) {
                    float::dbl(prediction)
                } else {
                    as.matrix(prediction)
                }
                if (identical(tolower(selection_metric), "q2")) {
                    1 - sum((observed - predicted)^2) / denominator
                } else {
                    sqrt(mean((observed - predicted)^2))
                }
            }, numeric(1L))
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
    prediction_signature <- fingerprint(bounded_fingerprint_object(list(
        pred = canonical_prediction(result$pred),
        Ypred = canonical_prediction(result$Ypred),
        Q2Y = canonical_prediction(result$Q2Y),
        RMSD = canonical_prediction(result$RMSD)
    )))
    numerical_prediction_signature <- fingerprint(bounded_fingerprint_object(list(
        pred = canonical_prediction(result$pred, digits = 12L),
        Ypred = canonical_prediction(result$Ypred, digits = 12L),
        Q2Y = canonical_prediction(result$Q2Y, digits = 12L),
        RMSD = canonical_prediction(result$RMSD, digits = 12L)
    )))
    fold_signature <- fingerprint(result$fold %||% fold)
    residency <- if (identical(workload, "cv")) {
        result$residency %||% list()
    } else {
        result$diagnostics$residency %||% list()
    }
    fold_status <- result$status
    if (is.null(fold_status)) {
        status <- "ok"
    } else if (is.character(fold_status) && length(fold_status) == 1L) {
        status <- fold_status
    } else {
        status <- if (all(fold_status %in% c(1L, 4L))) "ok" else "partial"
    }
    output_mib <- as.numeric(object.size(result)) / 1024^2
    classifier_best_ncomp <- classifier_best_metric <- NA_character_
    if (identical(workload, "cv") && classification &&
        is.data.frame(result$tuning_summary) &&
        all(c("classifier", "best_ncomp", "best_metric_value") %in%
            names(result$tuning_summary))) {
        summary <- result$tuning_summary
        summary <- summary[summary$status == "ok", , drop = FALSE]
        classifier_best_ncomp <- paste(
            paste0(summary$classifier, ":", summary$best_ncomp),
            collapse = ";"
        )
        classifier_best_metric <- paste(
            paste0(
                summary$classifier,
                ":",
                signif(summary$best_metric_value, 12L)
            ),
            collapse = ";"
        )
    }
}

fold_status_text <- if (is.null(result)) {
    NA_character_
} else {
    paste(result$status %||% 1L, collapse = ";")
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
    kernel = if (identical(method, "kernelpls")) kernel else NA_character_,
    north = if (identical(method, "opls")) north else NA_integer_,
    classifier = if (classification) {
        paste(classifier, collapse = ";")
    } else {
        NA_character_
    },
    n = nrow(X),
    p = ncol(X),
    q = if (classification) nlevels(Y) else ncol(Y),
    groups = length(unique(constrain)),
    folds = length(unique(fold)),
    ncomp = paste(ncomp, collapse = ";"),
    selection_metric = selection_metric,
    best_ncomp = best_ncomp,
    best_metric = best_metric,
    classifier_best_ncomp = classifier_best_ncomp,
    classifier_best_metric = classifier_best_metric,
    metric_path = metric_path,
    elapsed_sec = unname(timing[["elapsed"]]),
    user_sec = unname(timing[["user.self"]]),
    system_sec = unname(timing[["sys.self"]]),
    baseline_rss_mib = baseline_rss_mib,
    final_minus_baseline_rss_mib = final_rss_mib - baseline_rss_mib,
    output_mib = output_mib,
    context_mode = context_mode,
    fold_cache = fold_cache,
    fold_orchestration = residency$fold_orchestration %||% "host",
    metric_reduction = residency$metric_reduction %||% "host",
    groups_preserved = groups_preserved,
    fold_signature = fold_signature,
    prediction_signature = prediction_signature,
    numerical_prediction_signature = numerical_prediction_signature,
    fold_status = fold_status_text,
    status = status,
    error = error_message,
    replicate = replicate,
    stringsAsFactors = FALSE
)
write.table(
    row, args$output, sep = ",", row.names = FALSE,
    col.names = !file.exists(args$output), append = file.exists(args$output)
)
