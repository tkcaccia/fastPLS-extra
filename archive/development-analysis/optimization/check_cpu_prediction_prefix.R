#!/usr/bin/env Rscript
# Native compact prediction only; fit and data construction are outside timing.
args <- commandArgs(TRUE)
stopifnot(length(args) >= 2L, !grepl("frozen", args[[1L]], ignore.case = TRUE))
.libPaths(c(args[[1L]], .libPaths()))
library(fastPLS)
out <- args[[2L]]
dir.create(out, recursive = TRUE, showWarnings = FALSE)
set.seed(221)
make_case <- function(n, nt, p, q, components) {
    X <- matrix(rnorm(n * p), n, p)
    test <- matrix(rnorm(nt * p), nt, p)
    coefficient <- matrix(rnorm(p * q), p, q)
    list(X = X, test = test, Y = X %*% coefficient,
        observed = test %*% coefficient, components = components)
}
cases <- list(
    iris = list(X = as.matrix(iris[1:120, -5]),
        test = as.matrix(iris[121:150, -5]),
        Y = iris$Species[1:120], components = 1:2),
    tall_predictors = make_case(180L, 4000L, 800L, 16L, 1:12),
    wide_responses = make_case(100L, 120L, 80L, 512L, 1:12)
)
rows <- list()
agreement <- list()
for (dataset in names(cases)) {
    data <- cases[[dataset]]
    for (family in c("simpls", "plssvd")) {
        for (solver in c("irlba", "rsvd")) {
            fit <- suppressWarnings(pls(data$X, data$Y,
                method = family, svd.method = solver, backend = "cpu",
                ncomp = data$components, seed = 13))
            model <- fastPLS:::.fastpls_restore_internal_output_fields(fit)
            model$B <- NULL
            model$predict_latent_ok <- TRUE
            predicted <- fastPLS:::pls_predict(model, data$test, TRUE)
            key <- paste(dataset, family, solver, sep = "_")
            saveRDS(predicted, file.path(out, paste0(key, ".rds")))
            if (length(args) >= 3L) {
                old <- readRDS(file.path(args[[3L]], paste0(key, ".rds")))
                difference <- predicted$Ypred - old$Ypred
                relative <- sqrt(sum(difference^2) /
                    max(sum(old$Ypred^2), .Machine$double.eps))
                score_relative <- sqrt(sum((predicted$Ttest - old$Ttest)^2) /
                    max(sum(old$Ttest^2), .Machine$double.eps))
                stopifnot(relative < 1e-11, score_relative < 1e-11)
                agreement[[key]] <- data.frame(case = key,
                    prediction_relative_error = relative,
                    projection_relative_error = score_relative)
                rm(old, difference)
            }
            metric <- if (is.factor(data$Y)) {
                mean(max.col(predicted$Ypred[, , length(model$ncomp)],
                    ties.method = "first") == as.integer(iris$Species[121:150]))
            } else {
                sqrt(mean((predicted$Ypred[, , length(model$ncomp)] -
                    data$observed)^2))
            }
            rm(predicted)
            iterations <- switch(dataset,
                iris = 10000L, wide_responses = 50L, 5L)
            for (replicate in 1:20) {
                gc(full = TRUE)
                elapsed <- system.time({
                    for (iteration in seq_len(iterations)) {
                        value <- fastPLS:::pls_predict(model, data$test, TRUE)
                    }
                })[["elapsed"]]
                rows[[length(rows) + 1L]] <- data.frame(
                    case = key, dataset = dataset, family = family, solver = solver,
                    backend = "cpu", precision = "float64", replicate = replicate,
                    iterations = iterations, seconds_per_prediction = elapsed / iterations,
                    n_train = nrow(data$X), n_test = nrow(data$test),
                    p = ncol(data$X), q = model$m,
                    maximum_components = max(model$ncomp),
                    requested_prefixes = length(model$ncomp), metric = metric,
                    scope = "compiled_compact_prediction_with_projection")
                rm(value)
            }
            rm(fit, model)
        }
    }
}
write.csv(do.call(rbind, rows), file.path(out, "prediction_timings.csv"), row.names = FALSE)
if (length(agreement)) {
    write.csv(do.call(rbind, agreement), file.path(out, "agreement.csv"), row.names = FALSE)
}
cat(length(rows), "batched prediction timing rows completed\n")
