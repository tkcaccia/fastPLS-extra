#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 8L) {
    stop(paste(
        "Usage: precision_backend_concordance_worker.R",
        "LIB TASK FAMILY NCOMP MODES REFERENCE_MODE OUTPUT EXPECTED_VERSION"
    ), call. = FALSE)
}

library_path <- args[[1L]]
task_path <- args[[2L]]
family <- args[[3L]]
ncomp <- as.integer(args[[4L]])
modes <- strsplit(args[[5L]], ",", fixed = TRUE)[[1L]]
reference_mode <- args[[6L]]
output <- args[[7L]]
expected_version <- args[[8L]]

.libPaths(unique(c(library_path, .libPaths())))
suppressPackageStartupMessages(library(fastPLS))
if (!identical(as.character(packageVersion("fastPLS")), expected_version)) {
    stop("Expected fastPLS ", expected_version, call. = FALSE)
}

`%||%` <- function(left, right) {
    if (is.null(left) || !length(left)) right else left
}

task <- readRDS(task_path)
if (!all(c("Xtrain", "Xtest") %in% names(task)) &&
        all(c("Xtrain_rds", "Xtest_rds") %in% names(task))) {
    task$Xtrain <- readRDS(task$Xtrain_rds)
    task$Xtest <- readRDS(task$Xtest_rds)
}
required <- c("Xtrain", "Ytrain", "Xtest", "Ytest")
if (!is.list(task) || !all(required %in% names(task))) {
    stop("Prepared task is missing a required matrix or response", call. = FALSE)
}
dataset <- task$dataset %||% sub("_task\\.rds$", "", basename(task_path))
classification <- is.factor(task$Ytrain)

to_float <- function(value) {
    if (inherits(value, "float32")) value else float::fl(as.matrix(value))
}

to_double <- function(value) {
    if (inherits(value, "float32")) float::dbl(value) else as.matrix(value)
}

prepare_value <- function(value, precision) {
    if (identical(precision, "float32")) to_float(value) else to_double(value)
}

extract_prediction <- function(fit, Xtest, backend) {
    prediction <- predict(fit, Xtest, backend = backend)$Ypred
    if (is.list(prediction)) prediction <- prediction[[length(prediction)]]
    if (length(dim(prediction)) == 3L) {
        prediction <- prediction[, , dim(prediction)[[3L]], drop = TRUE]
    }
    prediction
}

regression_sums <- function(observed, predicted, reference = NULL,
                            block_rows = 16L) {
    nr <- nrow(observed)
    squared_error <- 0
    count <- 0
    ref_squared <- 0
    diff_squared <- 0
    sum_ref <- 0
    sum_pred <- 0
    sum_ref2 <- 0
    sum_pred2 <- 0
    sum_cross <- 0
    for (start in seq.int(1L, nr, by = block_rows)) {
        stop_at <- min(nr, start + block_rows - 1L)
        index <- start:stop_at
        obs_block <- as.matrix(observed[index, , drop = FALSE])
        pred_block <- as.matrix(predicted[index, , drop = FALSE])
        residual <- pred_block - obs_block
        squared_error <- squared_error + sum(residual * residual)
        count <- count + length(residual)
        if (!is.null(reference)) {
            ref_block <- as.matrix(reference[index, , drop = FALSE])
            delta <- pred_block - ref_block
            ref_squared <- ref_squared + sum(ref_block * ref_block)
            diff_squared <- diff_squared + sum(delta * delta)
            sum_ref <- sum_ref + sum(ref_block)
            sum_pred <- sum_pred + sum(pred_block)
            sum_ref2 <- sum_ref2 + sum(ref_block * ref_block)
            sum_pred2 <- sum_pred2 + sum(pred_block * pred_block)
            sum_cross <- sum_cross + sum(ref_block * pred_block)
        }
    }
    result <- list(rmsd = sqrt(squared_error / max(1, count)))
    if (!is.null(reference)) {
        denominator <- sqrt(max(ref_squared, .Machine$double.eps))
        result$relative_prediction_error <- sqrt(diff_squared) / denominator
        covariance <- sum_cross - sum_ref * sum_pred / count
        variance_ref <- sum_ref2 - sum_ref * sum_ref / count
        variance_pred <- sum_pred2 - sum_pred * sum_pred / count
        correlation_denominator <- sqrt(max(
            variance_ref * variance_pred,
            .Machine$double.eps
        ))
        result$prediction_correlation <- covariance / correlation_denominator
    }
    result
}

