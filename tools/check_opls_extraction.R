args <- commandArgs(TRUE)
stopifnot(length(args) %in% c(2L, 3L),
    !grepl("frozen|ikpls", args[[1L]], ignore.case = TRUE))
.libPaths(c(normalizePath(args[[1L]]), .libPaths()))
suppressPackageStartupMessages(library(fastPLS))
options(backend = "cpu", cores = 1L)
cases <- list()
for (shape in c("ordinary", "wide", "dummy")) {
    set.seed(493)
    n <- if (shape == "wide") 35L else 60L
    p <- if (shape == "wide") 90L else 12L
    x <- matrix(rnorm(n * p), n, p)
    x[, 2L] <- 1
    y <- if (shape == "dummy") diag(4)[rep(1:4, length.out = n), ] else
        x[, 3:6] + matrix(rnorm(n * 4), n, 4)
    test <- matrix(rnorm(11L * p), 11L, p)
    original <- serialize(list(x, y, test), NULL)
    for (scaling in 1:3) for (north in c(0L, 1L, 3L)) {
        key <- paste(shape, scaling, north, sep = "_")
        model <- fastPLS:::opls_filter_cpp(x, y, north, scaling)
        predicted <- fastPLS:::opls_apply_filter_cpp(
            test, model$mX, model$vX, model$W_orth, model$P_orth)
        stopifnot(identical(original, serialize(list(x, y, test), NULL)))
        cases[[key]] <- list(filter = model, predicted = predicted)
    }
}
if (length(args) == 3L) {
    expected <- readRDS(args[[3L]])
    stopifnot(isTRUE(all.equal(cases, expected, tolerance = 1e-12)))
    cat(length(cases), "OPLS filter cases match current-development baseline at 1e-12\n")
}
dir.create(dirname(args[[2L]]), recursive = TRUE, showWarnings = FALSE)
saveRDS(cases, args[[2L]])
cat(length(cases), "filter and held-out transformations recorded\n")
