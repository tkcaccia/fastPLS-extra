test_that("only the NMR benchmark modelling interface is exported", {
    removed <- c("irlba", "irlba_crossprod", "pls.single.cv", "pls.double.cv")
    expect_false(any(removed %in% getNamespaceExports("fastPLSextra")))
})

test_that("shared PLS models predict and serialize", {
    set.seed(9)
    x <- matrix(rnorm(70L * 12L), 70L, 12L)
    y <- x[, 1:5] + matrix(rnorm(350, sd = 0.1), 70L, 5L)
    for (family in c("simpls", "plssvd")) {
        fit <- pls_irlba(x, y, x, ncomp = c(1L, 3L), method = family, fit = TRUE)
        expect_named(fit$Ypred, c("ncomp=1", "ncomp=3"))
        expect_equal(fit$Ypred[[2L]], fit$Yfit[, , 2L], tolerance = 1e-10)
        expect_equal(predict(unserialize(serialize(fit, NULL)), x), fit$Ypred)
        expect_error(predict(fit, x[, -1]), "column count")
        expect_true(all(fit$convergence$status == 0L))
        expect_false("scores" %in% names(fit))
        expect_false("coefficients" %in% names(fit))
    }
})

test_that("invalid PLS requests fail explicitly", {
    x <- matrix(seq_len(30), 10L, 3L)
    expect_error(pls_irlba(x, x[-1, ]), "matching")
    expect_error(pls_irlba(x, x, ncomp = 4L), "component bound")
    expect_error(pls_irlba(x, x, fit = NA), "fit")
})

test_that("small full working subspaces use a labelled dense decomposition", {
    set.seed(2)
    x <- matrix(rnorm(80L * 8L), 80L, 8L)
    model <- pls_irlba(x, x, ncomp = 2L)
    expect_true(all(model$convergence$algorithm == "dense_full_subspace"))
    expect_false("R2Y" %in% names(model))
    expect_false("Yfit" %in% names(model))
})

test_that("full-subspace PLS-SVD predictions match an independent dense calculation", {
    set.seed(41)
    x <- matrix(rnorm(90L * 14L), 90L, 14L)
    y <- x[, 1:8] + matrix(rnorm(720L, sd = 0.2), 90L, 8L)
    heldout <- matrix(rnorm(11L * 14L), 11L, 14L)
    counts <- c(1L, 3L, 6L)
    model <- pls_irlba(x, y, heldout, ncomp = counts,
        method = "plssvd", fit = TRUE)
    expect_identical(model$convergence$algorithm, "dense_full_subspace")
    xc <- sweep(x, 2L, colMeans(x))
    yc <- sweep(y, 2L, colMeans(y))
    xt <- sweep(heldout, 2L, colMeans(x))
    directions <- svd(crossprod(xc, yc))$u
    for (index in seq_along(counts)) {
        basis <- directions[, seq_len(counts[index]), drop = FALSE]
        scores <- xc %*% basis
        weights <- qr.solve(scores, yc)
        fitted <- sweep(scores %*% weights, 2L, colMeans(y), "+")
        predicted <- sweep(xt %*% basis %*% weights, 2L, colMeans(y), "+")
        expect_equal(model$Yfit[, , index], fitted, tolerance = 1e-11)
        expect_equal(model$Ypred[[index]], predicted, tolerance = 1e-11)
    }
})

test_that("prediction reuses one maximal score projection", {
    set.seed(37)
    x <- matrix(rnorm(90L * 24L), 90L, 24L)
    y <- matrix(rnorm(90L * 18L), 90L, 18L)
    heldout <- matrix(rnorm(13L * 24L), 13L, 24L)
    for (family in c("simpls", "plssvd")) {
        fit <- pls_irlba(x, y, ncomp = c(1L, 3L, 6L), method = family)
        prediction <- predict(fit, heldout)
        standardized <- sweep(heldout, 2L, fit$mX, "-")
        standardized <- sweep(standardized, 2L, fit$vX, "/")
        for (index in seq_along(fit$ncomp)) {
            count <- fit$ncomp[[index]]
            if (family == "simpls") {
                expected <- standardized %*%
                    fit$R[, seq_len(count), drop = FALSE] %*%
                    t(fit$Q[, seq_len(count), drop = FALSE])
            } else {
                weights <- fit$weights[seq_len(count), , index, drop = FALSE]
                dim(weights) <- c(count, ncol(y))
                expected <- standardized %*%
                    fit$R[, seq_len(count), drop = FALSE] %*% weights
            }
            expected <- sweep(expected, 2L, fit$mY, "+")
            expect_equal(prediction[[index]], expected, tolerance = 1e-11)
        }
    }
})
