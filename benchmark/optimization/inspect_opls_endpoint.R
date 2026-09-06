#!/usr/bin/env Rscript
# Diagnose a completed component-path discrepancy without fitting old software.
args <- commandArgs(trailingOnly = TRUE)
stopifnot(length(args) == 4L)
.libPaths(unique(c(args[[1L]], .libPaths())))
suppressPackageStartupMessages(library(fastPLS))
options(backend = "cpu", cores = 1L)
task <- readRDS(args[[2L]])
cfg <- readRDS(args[[3L]])
if (is.null(cfg$run_id)) {
    cfg <- Filter(function(x) identical(x$run_id,
        "component_path__tabula__opls__k50__cpu__r1"), cfg)
    stopifnot(length(cfg) == 1L)
    cfg <- cfg[[1L]]
}
out <- args[[4L]]
dir.create(out, recursive = TRUE, showWarnings = FALSE)
writeLines(c(paste("Library:", normalizePath(args[[1L]])),
    capture.output(sessionInfo())), file.path(out, "session_info.txt"))
numeric_matrix <- function(x) {
    if (inherits(x, "float32")) float::dbl(x) else as.matrix(x)
}
X <- numeric_matrix(task$Xtrain)
Xtest <- numeric_matrix(task$Xtest)
Y <- task$Ytrain
levels_y <- if (is.factor(Y)) levels(Y) else sort(unique(as.character(Y)))
y_numeric <- match(as.character(Y), levels_y)
dummy <- matrix(0, length(Y), length(levels_y))
dummy[cbind(seq_along(Y), y_numeric)] <- 1
filter <- fastPLS:::opls_filter_cpp(X, dummy, cfg$north,
    match(cfg$scaling, c("centering", "autoscaling", "none")))
singular <- svd(filter$X, nu = 0L, nv = 0L)$d
write.csv(data.frame(index = seq_along(singular), singular_value = singular),
    file.path(out, "filtered_predictor_singular_values.csv"), row.names = FALSE)
rows <- list()
predictions <- list()
for (solver in c("irlba", "rsvd")) {
    for (seed in c(1001L, 1002L)) {
        for (components in c(40L, 48L, 49L, 50L)) {
            key <- paste(solver, seed, components, sep = "_")
            warnings <- character()
            value <- tryCatch(withCallingHandlers({
                elapsed <- system.time({
                    fit_args <- list(Xtrain = X, Ytrain = Y,
                        ncomp = components, method = "opls",
                        north = cfg$north, scaling = cfg$scaling,
                        backend = "cpu", svd.method = solver, seed = seed,
                        fit = FALSE, return_variance = FALSE)
                    for (control in c("oversample", "power")) {
                        if (is.finite(cfg[[control]])) {
                            fit_args[[control]] <- cfg[[control]]
                        }
                    }
                    fit <- do.call(pls, fit_args)
                    prediction <- predict(fit, Xtest)$Ypred[[1L]]
                })[["elapsed"]]
                model <- fastPLS:::.fastpls_restore_internal_output_fields(fit)
                inner <- fastPLS:::.fastpls_restore_internal_output_fields(model$inner_model)
                score <- filter$X %*% inner$R
                gram <- crossprod(score)
                predictions[[key]] <- prediction
                data.frame(solver = solver, seed = seed, ncomp = components,
                    effective_ncomp = max(inner$ncomp),
                    accuracy = mean(as.character(prediction) == as.character(task$Ytest)),
                    seconds = elapsed,
                    last_weight_norm = sqrt(sum(inner$R[, ncol(inner$R)]^2)),
                    last_score_norm = sqrt(tail(diag(gram), 1)),
                    score_orthogonality_error = max(abs(gram - diag(ncol(score)))),
                    status = "success", error = "")
            }, warning = function(w) {
                warnings <<- c(warnings, conditionMessage(w))
                invokeRestart("muffleWarning")
            }), error = function(e) {
                data.frame(solver = solver, seed = seed, ncomp = components,
                    effective_ncomp = NA, accuracy = NA, seconds = NA,
                    last_weight_norm = NA, last_score_norm = NA,
                    score_orthogonality_error = NA, status = "error",
                    error = conditionMessage(e))
            })
            value$warnings <- paste(warnings, collapse = " | ")
            rows[[length(rows) + 1L]] <- value
            write.csv(do.call(rbind, rows), file.path(out, "endpoint_diagnostics.csv"),
                row.names = FALSE)
            print(value)
        }
    }
}
saveRDS(predictions, file.path(out, "predictions.rds"))
