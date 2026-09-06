#!/usr/bin/env Rscript
# One prediction in a separate process; fixed latent factors are not a fit.
args <- commandArgs(TRUE)
stopifnot(length(args) == 3L,
    !grepl("frozen", args[[1L]], ignore.case = TRUE))
.libPaths(c(args[[1L]], .libPaths()))
library(fastPLS)
family <- match.arg(args[[2L]], c("simpls", "plssvd"))
set.seed(971)
p <- 200L
q <- 8000L
rank <- 96L
components <- as.integer(seq(6, rank, by = 6))
X <- matrix(rnorm(8L * p), 8L, p)
R <- matrix(rnorm(p * rank) / sqrt(p), p, rank)
Q <- matrix(rnorm(q * rank) / sqrt(rank), q, rank)
model <- list(R = R, Q = Q, m = q, p = p, ncomp = components,
    mX = matrix(0, 1, p), vX = matrix(1, 1, p),
    mY = matrix(0, 1, q), pls_method = family)
if (family == "plssvd") {
    model$W_latent <- array(0, c(rank, q, length(components)))
    for (a in seq_along(components)) {
        model$W_latent[seq_len(components[[a]]), , a] <-
            t(Q[, seq_len(components[[a]]), drop = FALSE])
    }
}
events <- Sys.getenv("FASTPLS_MEASUREMENT_EVENTS")
stopifnot(nzchar(events))
mark <- function(event, rss = NA_real_) {
    row <- data.frame(event = event, replicate = 1L,
        timestamp = as.numeric(Sys.time()), rss_mib = rss)
    write.table(row, events, append = file.exists(events), sep = ",",
        row.names = FALSE, col.names = !file.exists(events), na = "")
}
gc(full = TRUE)
Sys.sleep(0.3)
rss <- as.numeric(system2("ps", c("-o", "rss=", "-p", Sys.getpid()),
    stdout = TRUE)) / 1024
mark("fit_start", rss)
value <- fastPLS:::pls_predict_flash_cpu(model, X, TRUE, 4L)
Sys.sleep(0.15)
mark("predict_end")
expected <- X %*% R %*% t(Q)
stopifnot(isTRUE(all.equal(value$Ypred[, , length(components)], expected,
    tolerance = 1e-12)))
write.csv(data.frame(family = family, scope = "single_blocked_prediction_only",
    n_test = nrow(X), p = p, q = q, max_components = rank,
    prefixes = length(components), model_bytes = as.numeric(object.size(model)),
    output_bytes = as.numeric(object.size(value)),
    full_weight_cube_bytes = 8 * rank * q * length(components),
    single_weight_matrix_bytes = 8 * rank * q,
    prediction_sum = sum(value$Ypred), prediction_sumsq = sum(value$Ypred^2)),
    args[[3L]], row.names = FALSE)
