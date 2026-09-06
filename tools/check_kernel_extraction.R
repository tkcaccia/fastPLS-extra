args <- commandArgs(TRUE)
stopifnot(length(args) %in% c(2L, 3L),
    !grepl("frozen|ikpls", args[[1L]], ignore.case = TRUE))
.libPaths(c(normalizePath(args[[1L]]), .libPaths()))
suppressPackageStartupMessages(library(fastPLS))
options(backend = "cpu", cores = 1L)
set.seed(673)
x <- matrix(rnorm(40L * 13L), 40L, 13L)
xt <- matrix(rnorm(9L * 13L), 9L, 13L)
records <- list()
for (kernel in 1:3) for (gamma in c(0.2, 0.9)) for (degree in 2:3) {
    name <- paste(kernel, gamma, degree, sep = "_")
    k <- fastPLS:::kernel_matrix_cpp(x, x, kernel, gamma, degree, 0.5)
    test <- fastPLS:::kernel_matrix_cpp(xt, x, kernel, gamma, degree, 0.5)
    centered <- fastPLS:::center_kernel_train_cpp(k)
    pred <- fastPLS:::center_kernel_test_cpp(
        test, centered$col_means, centered$grand_mean)
    records[[paste0("cpu64_", name)]] <- list(k, centered, pred)
    for (backend in c("cpu", if (has_metal()) "metal")) {
        id <- fastPLS:::.float32_backend_id(backend)
        xx <- float::fl(x)
        tt <- float::fl(xt)
        k <- fastPLS:::kernel_matrix_float32_cpp(xx, xx, kernel, gamma, degree, 0.5, id)
        test <- fastPLS:::kernel_matrix_float32_cpp(tt, xx, kernel, gamma, degree, 0.5, id)
        centered <- fastPLS:::center_kernel_train_float32_cpp(
            fastPLS:::.float32_from_bits(k$K))
        pred <- fastPLS:::center_kernel_test_float32_cpp(
            fastPLS:::.float32_from_bits(test$K),
            fastPLS:::.float32_from_bits(centered$col_means), centered$grand_mean)
        records[[paste0(backend, "32_", name)]] <- list(k, centered, pred)
    }
}
if (length(args) == 3L) {
    expected <- readRDS(args[[3L]])
    stopifnot(isTRUE(all.equal(records, expected, tolerance = 1e-12)))
    cat(length(records), "kernel/centering paths match the development baseline\n")
}
dir.create(dirname(args[[2L]]), recursive = TRUE, showWarnings = FALSE)
saveRDS(records, args[[2L]])
cat(length(records), "paths recorded; float32 storage remains raw float bits\n")
