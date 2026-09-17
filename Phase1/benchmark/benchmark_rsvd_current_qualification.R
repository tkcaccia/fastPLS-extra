#!/usr/bin/env Rscript

# Multi-seed qualification of the public automatic rSVD controls against a
# high-accuracy public-API comparison route. This is approximation evidence;
# it is intentionally separate from the dense SIMPLS recurrence comparison.

args <- commandArgs(trailingOnly = TRUE)
argument <- function(name, default) {
    prefix <- paste0("--", name, "=")
    value <- args[startsWith(args, prefix)]
    if (length(value)) sub(prefix, "", value[[1L]], fixed = TRUE) else default
}

library_path <- Sys.getenv("FASTPLS_BENCH_LIB", unset = "")
if (nzchar(library_path)) {
    .libPaths(unique(c(normalizePath(library_path), .libPaths())))
}
suppressPackageStartupMessages(library(fastPLS))

`%||%` <- function(left, right) {
    if (is.null(left) || !length(left)) right else left
}

backend <- match.arg(argument("backend", "cpu"), c("cpu", "cuda"))
seeds <- as.integer(strsplit(
    argument("seeds", paste(seq_len(29L), collapse = ",")),
    ",", fixed = TRUE
)[[1L]])
if (!length(seeds) || anyNA(seeds) || anyDuplicated(seeds)) {
    stop("The rSVD qualification requires distinct integer seeds.", call. = FALSE)
}
if (backend == "cuda" && !isTRUE(has_cuda())) {
    stop("CUDA is unavailable; no CPU fallback is permitted.", call. = FALSE)
}

output_directory <- argument(
    "out",
    file.path(Sys.getenv("FASTPLS_RESULTS_ROOT"), "rsvd_qualification")
)
if (!nzchar(output_directory)) {
    stop("Supply --out or set FASTPLS_RESULTS_ROOT.", call. = FALSE)
}
dir.create(output_directory, recursive = TRUE, showWarnings = FALSE)

relative_error <- function(value, reference) {
    sqrt(sum((value - reference)^2)) /
        max(sqrt(sum(reference^2)), .Machine$double.eps)
}

aligned_score_error <- function(value, reference) {
    value <- as.matrix(value)
    reference <- as.matrix(reference)
    if (!identical(dim(value), dim(reference))) return(Inf)
    for (column in seq_len(ncol(value))) {
        if (sum(value[, column] * reference[, column]) < 0) {
            value[, column] <- -value[, column]
        }
    }
    relative_error(value, reference)
}

safe_correlation <- function(value, reference) {
    value <- as.vector(value)
    reference <- as.vector(reference)
    if (length(value) < 2L || sd(value) == 0 || sd(reference) == 0) {
        return(NA_real_)
    }
    cor(value, reference)
}

principal_angle <- function(value, reference) {
    q_value <- qr.Q(qr(as.matrix(value)))
    q_reference <- qr.Q(qr(as.matrix(reference)))
    singular_values <- svd(
        crossprod(q_value, q_reference), nu = 0L, nv = 0L
    )$d
    max(acos(pmin(1, pmax(-1, singular_values))) * 180 / pi)
}

last_numeric_prediction <- function(prediction) {
    score <- prediction$Yscore
    if (!is.null(score)) {
        return(score[, , dim(score)[[3L]], drop = FALSE][, , 1L])
    }
    value <- prediction$Ypred
    if (is.list(value) && !is.data.frame(value)) {
        return(as.matrix(value[[length(value)]]))
    }
    if (length(dim(value)) == 3L) {
        return(value[, , dim(value)[[3L]], drop = FALSE][, , 1L])
    }
    as.matrix(value)
}

last_labels <- function(prediction) {
    value <- prediction$Ypred
    if (is.data.frame(value)) return(as.character(value[[ncol(value)]]))
    if (is.list(value)) return(as.character(value[[length(value)]]))
    as.character(value)
}

