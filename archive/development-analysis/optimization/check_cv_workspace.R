#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
stopifnot(length(args) >= 2L)
lib <- Sys.getenv("FASTPLS_LIB")
if (nzchar(lib)) .libPaths(c(lib, .libPaths()))
suppressPackageStartupMessages(library(fastPLS))
backend <- match.arg(args[[1L]], c("cpu", "cuda", "metal"))
set.seed(42)
X <- matrix(rnorm(90 * 16), 90, 16)
Yreg <- matrix(rnorm(90 * 6), 90, 6) + X[, 1:6]
labels <- matrix(as.double(rep(1:6, each = 15)), ncol = 1)
inputs <- serialize(list(X, Yreg, labels), NULL)
out <- list()
solvers <- if (backend == "cpu") c("cpu_rsvd", "irlba") else "cpu_rsvd"
for (solver in solvers) {
    for (scaling in 1:3) {
        for (head in c("regression", "argmax", "lda")) {
            for (store in c(TRUE, FALSE)) {
                for (method in c(1L, 3L, 4L, 5L)) {
                    classification <- head != "regression"
                    metric_ids <- if (classification) 4L else 2:4
                    for (metric_id in metric_ids) {
                    set.seed(92)
                    value <- fastPLS:::pls_cv_predict_compiled(
                        X, if (classification) labels else Yreg,
                        seq_len(nrow(X)), 1:6, scaling, 4L, method,
                        match(backend, c("cpu", "cuda", "metal")) - 1L,
                        fastPLS:::.svd_method_id(solver), 32L, 5L, 0, 92L,
                        classification, 6L, FALSE, 1L, head != "lda",
                        matrix(numeric(), 0, 0), as.integer(head == "lda"),
                        0, store, metric_id
                    )
                    key <- paste(solver, scaling, head, store, method, metric_id)
                    out[[key]] <- list(value = value, random_state = .Random.seed)
                    stopifnot(identical(serialize(list(X, Yreg, labels), NULL),
                                        inputs))
                    }
                }
            }
        }
    }
}
if (length(args) >= 3L) {
    reference <- readRDS(args[[3L]])
    stopifnot(identical(names(out), names(reference)))
    for (key in names(out)) {
        comparison <- all.equal(out[[key]], reference[[key]], tolerance = 1e-10)
        if (!isTRUE(comparison)) stop(key, ": ", paste(comparison, collapse = "; "))
    }
}
dir.create(dirname(args[[2L]]), recursive = TRUE, showWarnings = FALSE)
saveRDS(out, args[[2L]])
cat("Checked", length(out), backend, "CV configurations\n")
