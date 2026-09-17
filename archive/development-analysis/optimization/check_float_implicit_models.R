args <- commandArgs(TRUE)
stopifnot(length(args) >= 2L)
lib <- normalizePath(args[[1L]])
out <- args[[2L]]
backend <- if (length(args) >= 3L) args[[3L]] else "cpu"
before <- if (length(args) >= 4L) args[[4L]] else ""
stopifnot(!grepl("frozen", lib, ignore.case = TRUE))
.libPaths(c(lib, .libPaths()))
library(fastPLS)
dir.create(out, recursive = TRUE, showWarnings = FALSE)
set.seed(626)
n <- 80L
p <- 3001L
q <- 2901L
latent <- matrix(rnorm((n + 12L) * 16L), n + 12L, 16L)
X <- float::fl(latent %*% matrix(rnorm(16L * p), 16L, p) +
    matrix(rnorm((n + 12L) * p, sd = 0.02), n + 12L, p))
Y <- float::fl(latent %*% matrix(rnorm(16L * q), 16L, q) +
    matrix(rnorm((n + 12L) * q, sd = 0.02), n + 12L, q))
train <- seq_len(n)
test <- n + seq_len(12L)
rows <- list()
for (solver in if (backend == "cuda") "rsvd" else c("rsvd", "irlba")) {
    for (family in c("simpls", "plssvd", "opls")) {
        key <- paste(backend, solver, family, sep = "_")
        elapsed <- system.time(model <- suppressWarnings(pls(
            X[train, ], Y[train, ], Xtest = X[test, ], Ytest = Y[test, ],
            ncomp = c(1L, 3L, 6L), method = family, backend = backend,
            svd.method = solver, oversample = 3, power = 2, seed = 24,
            fit = TRUE, return_variance = FALSE)))[["elapsed"]]
        prediction <- lapply(model$Ypred, float::dbl)
        fitted <- lapply(model$Yfit, float::dbl)
        stopifnot(all(vapply(c(prediction, fitted), function(x) all(is.finite(x)), logical(1))))
        comparison <- NA_real_
        if (nzchar(before)) {
            old <- readRDS(file.path(before, paste0(key, ".rds")))
            comparison <- max(vapply(seq_along(prediction), function(i) {
                sqrt(sum((prediction[[i]] - old$prediction[[i]])^2) /
                    sum(old$prediction[[i]]^2))
            }, numeric(1)))
        }
        saveRDS(list(prediction = prediction, fitted = fitted, Q2Y = model$Q2Y,
            diagnostics = model$diagnostics, rng = .Random.seed),
            file.path(out, paste0(key, ".rds")))
        rows[[length(rows) + 1L]] <- data.frame(key, elapsed,
            relative_prediction_change = comparison,
            Q2Y = tail(model$Q2Y, 1L))
        write.csv(do.call(rbind, rows), file.path(out, "summary.csv"), row.names = FALSE)
        print(tail(rows, 1L))
    }
}
