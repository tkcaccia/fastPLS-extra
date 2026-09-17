test_library <- Sys.getenv("FASTPLS_TEST_LIB", unset = "")
if (nzchar(test_library)) .libPaths(c(test_library, .libPaths()))
args <- commandArgs(trailingOnly = TRUE)
output <- if (length(args)) args[[1L]] else tempfile(fileext = ".csv")
suppressPackageStartupMessages({
    library(fastPLS)
    library(float)
})

set.seed(20260907)
n <- 96L
p <- 18L
x <- matrix(rnorm(n * p), n, p)
eta <- cbind(
    x[, 1L] - 0.6 * x[, 2L],
    -0.4 * x[, 1L] + x[, 3L],
    0.5 * x[, 2L] - x[, 3L]
)
y_class <- factor(max.col(eta + matrix(rnorm(n * 3L, sd = 0.35), n, 3L)))
y_reg <- cbind(
    x[, 1L] + 0.4 * x[, 4L],
    x[, 2L] - 0.7 * x[, 5L]
) + matrix(rnorm(n * 2L, sd = 0.1), n, 2L)
train <- seq_len(72L)
test <- setdiff(seq_len(n), train)

fit_one <- function(family, task, classifier = "argmax") {
    response <- if (task == "regression") y_reg else y_class
    common <- list(
        Xtrain = fl(x[train, , drop = FALSE]),
        Ytrain = if (task == "regression") {
            fl(response[train, , drop = FALSE])
        } else {
            response[train]
        },
        Xtest = fl(x[test, , drop = FALSE]),
        Ytest = if (task == "regression") {
            fl(response[test, , drop = FALSE])
        } else {
            response[test]
        },
        ncomp = 1:3,
        method = family,
        svd.method = "rsvd",
        classifier = classifier,
        seed = 19,
        fit = FALSE,
        return_variance = FALSE
    )
    if (family == "opls") common$north <- 1L
    if (family == "kernelpls") {
        common$kernel <- if (classifier == "lda") "poly" else "rbf"
        common$gamma <- 0.08
        common$degree <- 2L
        common$coef0 <- 1
    }
    cpu_args <- common
    cpu_args$backend <- "cpu"
    metal_args <- common
    metal_args$backend <- "metal"
    cpu_time <- system.time(cpu <- do.call(pls, cpu_args))[["elapsed"]]
    metal_time <- system.time(metal <- do.call(pls, metal_args))[["elapsed"]]
    cpu_pred <- cpu$Ypred[[3L]]
    metal_pred <- metal$Ypred[[3L]]
    if (task == "classification") {
        metric_cpu <- mean(cpu_pred == response[test])
        metric_metal <- mean(metal_pred == response[test])
        agreement <- mean(cpu_pred == metal_pred)
        relative_error <- NA_real_
    } else {
        cpu_pred <- as.matrix(cpu_pred)
        metal_pred <- as.matrix(float::dbl(metal_pred))
        metric_cpu <- sqrt(mean((cpu_pred - response[test, ])^2))
        metric_metal <- sqrt(mean((metal_pred - response[test, ])^2))
        agreement <- NA_real_
        relative_error <- sqrt(sum((cpu_pred - metal_pred)^2)) /
            max(sqrt(sum(cpu_pred^2)), .Machine$double.eps)
    }
    metadata <- attr(metal, "fastPLS_internal", exact = TRUE)
    controls <- metadata$resident_controls
    data.frame(
        family = family,
        task = task,
        classifier = if (task == "classification") classifier else NA_character_,
        cpu_seconds = cpu_time,
        metal_seconds = metal_time,
        cpu_metric = metric_cpu,
        metal_metric = metric_metal,
        metric_difference = metric_metal - metric_cpu,
        label_agreement = agreement,
        relative_prediction_error = relative_error,
        resident_backend = metadata$resident_backend %||% NA_character_,
        gpu_resident = isTRUE(metadata$gpu_resident),
        host_assisted_components = isTRUE(controls$host_assisted_components),
        stringsAsFactors = FALSE
    )
}

`%||%` <- function(x, y) if (is.null(x)) y else x
cases <- list(
    c("opls", "classification", "argmax"),
    c("opls", "classification", "lda"),
    c("opls", "regression", "argmax"),
    c("kernelpls", "classification", "argmax"),
    c("kernelpls", "classification", "lda"),
    c("kernelpls", "regression", "argmax")
)
results <- do.call(rbind, lapply(cases, function(case) {
    tryCatch(
        fit_one(case[[1L]], case[[2L]], case[[3L]]),
        error = function(error) data.frame(
            family = case[[1L]], task = case[[2L]], classifier = case[[3L]],
            error = conditionMessage(error), stringsAsFactors = FALSE
        )
    )
}))
write.csv(results, output, row.names = FALSE)
print(results)