parse_mode <- function(mode) {
    fields <- strsplit(mode, ":", fixed = TRUE)[[1L]]
    if (length(fields) != 2L ||
            !fields[[1L]] %in% c("cpu", "cuda", "metal") ||
            !fields[[2L]] %in% c("float32", "float64")) {
        stop("Invalid mode: ", mode, call. = FALSE)
    }
    list(backend = fields[[1L]], precision = fields[[2L]])
}

fit_mode <- function(mode, reference_prediction = NULL) {
    specification <- parse_mode(mode)
    backend <- specification$backend
    precision <- specification$precision
    Xtrain <- prepare_value(task$Xtrain, precision)
    Xtest <- prepare_value(task$Xtest, precision)
    if (classification) {
        Ytrain <- task$Ytrain
        Ytest <- task$Ytest
    } else {
        Ytrain <- prepare_value(task$Ytrain, precision)
        Ytest <- prepare_value(task$Ytest, precision)
    }
    started <- proc.time()[["elapsed"]]
    result <- tryCatch({
        controls <- list()
        diagnostic_oversample <- Sys.getenv(
            "FASTPLS_BENCH_OVERSAMPLE", unset = ""
        )
        diagnostic_power <- Sys.getenv("FASTPLS_BENCH_POWER", unset = "")
        if (nzchar(diagnostic_oversample)) {
            controls$oversample <- as.integer(diagnostic_oversample)
        }
        if (nzchar(diagnostic_power)) {
            controls$power <- as.integer(diagnostic_power)
        }
        fit <- do.call(pls, c(list(
            Xtrain, Ytrain,
            ncomp = ncomp,
            method = family,
            backend = backend,
            classifier = "argmax",
            kernel = "linear",
            north = 1L,
            fit = FALSE,
            proj = FALSE,
            return_variance = FALSE,
            return_loadings = FALSE,
            seed = 123L
        ), controls))
        prediction <- extract_prediction(fit, Xtest, backend)
        internal <- attr(fit, "fastPLS_internal", exact = TRUE)
        reported_precision <- internal$precision %||% NA_character_
        normalized_precision <- switch(
            reported_precision,
            single = "float32", double = "float64", reported_precision
        )
        if (!is.na(normalized_precision) &&
                !identical(normalized_precision, precision)) {
            stop("Fit reported precision ", reported_precision)
        }
        route <- fit$diagnostics$residency$route %||%
            internal$execution_route %||% internal$resident_backend %||%
            internal$predict_backend %||%
            fit$diagnostics$rsvd$backend %||% ""
        controls <- fit$diagnostics$rsvd %||% list()
        route_ok <- switch(
            backend,
            cpu = grepl("CPU", route, ignore.case = TRUE) &&
                !grepl("CUDA|Metal", route, ignore.case = TRUE),
            cuda = grepl("CUDA", route, ignore.case = TRUE),
            metal = grepl("Metal", route, ignore.case = TRUE)
        )
        if (!isTRUE(route_ok)) stop("Unexpected execution route: ", route)
        if (classification) {
            predicted_labels <- as.character(prediction)
            metric <- mean(predicted_labels == as.character(Ytest))
            if (is.null(reference_prediction)) {
                agreement <- 1
            } else {
                agreement <- mean(
                    predicted_labels == as.character(reference_prediction)
                )
            }
            diagnostics <- list(
                metric = metric,
                label_agreement = agreement,
                relative_prediction_error = NA_real_,
                prediction_correlation = NA_real_,
                prediction = predicted_labels,
                route = route,
                controls = controls
            )
        } else {
            predicted_matrix <- if (inherits(prediction, "float32")) {
                float::dbl(prediction)
            } else {
                as.matrix(prediction)
            }
            observed_matrix <- if (inherits(Ytest, "float32")) {
                float::dbl(Ytest)
            } else {
                as.matrix(Ytest)
            }
            reference_matrix <- if (is.null(reference_prediction)) {
                NULL
            } else {
                reference_prediction
            }
            diagnostics <- regression_sums(
                observed_matrix, predicted_matrix, reference_matrix
            )
            diagnostics$metric <- diagnostics$rmsd
            diagnostics$label_agreement <- NA_real_
            diagnostics$prediction <- predicted_matrix
            diagnostics$route <- route
            diagnostics$controls <- controls
        }
        diagnostics
    }, error = function(error) {
        list(error = conditionMessage(error))
    })
    elapsed <- proc.time()[["elapsed"]] - started
    rm(Xtrain, Xtest, Ytrain, Ytest)
    invisible(gc(full = TRUE))
    if (!is.null(result$error)) {
        return(list(
            row = data.frame(
                dataset = dataset, family = family, ncomp = ncomp,
                mode = mode, reference_mode = reference_mode,
                backend = backend, precision = precision,
                task_type = if (classification) "classification" else "regression",
                metric_name = if (classification) "accuracy" else "RMSD",
                metric_value = NA_real_, metric_delta = NA_real_,
                relative_metric_delta = NA_real_, label_agreement = NA_real_,
                relative_prediction_error = NA_real_,
                prediction_correlation = NA_real_, elapsed_sec = elapsed,
                oversample = NA_integer_, power = NA_integer_, seed = 123L,
                control_profile = "",
                execution_route = "", status = "failed",
                error_message = result$error, stringsAsFactors = FALSE
            ),
            prediction = NULL
        ))
    }
    list(
        row = data.frame(
            dataset = dataset, family = family, ncomp = ncomp,
            mode = mode, reference_mode = reference_mode,
            backend = backend, precision = precision,
            task_type = if (classification) "classification" else "regression",
            metric_name = if (classification) "accuracy" else "RMSD",
            metric_value = result$metric, metric_delta = NA_real_,
            relative_metric_delta = NA_real_,
            label_agreement = result$label_agreement,
            relative_prediction_error = result$relative_prediction_error %||% NA_real_,
            prediction_correlation = result$prediction_correlation %||% NA_real_,
            elapsed_sec = elapsed,
            oversample = result$controls$oversample %||% NA_integer_,
            power = result$controls$power %||% NA_integer_,
            seed = result$controls$seed %||% 123L,
            control_profile = result$controls$control_profile %||% "",
            execution_route = result$route,
            status = "success", error_message = "", stringsAsFactors = FALSE
        ),
        prediction = result$prediction
    )
}

