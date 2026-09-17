#!/usr/bin/env Rscript

test_library <- Sys.getenv("FASTPLS_TEST_LIB", unset = "")
if (nzchar(test_library)) .libPaths(c(test_library, .libPaths()))
args <- commandArgs(trailingOnly = TRUE)
output <- if (length(args)) args[[1L]] else tempfile(fileext = ".csv")
library(fastPLS)

prediction_at <- function(fit, component) {
    value <- fit$Ypred
    name <- paste0("ncomp=", component)
    if (is.data.frame(value) || is.list(value)) return(value[[name]])
    if (length(dim(value)) == 3L) {
        index <- if (!is.null(dimnames(value)[[3L]])) {
            match(name, dimnames(value)[[3L]])
        } else {
            dim(value)[[3L]]
        }
        return(value[, , index, drop = TRUE])
    }
    value
}

fit_once <- function(Xtrain, Ytrain, Xtest, Ytest, method, kernel,
                     classifier, backend, precision, component) {
    if (identical(precision, "float32")) {
        Xtrain <- float::fl(Xtrain)
        Xtest <- float::fl(Xtest)
        if (!is.factor(Ytrain)) {
            Ytrain <- float::fl(Ytrain)
            Ytest <- float::fl(Ytest)
        }
    }
    elapsed <- system.time({
        fit <- pls(
            Xtrain, Ytrain, Xtest, Ytest,
            ncomp = component,
            method = method,
            kernel = kernel,
            classifier = classifier,
            backend = backend,
            north = 1L,
            return_variance = FALSE,
            rsvd_oversample = 32L,
            rsvd_power = 5L,
            seed = 19L
        )
    })[["elapsed"]]
    list(fit = fit, elapsed = elapsed,
         prediction = prediction_at(fit, component))
}

set.seed(20260907)
n <- 240L
p <- 32L
component <- 5L
X <- matrix(rnorm(n * p), n, p)
class <- factor(rep(c("A", "B", "C"), each = n / 3L))
X[class == "B", 1:4] <- X[class == "B", 1:4] + 0.9
X[class == "C", 1:4] <- X[class == "C", 1:4] - 0.9
Y <- cbind(
    1.2 * X[, 1L] - 0.7 * X[, 2L] + rnorm(n, sd = 0.15),
    X[, 3L] + 0.5 * X[, 4L] + rnorm(n, sd = 0.15)
)
train <- unlist(lapply(split(seq_len(n), class), head, 60L), use.names = FALSE)
test <- setdiff(seq_len(n), train)

tasks <- list(
    list(task = "classification", response = class, classifier = "argmax"),
    list(task = "classification", response = class, classifier = "lda"),
    list(task = "regression", response = Y, classifier = "argmax")
)
families <- list(
    list(method = "opls", kernel = "linear"),
    list(method = "kernelpls", kernel = "rbf"),
    list(method = "kernelpls", kernel = "poly")
)

rows <- list()
index <- 0L
for (precision in c("float64", "float32")) {
    for (family in families) {
        for (task in tasks) {
            response <- task$response
            Ytrain <- if (is.factor(response)) response[train] else response[train, , drop = FALSE]
            Ytest <- if (is.factor(response)) response[test] else response[test, , drop = FALSE]
            cpu <- fit_once(
                X[train, , drop = FALSE], Ytrain,
                X[test, , drop = FALSE], Ytest,
                family$method, family$kernel, task$classifier,
                "cpu", precision, component
            )
            cuda <- fit_once(
                X[train, , drop = FALSE], Ytrain,
                X[test, , drop = FALSE], Ytest,
                family$method, family$kernel, task$classifier,
                "cuda", precision, component
            )
            if (is.factor(response)) {
                agreement <- mean(as.character(cpu$prediction) ==
                                  as.character(cuda$prediction))
                cpu_metric <- mean(cpu$prediction == Ytest)
                cuda_metric <- mean(cuda$prediction == Ytest)
                relative_error <- NA_real_
            } else {
                cpu_prediction <- as.matrix(cpu$prediction)
                cuda_prediction <- as.matrix(cuda$prediction)
                agreement <- NA_real_
                cpu_metric <- sqrt(mean((cpu_prediction - as.matrix(Ytest))^2))
                cuda_metric <- sqrt(mean((cuda_prediction - as.matrix(Ytest))^2))
                relative_error <- sqrt(sum((cuda_prediction - cpu_prediction)^2)) /
                    max(sqrt(sum(cpu_prediction^2)), .Machine$double.eps)
            }
            route <- cuda$fit$diagnostics$residency$route
            index <- index + 1L
            rows[[index]] <- data.frame(
                precision = precision,
                task = task$task,
                classifier = task$classifier,
                method = family$method,
                kernel = family$kernel,
                component = component,
                cpu_seconds = cpu$elapsed,
                cuda_seconds = cuda$elapsed,
                cpu_metric = cpu_metric,
                cuda_metric = cuda_metric,
                metric_difference = cuda_metric - cpu_metric,
                prediction_agreement = agreement,
                relative_prediction_error = relative_error,
                resident_route = if (is.null(route)) NA_character_ else route,
                stringsAsFactors = FALSE
            )
        }
    }
}

result <- do.call(rbind, rows)
write.csv(result, output, row.names = FALSE)
print(result, row.names = FALSE)
