#!/usr/bin/env Rscript
# Two current-code candidates, never the frozen release or external PLS.
args <- commandArgs(trailingOnly = TRUE)
stopifnot(length(args) >= 2L)
lib <- normalizePath(args[[1L]], mustWork = TRUE)
if (grepl("frozen", lib, ignore.case = TRUE)) stop("Current candidates only")
.libPaths(unique(c(lib, .libPaths())))
suppressPackageStartupMessages(library(fastPLS))
backend <- if (length(args) >= 4L) args[[4L]] else "metal"
stopifnot(backend %in% c("cpu", "cuda", "metal"),
    normalizePath(find.package("fastPLS")) == file.path(lib, "fastPLS"))
if (backend == "metal") stopifnot(has_metal())
if (backend == "cuda") stopifnot(has_cuda())
dir.create(args[[2L]], recursive = TRUE, showWarnings = FALSE)
results <- list()
times <- list()
set.seed(820)
X <- float::fl(matrix(rnorm(180 * 61), 180, 61))
Y <- float::fl(matrix(rnorm(180 * 43), 180, 43))
y <- factor(rep(1:15, 12))
for (solver in if (backend == "cuda") "rsvd" else c("rsvd", "irlba")) {
    for (family in c("plssvd", "simpls", "opls", "kernelpls")) {
        kernels <- if (family == "kernelpls") c("linear", "rbf", "poly") else "linear"
        for (kernel in kernels) {
            for (head in c("regression", "argmax", "lda")) {
                key <- paste(solver, family, kernel, head, sep = "/")
                target <- if (head == "regression") Y[1:150, ] else y[1:150]
                for (iteration in 1:3) {
                    start <- proc.time()[["elapsed"]]
                    model <- suppressWarnings(pls(
                        X[1:150, ], target, X[151:180, ], ncomp = c(2L, 4L),
                        method = family, kernel = kernel, backend = backend,
                        svd.method = solver, oversample = 3, power = 2,
                        classifier = if (head == "lda") "lda" else "argmax",
                        fit = TRUE, seed = 24
                    ))
                    times[[length(times) + 1L]] <- data.frame(
                        case = key, repetition = iteration,
                        total_seconds = proc.time()[["elapsed"]] - start)
                }
                fields <- intersect(c("Ypred", "Yfit", "R", "Q", "Ttrain", "R2Y"), names(model))
                stopifnot(!is.null(model$Ypred))
                results[[key]] <- list(outputs = model[fields], rng = .Random.seed)
            }
        }
    }
}
saveRDS(results, file.path(args[[2L]], "results.rds"))
write.csv(do.call(rbind, times), file.path(args[[2L]], "times.csv"), row.names = FALSE)
if (length(args) > 2L && nzchar(args[[3L]])) {
    before <- readRDS(file.path(args[[3L]], "results.rds"))
    stopifnot(identical(names(before), names(results)))
    for (key in names(results)) {
        difference <- all.equal(results[[key]], before[[key]], tolerance = 0)
        if (!isTRUE(difference)) stop(key, ": ", paste(difference, collapse = "; "))
    }
}
cat("Verified", length(results), "float32", backend, "SVD/model paths and RNG states\n")
