#!/usr/bin/env Rscript

# Candidate-only regression check for the allocation refactor; never fits a
# frozen package or an external PLS implementation.
args <- commandArgs(trailingOnly = TRUE)
stopifnot(length(args) >= 1L)
lib <- Sys.getenv("FASTPLS_LIB")
if (nzchar(lib)) .libPaths(c(lib, .libPaths()))
suppressPackageStartupMessages(library(fastPLS))
set.seed(708)
X <- matrix(rnorm(140 * 32), 140, 32)
Y <- matrix(rnorm(140 * 12), 140, 12)
Y[, 2:4] <- Y[, 2:4] + X[, 1:3]
out <- list()
for (family in c("simpls", "plssvd", "opls", "kernelpls")) {
    for (scaling in c("none", "centering", "autoscaling")) {
        set.seed(61)
        fit <- pls(
            X, Y, X[1:15, ], ncomp = 1:6, method = family,
            backend = "cpu", svd.method = "irlba", scaling = scaling,
            seed = 61, fit = TRUE, return_variance = FALSE
        )
        out[[paste(family, scaling)]] <- list(
            R = fit$R, Q = fit$Q, B = fit$B, Yfit = fit$Yfit,
            Ypred = fit$Ypred, random_state = .Random.seed
        )
    }
}
for (width in c(32L, 16L, 32L)) {
    set.seed(61)
    fit <- fastPLS:::pls_model2_fast_rsvd_xprod_precision(
        X[, seq_len(width)], Y, 1:6, 1L, FALSE, 12L, 2L, 0,
        61L, 5L
    )
    out[[paste0("implicit_", length(out))]] <- list(
        R = fit$R, Q = fit$Q, B = fit$B, random_state = .Random.seed
    )
}
if (length(args) > 1L) {
    reference <- readRDS(args[[2L]])
    errors <- vapply(names(out), function(key) {
        stopifnot(identical(out[[key]]$random_state,
                            reference[[key]]$random_state))
        stopifnot(isTRUE(all.equal(out[[key]], reference[[key]],
                                  tolerance = 1e-12)))
        values <- unlist(out[[key]][setdiff(names(out[[key]]), "random_state")])
        old <- unlist(reference[[key]][setdiff(names(out[[key]]), "random_state")])
        max(abs(values - old), na.rm = TRUE)
    }, numeric(1))
    print(errors)
}
dir.create(dirname(args[[1L]]), showWarnings = FALSE, recursive = TRUE)
saveRDS(out, args[[1L]])
cat("Checked", length(out), "candidate configurations\n")
