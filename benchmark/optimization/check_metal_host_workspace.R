#!/usr/bin/env Rscript
# Compare two current-code candidates; never load the frozen package.
args <- commandArgs(trailingOnly = TRUE)
stopifnot(length(args) >= 2L)
library_path <- normalizePath(args[[1L]], mustWork = TRUE)
if (grepl("frozen", library_path, ignore.case = TRUE)) stop("Current candidates only")
.libPaths(unique(c(library_path, .libPaths())))
suppressPackageStartupMessages(library(fastPLS))
stopifnot(normalizePath(find.package("fastPLS")) == file.path(library_path, "fastPLS"),
          has_metal())
out <- args[[2L]]
dir.create(out, recursive = TRUE, showWarnings = FALSE)
set.seed(711)
results <- list()
timings <- list()
model_timings <- list()
matrix_product <- function(A, B, precision, transpose_left = FALSE) {
    if (precision == "float32") {
        bits <- fastPLS:::metal_float32_matrix_multiply_cpp(
            A, B, transpose_left = transpose_left
        )
        return(fastPLS:::.float32_from_bits(bits$C))
    }
    if (transpose_left) fastPLS:::metal_crossprod_cpp(A, B) else
        fastPLS:::metal_matrix_multiply_cpp(A, B)
}
shapes <- list(small = c(64, 32, 16), medium = c(512, 128, 32),
               tall = c(2048, 256, 32))
for (shape in names(shapes)) {
    dims <- shapes[[shape]]
    X <- matrix(rnorm(dims[1] * dims[2]), dims[1], dims[2])
    Y <- matrix(rnorm(dims[2] * dims[3]), dims[2], dims[3])
    for (precision in c("float64", "float32")) {
        A <- if (precision == "float32") float::fl(X) else X
        B <- if (precision == "float32") float::fl(Y) else Y
        key <- paste(shape, precision, sep = "/")
        results[[key]] <- matrix_product(A, B, precision)
        iterations <- if (shape == "small") 100L else 25L
        for (replicate in 1:10) {
            start <- proc.time()[["elapsed"]]
            for (iteration in seq_len(iterations)) value <- matrix_product(A, B, precision)
            timings[[length(timings) + 1L]] <- data.frame(
                case = key, replicate = replicate, iterations = iterations,
                seconds_per_product = (proc.time()[["elapsed"]] - start) / iterations)
        }
        stopifnot(isTRUE(all.equal(value, results[[key]], tolerance = 0)))
    }
}
set.seed(712)
X <- matrix(rnorm(120 * 18), 120, 18)
Y <- cbind(X[, 1] + X[, 2], X[, 3] - X[, 4], X[, 5])
y <- factor(rep(c("a", "b", "c"), 40))
for (precision in c("float64", "float32")) {
    x <- if (precision == "float32") float::fl(X) else X
    response <- if (precision == "float32") float::fl(Y) else Y
    for (family in c("plssvd", "simpls", "opls", "kernelpls")) {
        kernels <- if (family == "kernelpls") c("linear", "rbf", "poly") else "linear"
        for (kernel in kernels) {
            for (head in c("regression", "argmax", "lda")) {
                key <- paste(precision, family, kernel, head, sep = "/")
                target <- if (head == "regression") response[1:90, , drop = FALSE] else y[1:90]
                for (replicate in 1:3) {
                    start <- proc.time()[["elapsed"]]
                    fit <- suppressWarnings(pls(x[1:90, ], target,
                        x[91:120, ], ncomp = 1:3, method = family, kernel = kernel,
                        backend = "metal", classifier = if (head == "lda") "lda" else "argmax",
                        fit = TRUE, seed = 39))
                    model_timings[[length(model_timings) + 1L]] <- data.frame(
                        case = key, replicate = replicate,
                        total_seconds = proc.time()[["elapsed"]] - start)
                }
                fields <- intersect(c("Ypred", "Yfit", "R", "Ttrain", "P", "B", "R2Y"), names(fit))
                stopifnot(!is.null(fit$Ypred))
                results[[key]] <- list(outputs = fit[fields], random_state = .Random.seed)
            }
        }
    }
}
write.csv(do.call(rbind, timings), file.path(out, "product_timings.csv"), row.names = FALSE)
write.csv(do.call(rbind, model_timings), file.path(out, "model_timings.csv"), row.names = FALSE)
saveRDS(results, file.path(out, "results.rds"))
if (length(args) > 2L) {
    reference <- readRDS(file.path(args[[3L]], "results.rds"))
    stopifnot(identical(names(results), names(reference)))
    for (key in names(results)) {
        delta <- all.equal(results[[key]], reference[[key]], tolerance = 0)
        if (!isTRUE(delta)) stop(key, ": ", paste(delta, collapse = "; "))
    }
}
cat("Verified", length(results), "Metal products/models; two current-code libraries only\n")
