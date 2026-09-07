#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
argument <- function(name, default = NULL) {
    prefix <- paste0("--", name, "=")
    matched <- args[startsWith(args, prefix)]
    if (!length(matched)) return(default)
    substring(matched[[length(matched)]], nchar(prefix) + 1L)
}

library_path <- argument("library")
source_id <- argument("source-id", "unrecorded")
dataset_path <- argument("dataset")
dataset_name <- argument("name")
output_path <- argument("output")
ncomp <- as.integer(argument("ncomp", "50"))
selected_path <- argument("selected", "")
repetitions <- as.integer(argument("repetitions", "3"))
backends <- strsplit(argument("backends", "cpu,cuda"), ",", fixed = TRUE)[[1L]]
precisions <- strsplit(argument("precisions", "float32,float64"), ",", fixed = TRUE)[[1L]]
families <- strsplit(
    argument("families", "plssvd,simpls,opls,kernelpls"), ",", fixed = TRUE
)[[1L]]
classifiers <- strsplit(
    argument("classifiers", "argmax,lda"), ",", fixed = TRUE
)[[1L]]
quiet <- identical(tolower(argument("quiet", "false")), "true")
rsvd_oversample <- as.integer(argument("rsvd-oversample", "32"))
rsvd_power <- as.integer(argument("rsvd-power", "5"))

if (any(!nzchar(c(library_path, dataset_path, dataset_name, output_path)))) {
    stop("Required arguments: --library, --dataset, --name, and --output")
}
if (anyNA(c(ncomp, repetitions, rsvd_oversample, rsvd_power)) ||
        ncomp < 1L || repetitions < 1L || rsvd_oversample < 0L ||
        rsvd_power < 0L) {
    stop("ncomp/repetitions must be positive and rSVD controls nonnegative")
}

.libPaths(unique(c(library_path, .libPaths())))
suppressPackageStartupMessages(library(fastPLS))
resolved_library <- normalizePath(find.package("fastPLS"), mustWork = TRUE)
requested_library <- normalizePath(library_path, mustWork = TRUE)
if (!startsWith(resolved_library, paste0(requested_library, .Platform$file.sep))) {
    stop(
        "Loaded fastPLS from ", resolved_library,
        ", outside the requested library ", requested_library
    )
}
package_version <- as.character(utils::packageVersion("fastPLS"))
`%||%` <- function(left, right) if (is.null(left)) right else left

load_task <- function(path, name) {
    if (grepl("[.]rds$", path, ignore.case = TRUE)) {
        task <- readRDS(path)
        required <- c("Xtrain", "Ytrain", "Xtest", "Ytest")
        if (!is.list(task) || !all(required %in% names(task))) {
            stop("RDS benchmark task must contain: ", paste(required, collapse = ", "))
        }
        return(task)
    }
    environment <- new.env(parent = emptyenv())
    load(path, envir = environment)
    if (identical(name, "CIFAR-100")) {
        data <- as.data.frame(environment$r)
        training <- data$split == "train"
        predictors <- grep("^feat_", names(data))
        response <- factor(data$label_name)
        levels_response <- levels(response[training])
        return(list(
            Xtrain = as.matrix(data[training, predictors, drop = FALSE]),
            Xtest = as.matrix(data[!training, predictors, drop = FALSE]),
            Ytrain = factor(response[training], levels = levels_response),
            Ytest = factor(response[!training], levels = levels_response)
        ))
    }
    if (identical(name, "NMR")) {
        return(list(
            Xtrain = environment$Xtrain,
            Xtest = environment$Xtest,
            Ytrain = environment$Ytrain,
            Ytest = environment$Ytest
        ))
    }
    stop("Unsupported dataset loader: ", name)
}

task64 <- load_task(dataset_path, dataset_name)
classification <- is.factor(task64$Ytrain)
selected <- if (nzchar(selected_path)) {
    utils::read.csv(selected_path, stringsAsFactors = FALSE)
} else {
    NULL
}
component_for <- function(family) {
    if (is.null(selected)) {
        return(ncomp)
    }
    dataset_id <- task64$dataset %||% dataset_name
    family_column <- if ("family" %in% names(selected)) {
        selected$family
    } else if ("method" %in% names(selected)) {
        selected$method
    } else {
        stop("Selected-component manifest must contain family or method")
    }
    hit <- selected$dataset == dataset_id & family_column == family
    values <- selected$selected_ncomp[hit]
    if (length(values) != 1L || !is.finite(values)) {
        stop("Selected-component manifest has no unique row for ", dataset_id,
             "/", family)
    }
    as.integer(values)
}

