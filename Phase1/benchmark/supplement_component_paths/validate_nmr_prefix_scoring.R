#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 1L) {
    stop("Usage: validate_nmr_prefix_scoring.R FASTPLS_LIBRARY", call. = FALSE)
}
.libPaths(c(normalizePath(args[[1L]], mustWork = TRUE), .libPaths()))
suppressPackageStartupMessages(library(fastPLS))

script_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
script_path <- normalizePath(sub("^--file=", "", script_arg[[1L]]))
source(file.path(dirname(dirname(script_path)), "nmr_component_selection_helpers.R"))

set.seed(31415)
X <- matrix(rnorm(72L * 18L), 72L, 18L)
B <- matrix(rnorm(18L * 31L), 18L, 31L)
Y <- X %*% B + matrix(rnorm(72L * 31L, sd = 0.05), 72L, 31L)
train <- seq_len(54L)
test <- setdiff(seq_len(72L), train)
grid <- c(1L, 2L, 3L)

as_matrix <- function(value) {
    if (inherits(value, "float32")) float::dbl(value) else as.matrix(value)
}

extract_prediction <- function(prediction, index) {
    value <- prediction$Ypred
    if (is.list(value)) return(as_matrix(value[[index]]))
    dimensions <- dim(value)
    if (length(dimensions) == 3L) {
        return(matrix(value[, , index], nrow = dimensions[[1L]]))
    }
    as_matrix(value)
}

rows <- list()
for (family in c("plssvd", "simpls", "opls", "kernelpls")) {
    fit <- pls(
        float::fl(X[train, , drop = FALSE]),
        float::fl(Y[train, , drop = FALSE]),
        ncomp = grid,
        method = family,
        backend = "cpu",
        north = 1L,
        kernel = "linear",
        fit = FALSE,
        return_variance = FALSE,
        seed = 123L
    )
    public <- predict(fit, float::fl(X[test, , drop = FALSE]))
    workspace <- fastpls_nmr_prepare_scoring(
        fit,
        float::fl(X[test, , drop = FALSE]),
        Y[test, , drop = FALSE],
        11L
    )
    for (index in seq_along(grid)) {
        k <- grid[[index]]
        expected <- sqrt(mean(
            (Y[test, , drop = FALSE] - extract_prediction(public, index))^2
        ))
        observed <- fastpls_nmr_score_prepared(
            workspace,
            Y[test, , drop = FALSE],
            k,
            11L
        )[["RMSD"]]
        rows[[length(rows) + 1L]] <- data.frame(
            family = family,
            ncomp = k,
            public_rmsd = expected,
            blocked_rmsd = observed,
            absolute_difference = abs(expected - observed)
        )
    }
}

result <- do.call(rbind, rows)
print(result)
if (any(!is.finite(result$absolute_difference)) ||
    max(result$absolute_difference) > 2e-5) {
    stop("The blocked NMR scorer disagrees with public prediction.", call. = FALSE)
}
