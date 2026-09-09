args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 4L) {
    stop("usage: Rscript cifar_worker.R LIBRARY TASK_RDS BACKEND PRECISION")
}

.libPaths(c(args[[1L]], .libPaths()))
suppressPackageStartupMessages(library(fastPLS))
if (args[[4L]] == "float32") {
    suppressPackageStartupMessages(library(float))
}

task <- readRDS(args[[2L]])
backend <- args[[3L]]
precision <- args[[4L]]
if (precision == "float32") {
    task$Xtrain <- float::fl(task$Xtrain)
    task$Xtest <- float::fl(task$Xtest)
} else if (precision != "float64") {
    stop("PRECISION must be float32 or float64")
}
invisible(gc(FALSE))

fit_started <- proc.time()[[3L]]
fit <- pls(
    task$Xtrain,
    task$Ytrain,
    ncomp = 50L,
    scaling = "none",
    method = "simpls",
    svd.method = "rsvd",
    backend = backend,
    classifier = "argmax",
    fit = FALSE,
    return_variance = FALSE,
    seed = 123L,
    oversample = 32L,
    power = 5L
)
fit_seconds <- proc.time()[[3L]] - fit_started

prediction_started <- proc.time()[[3L]]
predicted <- predict(fit, task$Xtest, backend = backend)$Ypred[[1L]]
prediction_seconds <- proc.time()[[3L]] - prediction_started
predicted <- factor(predicted, levels = levels(task$Ytest))
internal <- attr(fit, "fastPLS_internal")
`%||%` <- function(left, right) if (is.null(left)) right else left

result <- data.frame(
    backend = backend,
    precision = precision,
    fit_seconds = unname(fit_seconds),
    prediction_seconds = unname(prediction_seconds),
    total_seconds = unname(fit_seconds + prediction_seconds),
    accuracy = mean(predicted == task$Ytest),
    prediction_checksum = sum(as.integer(predicted) * seq_along(predicted)),
    execution_route = internal$execution_route %||%
        fit$diagnostics$residency$route %||% NA_character_,
    resident_backend = internal$resident_backend %||% NA_character_,
    algorithm = fit$diagnostics$algorithm_variant %||% NA_character_,
    stringsAsFactors = FALSE
)
write.table(result, row.names = FALSE, col.names = TRUE, sep = ",",
    quote = TRUE)
