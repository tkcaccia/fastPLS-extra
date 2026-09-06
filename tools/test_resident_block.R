Sys.setenv(PKG_CPPFLAGS = "-DFASTPLS_HAS_CUDA", PKG_LIBS = paste(
    normalizePath("resident_package_kernels.o"),
    "-L/usr/local/cuda-13.0/lib64 -Wl,-rpath,/usr/local/cuda-13.0/lib64",
    "-lcudart -lcublas -lcusolver -lcurand"))
Rcpp::sourceCpp("cuda_resident_r.cpp")
set.seed(41)
n <- 8192L; p <- 1024L; classes <- 64L; components <- 8L
labels <- rep(seq_len(classes), length.out = n)
X <- matrix(rnorm(n * p), n, p)
for (precision in c(32L, 64L)) {
    input <- if (precision == 32L) matrix(readBin(writeBin(as.double(X), raw(), size = 4),
        integer(), n = length(X), size = 4), n, p) else X
    elapsed <- system.time(model <- cuda_resident_simpls_fit_cpp(input, NULL,
        labels, classes, precision, components, 2L, 2L, 1L, 41L, 3L))[["elapsed"]]
    stopifnot(model$refresh_block == 8L, model$effective_oversample == 2L,
        model$effective_power == 1L)
    predicted <- cuda_resident_classify_cpp(model, input[seq_len(32L), , drop = FALSE],
        components, 0L, 1L)
    stopifnot(all(predicted >= 1L & predicted <= classes))
    cat("resident block refresh", precision, "elapsed", elapsed, "PASS\n")
    rm(model, input); gc()
}