make_case <- function(name, seed, n, p, q, rank, classification = FALSE,
                      ill_conditioned = FALSE) {
    set.seed(seed)
    latent <- matrix(rnorm(n * rank), n, rank)
    loading <- matrix(rnorm(p * rank), p, rank)
    if (ill_conditioned && p >= 4L) {
        loading[2L, ] <- loading[1L, ] + rnorm(rank, sd = 1e-9)
        loading[3L, ] <- 2 * loading[1L, ] - loading[2L, ]
    }
    x <- latent %*% t(loading) + matrix(rnorm(n * p, sd = 0.03), n, p)
    if (classification) {
        logits <- latent %*% matrix(rnorm(rank * q), rank, q)
        labels <- max.col(logits + matrix(rnorm(n * q, sd = 0.2), n, q))
        labels[seq_len(q)] <- seq_len(q)
        y <- factor(labels, levels = seq_len(q))
    } else {
        y <- latent %*% matrix(rnorm(rank * q), rank, q) +
            matrix(rnorm(n * q, sd = 0.03), n, q)
    }
    training <- seq_len(floor(0.75 * n))
    test <- setdiff(seq_len(n), training)
    y_training <- if (classification) y[training] else y[training, , drop = FALSE]
    y_test <- if (classification) y[test] else y[test, , drop = FALSE]
    list(
        name = name, classification = classification,
        Xtrain = x[training, , drop = FALSE], Xtest = x[test, , drop = FALSE],
        Ytrain = y_training, Ytest = y_test,
        ncomp = min(8L, rank, length(training) - 1L, p,
                    if (classification) q - 1L else q)
    )
}

cases <- list(
    make_case("regression_p_lt_n", 101L, 180L, 24L, 8L, 6L),
    make_case("regression_p_gt_n", 102L, 90L, 180L, 8L, 6L),
    make_case("regression_high_q", 103L, 150L, 30L, 120L, 8L),
    make_case("regression_ill_conditioned", 104L, 140L, 80L, 10L, 8L,
              ill_conditioned = TRUE),
    make_case("classification_p_lt_n", 105L, 180L, 24L, 5L, 5L, TRUE),
    make_case("classification_many_classes", 106L, 180L, 160L, 40L, 8L,
              TRUE)
)

fit_case <- function(case, seed, high_accuracy, execution_backend) {
    arguments <- list(
        Xtrain = case$Xtrain, Ytrain = case$Ytrain,
        ncomp = seq_len(case$ncomp), method = "simpls",
        classifier = if (case$classification) "argmax" else "argmax",
        scaling = "centering", backend = execution_backend, n.cores = 1L,
        fit = TRUE, proj = TRUE, return_loadings = TRUE,
        return_variance = FALSE, seed = seed
    )
    if (high_accuracy) {
        arguments$oversample <- max(
            128L,
            min(ncol(case$Xtrain), if (case$classification) {
                nlevels(factor(case$Ytrain))
            } else {
                ncol(as.matrix(case$Ytrain))
            })
        )
        arguments$power <- 5L
    }
    fit <- do.call(fastPLS::pls, arguments)
    prediction <- predict(
        fit, case$Xtest, raw_scores = case$classification,
        backend = execution_backend, n.cores = 1L
    )
    list(fit = fit, prediction = prediction)
}