if (!reference_mode %in% modes) {
    stop("Reference mode must be included in modes", call. = FALSE)
}
ordered_modes <- c(reference_mode, setdiff(modes, reference_mode))
reference_result <- fit_mode(reference_mode)
rows <- list(reference_result$row)
reference_prediction <- reference_result$prediction
reference_metric <- reference_result$row$metric_value[[1L]]
if (!identical(reference_result$row$status[[1L]], "success")) {
    stop("Reference mode failed: ", reference_result$row$error_message[[1L]],
         call. = FALSE)
}
for (mode in ordered_modes[-1L]) {
    candidate <- fit_mode(mode, reference_prediction)
    if (identical(candidate$row$status[[1L]], "success")) {
        candidate$row$metric_delta <-
            candidate$row$metric_value - reference_metric
        candidate$row$relative_metric_delta <- if (classification) {
            abs(candidate$row$metric_delta)
        } else {
            abs(candidate$row$metric_delta) /
                max(abs(reference_metric), .Machine$double.eps)
        }
    }
    rows[[length(rows) + 1L]] <- candidate$row
    rm(candidate)
    invisible(gc(full = TRUE))
}
rows[[1L]]$metric_delta <- 0
rows[[1L]]$relative_metric_delta <- 0
result <- do.call(rbind, rows)
dir.create(dirname(output), recursive = TRUE, showWarnings = FALSE)
write.csv(result, output, row.names = FALSE)
