test_that("IRLBA matches dense singular values and preserves RNG", {
    set.seed(23)
    x <- matrix(rnorm(80L * 18L), 80L, 18L)
    before <- .Random.seed
    fit <- irlba(x, 3L, seed = 7L)
    expect_identical(.Random.seed, before)
    expect_equal(as.numeric(fit$d), svd(x, nu = 0L, nv = 0L)$d[1:3], tolerance = 1e-4)
    expect_true(all(fit$convergence$status == 0L))
    expect_equal(irlba(x, 3L, seed = 7L), fit)
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
    }
})

test_that("invalid requests and nonconvergence fail explicitly", {
    x <- matrix(seq_len(30), 10L, 3L)
    expect_error(irlba(x, 4L), "dimensions")
    expect_error(irlba(x, 1.5), "integer")
    expect_error(pls_irlba(x, x[-1, ]), "matching")
    expect_error(pls_irlba(x, x, ncomp = 4L), "component bound")
    expect_error(pls_irlba(x, x, fit = NA), "fit")
    set.seed(5)
    z <- matrix(rnorm(100L * 90L), 100L, 90L)
    expect_error(irlba(z, 5L, maxit = 1L), "did not converge")
})

test_that("full working subspaces use a labelled dense decomposition", {
    set.seed(2)
    x <- matrix(rnorm(80L * 8L), 80L, 8L)
    fit <- irlba(x, 6L)
    expect_identical(fit$convergence$algorithm, "dense_full_subspace")
    expect_equal(as.numeric(fit$d), svd(x, nu = 0L, nv = 0L)$d[1:6], tolerance = 1e-12)
    model <- pls_irlba(x, x, ncomp = 2L)
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

test_that("implicit cross-products match explicit decompositions", {
    set.seed(37)
    for (shape in list(c(80L, 24L, 18L), c(12L, 40L, 30L), c(60L, 12L, 8L))) {
        x <- matrix(rnorm(shape[1L] * shape[2L]), shape[1L], shape[2L])
        y <- matrix(rnorm(shape[1L] * shape[3L]), shape[1L], shape[3L])
        before <- .Random.seed
        stored <- serialize(list(x, y), NULL)
        rank <- if (shape[3L] == 8L) 6L else 3L
        fit <- irlba_crossprod(x, y, rank, seed = 13L)
        expect_identical(.Random.seed, before)
        expect_identical(serialize(list(x, y), NULL), stored)
        product <- crossprod(x, y)
        reference <- svd(product, nu = 0L, nv = 0L)$d[seq_len(rank)]
        expect_equal(as.numeric(fit$d), reference, tolerance = 1e-5)
        expect_lt(norm(product %*% fit$v - sweep(fit$u, 2L, fit$d, "*"), "F") /
            norm(product, "F"), 1e-5)
        expect_lt(norm(crossprod(product, fit$u) - sweep(fit$v, 2L, fit$d, "*"), "F") /
            norm(product, "F"), 1e-5)
        expected <- if (shape[3L] == 8L) "factor_product_full_subspace" else
            "irlba_crossprod"
        expect_identical(fit$convergence$algorithm, expected)
    }
    expect_error(irlba_crossprod(x, y[-1L, ], 1L), "dimensions")
    expect_error(irlba_crossprod(x, y, 1L, maxit = 0L), "integer")
})
