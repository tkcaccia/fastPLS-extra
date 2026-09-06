test_that("the companion uses main headers without loading its namespace", {
    # The fresh child avoids dependence on packages loaded by testthat helpers.
    root <- dirname(find.package("fastPLSextra"))
    expression <- paste0(
        ".libPaths(c(", deparse(root), ", .libPaths())); ",
        "library(fastPLSextra); ",
        "stopifnot(!'fastPLS' %in% loadedNamespaces()); ",
        "set.seed(1); x <- matrix(rnorm(600), 50); ",
        "y <- matrix(rnorm(100), 50); ",
        "for (family in c('simpls', 'plssvd')) { ",
        "model <- pls_irlba(x, y, ncomp=1:2, method=family); ",
        "prediction <- predict(model, x); ",
        "stopifnot(length(prediction) == 2L) }; ",
        "stopifnot(!'fastPLS' %in% loadedNamespaces())"
    )
    output <- system2(file.path(R.home("bin"), "Rscript"),
        c("--vanilla", "-e", shQuote(expression)), stdout = TRUE, stderr = TRUE)
    status <- attr(output, "status")
    expect_true(is.null(status) || status == 0L, info = paste(output, collapse = "\n"))
})
