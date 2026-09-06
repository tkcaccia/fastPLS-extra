#!/usr/bin/env Rscript

# Exercise the benchmark helpers without loading the large canonical task.
expressions <- parse("benchmark/benchmark_nmr_qualified_solver.R")
helpers <- new.env(parent = globalenv())
helpers$`%||%` <- function(x, y) if (is.null(x)) y else x
wanted <- c("as_double", "extract_prediction", "regression_metrics")
for (expression in expressions) {
    if (is.call(expression) && identical(expression[[1L]], as.name("<-")) &&
        is.symbol(expression[[2L]]) && as.character(expression[[2L]]) %in% wanted) {
        eval(expression, helpers)
    }
}
y <- matrix(c(1, 2, 3, 4, 5, 6), 3, 2)
y32 <- float::fl(y)
stopifnot(identical(helpers$extract_prediction(y32, 2L), y))
stopifnot(identical(helpers$extract_prediction(list("ncomp=2" = y32), 2L), y))
metrics <- helpers$regression_metrics(y, y + 1, c(2, 5))
stopifnot(identical(unname(metrics["RMSD"]), 1),
          identical(unname(metrics["MAE"]), 1),
          identical(unname(metrics["Q2"]), -0.5))
bad_shape <- tryCatch({
    helpers$regression_metrics(y, y, 2)
    FALSE
}, error = function(error) TRUE)
stopifnot(bad_shape)
cat("NMR float32 extraction and common-denominator metric checks passed\n")
