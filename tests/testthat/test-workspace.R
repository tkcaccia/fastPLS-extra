test_that("IRLBA workspace reuse preserves fresh starts and input ownership", {
    set.seed(708)
    X <- matrix(rnorm(80L * 24L), 80L, 24L)
    Y <- matrix(rnorm(80L * 18L), 80L, 18L)
    inputs <- serialize(list(X, Y), NULL)
    for (method in c("simpls", "plssvd")) {
        fit_once <- function(x, y) {
            set.seed(92)
            before <- .Random.seed
            fit <- pls_irlba(x, y, ncomp = 1:5, method = method,
                             seed = 92L, fit = TRUE)
            expect_identical(.Random.seed, before)
            fit
        }
        first <- fit_once(X, Y)
        expect_true("irlba" %in% first$convergence$algorithm)
        fit_once(X[, 1:12], Y[, 1:6])
        expect_equal(fit_once(X, Y), first, tolerance = 0)
        expect_identical(serialize(list(X, Y), NULL), inputs)
        expect_true(all(is.finite(first$R)))
    }
})
