#!/usr/bin/env Rscript
# This isolates component-path/model construction, not the SVD estimator.
args <- commandArgs(TRUE)
stopifnot(length(args) >= 2L, !grepl("frozen", args[[1L]], ignore.case = TRUE))
.libPaths(c(args[[1L]], .libPaths()))
library(fastPLS)
stopifnot(has_metal())
out <- args[[2L]]
dir.create(out, recursive = TRUE, showWarnings = FALSE)
set.seed(991)
n <- 150L
p <- 500L
q <- 6000L
rank <- 64L
components <- c(1L, 2L, 4L, 8L, 12L, 16L, 24L, 32L, 40L, 48L, 56L, 64L)
X <- matrix(rnorm(n * p), n, p)
R <- qr.Q(qr(matrix(rnorm(p * rank), p, rank)))
Q <- qr.Q(qr(matrix(rnorm(q * rank), q, rank)))
prep <- list(X = X, n = n, p = p, m = q,
    mX = matrix(0, 1, p), vX = matrix(1, 1, p), mY = matrix(0, 1, q))
factors <- list(R = R, Q = Q, rank = rank, V = R, ncomp = components,
    singular = seq(rank, 1), implicit = FALSE, resident = FALSE, xprod = FALSE)
stopifnot(!fastPLS:::.should_store_coefficients(p, q, length(components), TRUE))
make_model <- function(family) {
    if (family == "plssvd") {
        path <- fastPLS:::.metal_plssvd_path(prep, factors, components, FALSE)
        fastPLS:::.metal_plssvd_model(prep, factors, path, components)
    } else {
        path <- fastPLS:::.metal_simpls_path(prep, factors, components, FALSE)
        fastPLS:::.metal_simpls_model(prep, factors, path)
    }
}
rows <- list()
outputs <- list()
for (family in c("plssvd", "simpls")) {
    warmup <- make_model(family)
    rm(warmup)
    for (replicate in 1:20) {
        gc(full = TRUE)
        timing <- system.time(model <- make_model(family))[["elapsed"]]
        rows[[length(rows) + 1L]] <- data.frame(
            family = family, replicate = replicate, n = n, p = p, q = q,
            maximum_components = rank, requested_prefixes = length(components),
            scope = "component_path_and_model_assembly_excluding_estimator",
            seconds = timing, model_bytes = as.numeric(object.size(model)),
            response_weight_bytes = as.numeric(object.size(model$W_latent)))
        rm(model)
    }
    gc(full = TRUE)
    profile <- file.path(out, paste0(family, "_R_allocations.txt"))
    Rprofmem(profile)
    model <- tryCatch(make_model(family), finally = Rprofmem(NULL))
    outputs[[family]] <- fastPLS:::.pls_predict_metal(model, X[1:4, ], TRUE)
    rm(model)
}
write.csv(do.call(rbind, rows), file.path(out, "construction.csv"), row.names = FALSE)
saveRDS(outputs, file.path(out, "predictions.rds"))
if (length(args) >= 3L) {
    previous <- readRDS(file.path(args[[3L]], "predictions.rds"))
    stopifnot(isTRUE(all.equal(outputs, previous, tolerance = 0)))
}
cat("40 component-construction timings and separate allocation profiles completed\n")