rows <- list()
index <- 1L
for (case in cases) {
    for (seed in seeds) {
        row <- tryCatch({
            reference <- fit_case(case, seed, TRUE, "cpu")
            candidate <- fit_case(case, seed, FALSE, backend)
            reference_prediction <- last_numeric_prediction(reference$prediction)
            candidate_prediction <- last_numeric_prediction(candidate$prediction)
            label_agreement <- if (case$classification) {
                mean(last_labels(candidate$prediction) ==
                         last_labels(reference$prediction))
            } else {
                NA_real_
            }
            metric_difference <- if (case$classification) {
                truth <- as.character(case$Ytest)
                abs(
                    mean(last_labels(candidate$prediction) == truth) -
                        mean(last_labels(reference$prediction) == truth)
                )
            } else {
                truth <- as.matrix(case$Ytest)
                candidate_rmsd <- sqrt(mean((candidate_prediction - truth)^2))
                reference_rmsd <- sqrt(mean((reference_prediction - truth)^2))
                abs(candidate_rmsd - reference_rmsd) /
                    max(reference_rmsd, .Machine$double.eps)
            }
            prediction_error <- relative_error(
                candidate_prediction, reference_prediction
            )
            correlation <- safe_correlation(
                candidate_prediction, reference_prediction
            )
            score_angle <- principal_angle(
                candidate$fit$Ttrain, reference$fit$Ttrain
            )
            score_error <- aligned_score_error(
                candidate$fit$Ttrain, reference$fit$Ttrain
            )
            met_tolerance <- prediction_error <= 0.01 &&
                score_error <= 0.01 &&
                (is.na(correlation) || correlation >= 0.995) &&
                (is.na(label_agreement) || label_agreement >= 0.995) &&
                metric_difference <= if (case$classification) 0.005 else 0.01
            diagnostics <- candidate$fit$diagnostics$rsvd %||% list()
            data.frame(
                backend = backend,
                case = case$name, seed = seed,
                task_type = if (case$classification) {
                    "classification"
                } else {
                    "regression"
                },
                n_train = nrow(case$Xtrain), p = ncol(case$Xtrain),
                q = if (case$classification) {
                    nlevels(factor(case$Ytrain))
                } else {
                    ncol(as.matrix(case$Ytrain))
                },
                ncomp = case$ncomp,
                prediction_relative_error = prediction_error,
                prediction_correlation = correlation,
                score_relative_error = score_error,
                score_subspace_angle_degrees = score_angle,
                label_agreement = label_agreement,
                metric_difference = metric_difference,
                effective_oversample = diagnostics$oversample %||% NA_integer_,
                effective_power = diagnostics$power %||% NA_integer_,
                met_prespecified_numerical_tolerances = met_tolerance,
                status = "success", error = NA_character_,
                package_version = as.character(packageVersion("fastPLS")),
                stringsAsFactors = FALSE
            )
        }, error = function(error) {
            data.frame(
                backend = backend,
                case = case$name, seed = seed,
                task_type = if (case$classification) {
                    "classification"
                } else {
                    "regression"
                },
                n_train = nrow(case$Xtrain), p = ncol(case$Xtrain),
                q = NA_integer_, ncomp = case$ncomp,
                prediction_relative_error = NA_real_,
                prediction_correlation = NA_real_,
                score_relative_error = NA_real_,
                score_subspace_angle_degrees = NA_real_,
                label_agreement = NA_real_, metric_difference = NA_real_,
                effective_oversample = NA_integer_,
                effective_power = NA_integer_,
                met_prespecified_numerical_tolerances = FALSE,
                status = "failed", error = conditionMessage(error),
                package_version = as.character(packageVersion("fastPLS")),
                stringsAsFactors = FALSE
            )
        })
        rows[[index]] <- row
        index <- index + 1L
    }
}

raw <- do.call(rbind, rows)
write.csv(raw, file.path(output_directory, "rsvd_qualification_raw.csv"),
          row.names = FALSE, na = "")
case_summary <- do.call(rbind, lapply(split(raw, raw$case), function(value) {
    data.frame(
        backend = backend, case = value$case[[1L]], comparisons = nrow(value),
        successful = sum(value$status == "success"),
        met_tolerances = sum(value$met_prespecified_numerical_tolerances),
        max_prediction_relative_error = max(
            value$prediction_relative_error, na.rm = TRUE
        ),
        min_prediction_correlation = min(
            value$prediction_correlation, na.rm = TRUE
        ),
        max_score_relative_error = max(
            value$score_relative_error, na.rm = TRUE
        ),
        max_score_subspace_angle_degrees = max(
            value$score_subspace_angle_degrees, na.rm = TRUE
        ),
        min_label_agreement = if (all(is.na(value$label_agreement))) {
            NA_real_
        } else {
            min(value$label_agreement, na.rm = TRUE)
        },
        stringsAsFactors = FALSE
    )
}))
write.csv(case_summary, file.path(output_directory, "rsvd_qualification_case_summary.csv"),
          row.names = FALSE, na = "")
successful <- raw[raw$status == "success", , drop = FALSE]
summary <- data.frame(
    backend = backend,
    effective_controls = paste(sort(unique(paste0(
        successful$effective_oversample, "/", successful$effective_power
    ))), collapse = "; "),
    comparisons = nrow(raw),
    successful = nrow(successful),
    met_tolerances = sum(raw$met_prespecified_numerical_tolerances),
    max_prediction_relative_error = max(
        successful$prediction_relative_error, na.rm = TRUE
    ),
    min_prediction_correlation = min(
        successful$prediction_correlation, na.rm = TRUE
    ),
    max_score_relative_error = max(
        successful$score_relative_error, na.rm = TRUE
    ),
    min_label_agreement = min(
        successful$label_agreement, na.rm = TRUE
    ),
    max_metric_difference = max(successful$metric_difference, na.rm = TRUE),
    stringsAsFactors = FALSE
)
write.csv(summary, file.path(output_directory, "rsvd_qualification_summary.csv"),
          row.names = FALSE, na = "")
writeLines(capture.output(sessionInfo()),
           file.path(output_directory, "session_info.txt"))
print(summary)
