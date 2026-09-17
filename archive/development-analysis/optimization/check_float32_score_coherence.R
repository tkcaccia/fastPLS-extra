args <- commandArgs(TRUE)
stopifnot(length(args) == 3L)
.libPaths(c(args[[1L]], .libPaths()))
library(fastPLS)
backend <- args[[3L]]
if (backend == "cuda" && !has_cuda()) stop("CUDA is unavailable")
if (backend == "metal" && !has_metal()) stop("Metal is unavailable")
rows <- list()
for (condition in c("well_conditioned", "ill_conditioned")) {
    set.seed(628)
    n <- 120L
    latent <- sweep(matrix(rnorm(n * 20L), n, 20L), 2L,
        if (condition == "ill_conditioned")
            10^seq(0, -3, length.out = 20L) else rep(1, 20L), "*")
    X <- float::fl(latent %*% matrix(rnorm(20L * 180L), 20L, 180L) +
        matrix(rnorm(n * 180L, sd = 1e-4), n, 180L))
    Y <- float::fl(latent %*% matrix(rnorm(20L * 110L), 20L, 110L) +
        matrix(rnorm(n * 110L, sd = 1e-4), n, 110L))
    solvers <- if (backend == "cuda") "rsvd" else c("rsvd", "irlba")
    for (solver in solvers) {
        model <- suppressWarnings(pls(X, Y, ncomp = c(10L, 20L, 30L),
            svd.method = solver, backend = backend, seed = 29,
            fit = TRUE, return_variance = FALSE))
        internal <- fastPLS:::.fastpls_restore_internal_output_fields(model)
        scores <- float::dbl(internal$Ttrain)
        scaled <- fastPLS:::.float32_sweep_cols(X, internal$mX, "-")
        scaled <- fastPLS:::.float32_sweep_cols(scaled, internal$vX, "/")
        projected <- float::dbl(scaled %*% internal$R)
        predicted <- predict(model, X)$Ypred
        relative <- function(a, b) {
            sqrt(sum((a - b)^2) / max(sum(b^2), .Machine$double.eps))
        }
        for (i in seq_along(predicted)) {
            a <- c(10L, 20L, 30L)[i]
            keep <- seq_len(a)
            fitted <- float::dbl(model$Yfit[[i]])
            prediction <- float::dbl(predicted[[i]])
            rows[[length(rows) + 1L]] <- data.frame(
                backend = backend, condition = condition, solver = solver,
                ncomp = a,
                stored_orthogonality = max(abs(crossprod(scores[, keep]) - diag(a))),
                projected_orthogonality = max(abs(crossprod(projected[, keep]) - diag(a))),
                score_relative_error = relative(projected[, keep], scores[, keep]),
                prediction_fit_relative_error = relative(prediction, fitted),
                finite = all(is.finite(c(prediction, fitted, scores, projected))))
        }
    }
}
result <- do.call(rbind, rows)
write.csv(result, args[[2L]], row.names = FALSE)
print(result)
stopifnot(nrow(result) == if (backend == "cuda") 6L else 12L,
    all(result$finite))
