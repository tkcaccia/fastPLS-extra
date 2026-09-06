args <- commandArgs(trailingOnly = TRUE)
stopifnot(length(args) == 3L)
.libPaths(unique(c(args[[1L]], .libPaths())))
suppressPackageStartupMessages(library(fastPLS))
options(backend = "cpu", cores = 1L)
set.seed(829)
X <- matrix(rnorm(100 * 25), 100, 25)
Y <- X %*% matrix(rnorm(25 * 60), 25, 60) + matrix(rnorm(100 * 60), 100, 60)
models <- list()
for (backend in c("cpu", if (has_metal()) "metal")) {
    for (family in c("plssvd", "simpls", "opls", "kernelpls")) {
        for (solver in "rsvd") {
            key <- paste(backend, family, solver, sep = "_")
            model <- suppressWarnings(pls(X, Y, X, Y, ncomp = c(2, 4),
                method = family, backend = backend, svd.method = solver,
                fit = TRUE, return_variance = FALSE, seed = 87))
            models[[key]] <- model$metrics
        }
    }
}
expected <- readRDS(args[[2L]])
stopifnot(all(names(models) %in% names(expected)))
# The stored panel retains IRLBA rows as comparison provenance. They are not
# supported by the main API and must not be executed or relabelled as rSVD.
excluded <- setdiff(names(expected), names(models))
stopifnot(all(grepl("_irlba$", excluded) |
    (!has_metal() & grepl("^metal_", excluded))))
expected <- expected[names(models)]
stopifnot(isTRUE(all.equal(models, expected, tolerance = 1e-12)))
saveRDS(models, file.path(args[[3L]], "public_metrics.rds"))
cat(length(models), "public metric paths match saved current-code results at 1e-12\n")
cat("Stored rows outside the current backend/solver scope:", paste(excluded, collapse = ", "), "\n")

# Exercise a true randomized sketch, not only the small full-width route.
set.seed(928)
U <- qr.Q(qr(matrix(rnorm(150 * 60), 150, 60)))
V <- qr.Q(qr(matrix(rnorm(90 * 60), 90, 60)))
A <- sweep(U, 2L, exp(-seq_len(60) / 3), "*") %*% t(V)
for (seed in c(11L, 22L, 33L)) {
    ans <- suppressWarnings(fastsvd(A, nu = 5, nv = 5, method = "rsvd",
        backend = "cpu", seed = seed))
    expected_values <- exp(-seq_len(5) / 3)
    stopifnot(max(abs(ans$d - expected_values)) < 1e-7)
}
cat("Three randomized-sketch spectra agree with known singular values at 1e-7\n")
