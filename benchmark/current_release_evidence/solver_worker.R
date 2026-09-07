#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 8L) {
    stop("Usage: solver_worker.R LIB SHAPE FAMILY SOLVER REP OUTPUT READY GO",
         call. = FALSE)
}
lib <- args[[1L]]
shape <- args[[2L]]
family <- args[[3L]]
solver <- args[[4L]]
replicate_id <- as.integer(args[[5L]])
output <- args[[6L]]
ready <- args[[7L]]
go <- args[[8L]]
.libPaths(c(lib, .libPaths()))
suppressPackageStartupMessages({
    library(fastPLS)
    library(fastPLSextra)
})
stopifnot(as.character(packageVersion("fastPLS")) == "0.99.40")

set.seed(9107L)
dims <- switch(
    shape,
    balanced = c(n = 1600L, p = 600L, q = 120L),
    predictor_wide = c(n = 700L, p = 2800L, q = 20L),
    response_wide = c(n = 700L, p = 300L, q = 2800L),
    stop("unknown shape", call. = FALSE)
)
n_test <- as.integer(dims[["n"]] / 4L)
n_total <- dims[["n"]] + n_test
latent <- 15L
X <- matrix(rnorm(n_total * dims[["p"]]), n_total, dims[["p"]])
U <- matrix(rnorm(dims[["p"]] * latent), dims[["p"]], latent) / sqrt(dims[["p"]])
V <- matrix(rnorm(latent * dims[["q"]]), latent, dims[["q"]]) / sqrt(latent)
Y <- X %*% U %*% V + matrix(rnorm(n_total * dims[["q"]], sd = 0.4),
                             n_total, dims[["q"]])
train <- seq_len(dims[["n"]])
test <- dims[["n"]] + seq_len(n_test)
Xtrain <- X[train, , drop = FALSE]
Ytrain <- Y[train, , drop = FALSE]
Xtest <- X[test, , drop = FALSE]
Ytest <- Y[test, , drop = FALSE]
rm(X, Y, U, V)
gc(full = TRUE)
rss_mib <- function() as.numeric(ps::ps_memory_info(ps::ps_handle())[["rss"]]) / 1024^2
writeLines(format(rss_mib(), digits = 15L), ready)
while (!file.exists(go)) Sys.sleep(0.01)

ncomp <- 20L
elapsed <- system.time({
    if (solver == "rsvd") {
        fit <- fastPLS::pls(
            Xtrain, Ytrain, ncomp = ncomp, method = family,
            backend = "cpu", fit = FALSE, return_variance = FALSE,
            seed = 123L
        )
        prediction <- predict(fit, Xtest)$Ypred
    } else {
        fit <- fastPLSextra::pls_irlba(
            Xtrain, Ytrain, ncomp = ncomp, method = family,
            scaling = "center", fit = FALSE, seed = 123L
        )
        prediction <- predict(fit, Xtest)
    }
})[["elapsed"]]
key <- paste0("ncomp=", ncomp)
predicted <- if (is.list(prediction)) prediction[[key]] else {
    prediction[, , dim(prediction)[[3L]], drop = TRUE]
}
rmsd <- sqrt(mean((as.matrix(predicted) - Ytest)^2))
row <- data.frame(
    package_version = as.character(packageVersion("fastPLS")),
    companion_version = as.character(packageVersion("fastPLSextra")),
    shape = shape,
    family = family,
    solver = solver,
    replicate = replicate_id,
    n_train = dims[["n"]],
    n_test = n_test,
    p = dims[["p"]],
    q = dims[["q"]],
    ncomp = ncomp,
    total_sec = elapsed,
    RMSD = rmsd,
    prefit_rss_mib = as.numeric(readLines(ready)[[1L]]),
    final_rss_mib = rss_mib(),
    stringsAsFactors = FALSE
)
dir.create(dirname(output), recursive = TRUE, showWarnings = FALSE)
write.csv(row, output, row.names = FALSE)
