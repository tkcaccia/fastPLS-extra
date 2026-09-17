args <- commandArgs(TRUE)
stopifnot(length(args) >= 3L)
lib <- normalizePath(args[[1L]])
source <- normalizePath(args[[2L]])
out <- args[[3L]]
backend <- if (length(args) >= 4L) args[[4L]] else "cpu"
stopifnot(!grepl("frozen", lib, ignore.case = TRUE))
.libPaths(c(lib, .libPaths()))
library(fastPLS)
if (backend == "metal") stopifnot(has_metal())
if (backend == "cuda") stopifnot(has_cuda())
# sourceCpp loads the RcppArmadillo DLL, unlike the ordinary fastPLS API.
# Refuse a known mixed-runtime setup before OpenMP aborts the R process.
if (identical(Sys.info()[["sysname"]], "Darwin")) {
    linked_libraries <- function(path) {
        lines <- system2("otool", c("-L", shQuote(path)), stdout = TRUE)
        paths <- sub(" [(].*$", "", trimws(lines[-1L]))
        paths[startsWith(paths, "/")]
    }
    pkg_dll <- system.file("libs/fastPLS.so", package = "fastPLS")
    armadillo_dll <- system.file("libs/RcppArmadillo.so", package = "RcppArmadillo")
    direct <- linked_libraries(pkg_dll)
    blas <- direct[grepl("openblas", direct, ignore.case = TRUE)]
    runtime <- unlist(lapply(blas, linked_libraries), use.names = FALSE)
    runtime <- runtime[grepl("libomp[.]dylib$", runtime)]
    cpp_runtime <- linked_libraries(armadillo_dll)
    cpp_runtime <- cpp_runtime[grepl("libomp[.]dylib$", cpp_runtime)]
    if (length(runtime) && length(cpp_runtime) &&
        !setequal(normalizePath(runtime), normalizePath(cpp_runtime))) {
        stop("This sourceCpp probe would load different OpenMP runtimes. ",
            "Use the Accelerate validation library or a consistent BLAS/R toolchain; ",
            "do not set KMP_DUPLICATE_LIB_OK.")
    }
}
dir.create(out, recursive = TRUE, showWarnings = FALSE)
Sys.setenv(PKG_CPPFLAGS = paste("-DARMA_64BIT_WORD=1",
        paste0("-I", shQuote(file.path(source, "src"))),
        paste0("-I", shQuote(file.path(source, "inst/include")))),
    PKG_LIBS = shQuote(system.file("libs", paste0("fastPLS", .Platform$dynlib.ext),
        package = "fastPLS")))
Rcpp::sourceCpp(file.path(source, "benchmark/optimization/probe_float_crosscov.cpp"))
set.seed(625)
products <- list()
for (n in c(17L, 81L)) for (width in c(1L, 3L, 11L)) {
    p <- 43L
    q <- 37L
    X <- matrix(rnorm(n * p), n, p)
    Y <- matrix(rnorm(n * q), n, q)
    directions <- matrix(rnorm(p * 5L), p, 5L)
    directions <- sweep(directions, 2L, sqrt(colSums(directions^2)), "/")
    B <- matrix(rnorm(q * width), q, width)
    C <- matrix(rnorm(p * width), p, width)
    result <- probe_float_crosscov(X, Y, directions, B, C,
        match(backend, c("cpu", "cuda", "metal")) - 1L)
    errors <- unlist(lapply(result$products, function(x) {
        unlist(x[c("forward_error", "reverse_error")])
    }))
    stopifnot(all(is.finite(errors)), max(errors) < 2e-5,
        result$reconstruction_error < 2e-5, result$zero_width,
        result$rejects_shape, result$rejects_capacity, result$scalar_bytes == 4,
        result$index_bytes == 8)
    products[[length(products) + 1L]] <- data.frame(backend, n, width,
        max_product_error = max(errors),
        reconstruction_error = result$reconstruction_error)
}
write.csv(do.call(rbind, products), file.path(out, "products.csv"), row.names = FALSE)
cat("All chained products, sequential deflations, fallback decompositions and guards passed\n")
