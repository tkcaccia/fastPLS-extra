#!/usr/bin/env Rscript
# CPU blocked prediction only; data/fitting and conversions are not timed.
args <- commandArgs(TRUE)
stopifnot(length(args) >= 2L, !grepl("frozen", args[[1L]], ignore.case = TRUE))
.libPaths(c(args[[1L]], .libPaths()))
library(fastPLS)
out <- args[[2L]]
dir.create(out, recursive = TRUE, showWarnings = FALSE)
set.seed(733)
make_case <- function(n, nt, p, q, components, block, iterations) {
    X <- matrix(rnorm(n * p), n, p)
    test <- matrix(rnorm(nt * p), nt, p)
    coefficient <- matrix(rnorm(p * q), p, q)
    list(X = X, test = test, Y = X %*% coefficient,
        observed = test %*% coefficient, components = components,
        block = block, iterations = iterations)
}
cases <- list(
    tall_predictors = make_case(150L, 1200L, 500L, 16L, 1:8, 400L, 10L),
    wide_responses = make_case(100L, 20L, 80L, 6000L,
        c(1L, 2L, 4L, 8L, 12L, 16L, 20L, 24L), 7L, 10L)
)
rows <- list()
agreement <- list()
for (dataset in names(cases)) {
    data <- cases[[dataset]]
    for (family in c("simpls", "plssvd")) {
        for (solver in c("irlba", "rsvd")) {
            model_file <- paste0(paste(dataset, family, solver, sep = "_"),
                "_model.rds")
            if (length(args) >= 3L) {
                raw <- readRDS(file.path(args[[3L]], model_file))
            } else {
                fit <- suppressWarnings(pls(data$X, data$Y,
                    method = family, svd.method = solver, backend = "cpu",
                    ncomp = data$components, seed = 13))
                raw <- fastPLS:::.fastpls_restore_internal_output_fields(fit)
                raw$B <- NULL
                raw$predict_latent_ok <- TRUE
                saveRDS(raw, file.path(out, model_file))
                rm(fit)
            }
            for (representation in if (family == "simpls") "shared" else
                c("stored", "factorized")) {
                model <- raw
                if (representation == "factorized") model$W_latent <- NULL
                key <- paste(dataset, family, solver, representation, sep = "_")
                predict_blocked <- function() {
                    fastPLS:::pls_predict_flash_cpu(model, data$test, TRUE, data$block)
                }
                predicted <- predict_blocked()
                expected <- fastPLS:::pls_predict(model, data$test, TRUE)
                stopifnot(isTRUE(all.equal(predicted$Ypred, expected$Ypred,
                    tolerance = 1e-11)))
                saveRDS(predicted, file.path(out, paste0(key, ".rds")))
                if (length(args) >= 3L) {
                    old <- readRDS(file.path(args[[3L]], paste0(key, ".rds")))
                    relative <- sqrt(sum((predicted$Ypred - old$Ypred)^2) /
                        max(sum(old$Ypred^2), .Machine$double.eps))
                    score_relative <- sqrt(sum((predicted$Ttest - old$Ttest)^2) /
                        max(sum(old$Ttest^2), .Machine$double.eps))
                    stopifnot(relative < 1e-11, score_relative < 1e-11)
                    agreement[[key]] <- data.frame(case = key,
                        prediction_relative_error = relative,
                        projection_relative_error = score_relative)
                    rm(old)
                }
                metric <- sqrt(mean((predicted$Ypred[, , length(model$ncomp)] -
                    data$observed)^2))
                rm(predicted, expected)
                for (replicate in 1:20) {
                    gc(full = TRUE)
                    elapsed <- system.time({
                        for (iteration in seq_len(data$iterations)) {
                            value <- predict_blocked()
                        }
                    })[["elapsed"]]
                    rows[[length(rows) + 1L]] <- data.frame(
                        case = key, dataset = dataset, family = family, solver = solver,
                        representation = representation, backend = "cpu",
                        precision = "float64", replicate = replicate,
                        iterations = data$iterations,
                        seconds_per_prediction = elapsed / data$iterations,
                        n_train = nrow(data$X), n_test = nrow(data$test),
                        p = ncol(data$X), q = model$m,
                        maximum_components = max(model$ncomp),
                        requested_prefixes = length(model$ncomp), metric = metric,
                        scope = "compiled_blocked_prediction_with_projection")
                    rm(value)
                }
            }
            rm(raw, model)
        }
    }
}
write.csv(do.call(rbind, rows), file.path(out, "prediction_timings.csv"), row.names = FALSE)
if (length(agreement)) {
    write.csv(do.call(rbind, agreement), file.path(out, "agreement.csv"), row.names = FALSE)
}
cat(length(rows), "blocked prediction timing rows completed\n")
