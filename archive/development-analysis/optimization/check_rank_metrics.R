#!/usr/bin/env Rscript
args <- commandArgs(trailingOnly = TRUE)
stopifnot(length(args) %in% 2:3)
.libPaths(unique(c(args[[1L]], .libPaths())))
suppressPackageStartupMessages(library(fastPLS))
out <- args[[2L]]
dir.create(out, recursive = TRUE, showWarnings = FALSE)
has_native <- exists("spearman_correlation_cpp", asNamespace("fastPLS"),
    inherits = FALSE)
native <- if (has_native) fastPLS:::spearman_correlation_cpp else NULL
reference <- function(x, y) suppressWarnings(cor(x, y,
    method = "spearman", use = "complete.obs"))
rows <- list()
for (n in if (has_native) c(9000L, 1800000L, 8506500L) else integer()) {
    for (ties in c(FALSE, TRUE)) {
        set.seed(813)
        x <- rnorm(n)
        y <- 0.2 * x + rnorm(n)
        if (ties) {
            x <- round(x, 1)
            y <- round(y, 1)
        }
        expected <- reference(x, y)
        actual <- native(x, y)
        stopifnot(isTRUE(all.equal(expected, actual, tolerance = 1e-14)))
        for (replicate in seq_len(5L)) {
            order <- if (replicate %% 2L) c("reference", "compiled") else
                c("compiled", "reference")
            for (method in order) {
                gc()
                elapsed <- system.time(value <- if (method == "reference") {
                    reference(x, y)
                } else native(x, y))[["elapsed"]]
                rows[[length(rows) + 1L]] <- data.frame(
                    n = n, ties = ties, replicate = replicate,
                    method = method, seconds = elapsed,
                    value = value, absolute_error = abs(value - expected))
            }
        }
        write.csv(do.call(rbind, rows), file.path(out, "rank_timings.csv"),
            row.names = FALSE)
        cat(n, "values; ties:", ties, "; numerical comparison met 1e-14\n")
    }
}

set.seed(829)
X <- matrix(rnorm(100 * 25), 100, 25)
Y <- X %*% matrix(rnorm(25 * 60), 25, 60) + matrix(rnorm(100 * 60), 100, 60)
models <- list()
for (backend in c("cpu", if (has_metal()) "metal")) {
    for (family in c("plssvd", "simpls", "opls", "kernelpls")) {
        for (solver in if (backend == "cpu") c("irlba", "rsvd") else "rsvd") {
            key <- paste(backend, family, solver, sep = "_")
            model <- suppressWarnings(pls(X, Y, X, Y, ncomp = c(2, 4),
                method = family, backend = backend, svd.method = solver,
                fit = TRUE, return_variance = FALSE, seed = 87))
            models[[key]] <- model$metrics
        }
    }
}
if (length(args) == 3L) {
    expected <- readRDS(file.path(args[[3L]], "public_metrics.rds"))
    stopifnot(isTRUE(all.equal(models, expected, tolerance = 1e-12)))
}
saveRDS(models, file.path(out, "public_metrics.rds"))
cat(length(models), "public model metric paths checked\n")