as_precision <- function(task, precision) {
    to_double <- function(value) {
        if (inherits(value, "float32")) {
            return(as.matrix(float::dbl(value)))
        }
        value <- as.matrix(value)
        storage.mode(value) <- "double"
        value
    }
    if (identical(precision, "float64")) {
        task$Xtrain <- to_double(task$Xtrain)
        task$Xtest <- to_double(task$Xtest)
        if (!classification) {
            task$Ytrain <- to_double(task$Ytrain)
            task$Ytest <- to_double(task$Ytest)
        }
        return(task)
    }
    if (!identical(precision, "float32")) stop("Unknown precision: ", precision)
    task$Xtrain <- if (inherits(task$Xtrain, "float32")) {
        task$Xtrain
    } else {
        float::fl(as.matrix(task$Xtrain))
    }
    task$Xtest <- if (inherits(task$Xtest, "float32")) {
        task$Xtest
    } else {
        float::fl(as.matrix(task$Xtest))
    }
    if (!classification) {
        task$Ytrain <- if (inherits(task$Ytrain, "float32")) {
            task$Ytrain
        } else {
            float::fl(as.matrix(task$Ytrain))
        }
        task$Ytest <- if (inherits(task$Ytest, "float32")) {
            task$Ytest
        } else {
            float::fl(as.matrix(task$Ytest))
        }
    }
    task
}

result <- list()
position <- 0L
for (precision in precisions) {
    task <- as_precision(task64, precision)
    for (backend in backends) {
        for (family in families) {
            family_ncomp <- component_for(family)
            active_classifiers <- if (classification) classifiers else "regression"
            for (classifier in active_classifiers) {
                for (replicate_id in seq_len(repetitions)) {
                    position <- position + 1L
                    gc(FALSE)
                    row <- list(
                        dataset = dataset_name,
                        package_version = package_version,
                        package_library = resolved_library,
                        source_id = source_id,
                        family = family,
                        backend = backend,
                        precision = precision,
                        classifier = classifier,
                        ncomp = family_ncomp,
                        replicate = replicate_id,
                        fit_seconds = NA_real_,
                        prediction_seconds = NA_real_,
                        metric = NA_real_,
                        metric_name = if (classification) "accuracy" else "RMSD",
                        execution_route = NA_character_,
                        algorithm_variant = NA_character_,
                        refresh_block = NA_integer_,
                        oversample = NA_integer_,
                        power = NA_integer_,
                        status = "success",
                        error = NA_character_
                    )
                    failure <- tryCatch({
                        started <- proc.time()[[3L]]
                        fit <- pls(
                            task$Xtrain,
                            task$Ytrain,
                            ncomp = family_ncomp,
                            method = family,
                            backend = backend,
                            classifier = if (classification) classifier else "argmax",
                            kernel = "linear",
                            fit = FALSE,
                            proj = FALSE,
                            return_variance = FALSE,
                            return_loadings = FALSE,
                            rsvd_oversample = rsvd_oversample,
                            rsvd_power = rsvd_power,
                            seed = 123
                        )
                        row$fit_seconds <- unname(proc.time()[[3L]] - started)
                        started <- proc.time()[[3L]]
                        prediction <- predict(fit, task$Xtest, backend = backend)$Ypred
                        row$prediction_seconds <- unname(proc.time()[[3L]] - started)
                        if (is.list(prediction)) {
                            prediction <- prediction[[length(prediction)]]
                        }
                        if (length(dim(prediction)) == 3L) {
                            prediction <- prediction[, , dim(prediction)[[3L]], drop = FALSE]
                            dim(prediction) <- dim(prediction)[1:2]
                        }
                        if (classification) {
                            row$metric <- mean(prediction == task$Ytest)
                        } else {
                            if (inherits(prediction, "float32")) {
                                prediction <- float::dbl(prediction)
                            }
                            observed <- task$Ytest
                            if (inherits(observed, "float32")) {
                                observed <- float::dbl(observed)
                            }
                            row$metric <- sqrt(mean((prediction - observed)^2))
                        }
                        row$execution_route <- fit$diagnostics$residency$route %||%
                            fit$diagnostics$execution_route %||%
                            fit$diagnostics$simpls$execution_route %||%
                            if (identical(backend, "cpu")) "compiled CPU" else NA_character_
                        row$algorithm_variant <-
                            fit$diagnostics$algorithm_variant %||% NA_character_
                        row$refresh_block <-
                            fit$diagnostics$resident_controls$refresh_block %||%
                            fit$diagnostics$simpls$candidate_block_size %||% NA_integer_
                        row$oversample <-
                            fit$diagnostics$rsvd$oversample %||% NA_integer_
                        row$power <- fit$diagnostics$rsvd$power %||% NA_integer_
                        NULL
                    }, error = function(condition) condition)
                    if (inherits(failure, "condition")) {
                        row$status <- "error"
                        row$error <- conditionMessage(failure)
                    }
                    row$total_seconds <- row$fit_seconds + row$prediction_seconds
                    result[[position]] <- as.data.frame(
                        row,
                        stringsAsFactors = FALSE
                    )
                }
            }
        }
    }
}

output <- do.call(rbind, result)
dir.create(dirname(output_path), recursive = TRUE, showWarnings = FALSE)
write.csv(output, output_path, row.names = FALSE)
if (!quiet) print(output)
