args <- commandArgs(TRUE)
stopifnot(length(args) == 2L, !grepl("frozen", args[[1L]], ignore.case = TRUE))
.libPaths(c(args[[1L]], .libPaths()))
library(fastPLS)
source(file.path(args[[2L]], "benchmark/nmr_component_selection_helpers.R"))
set.seed(627)
X <- matrix(rnorm(75 * 19), 75, 19)
Y <- X %*% matrix(rnorm(19 * 11), 19, 11) + matrix(rnorm(75 * 11), 75, 11)
components <- c(1L, 3L, 6L)
checks <- 0L
for (backend in c("cpu", if (has_metal()) "metal")) {
    for (family in c("plssvd", "simpls")) {
        model <- suppressWarnings(pls(X[1:60, ], Y[1:60, ], ncomp = components,
            method = family, backend = backend, seed = 31))
        predicted <- predict(model, X[61:75, ])$Ypred
        if (length(dim(predicted)) == 3L) {
            predicted <- lapply(seq_along(components), function(i) {
                matrix(predicted[, , i], nrow = 15L)
            })
        }
        stopifnot(length(predicted) == length(components))
        for (i in seq_along(components)) {
            k <- components[[i]]
            expected <- c(RMSD = sqrt(mean((Y[61:75, ] - predicted[[i]])^2)),
                MAE = mean(abs(Y[61:75, ] - predicted[[i]])),
                Q2 = 1 - sum((Y[61:75, ] - predicted[[i]])^2) /
                    sum(sweep(Y[61:75, ], 2, colMeans(Y[1:60, ]), "-")^2))
            for (width in c(1L, 4L, 20L)) {
                actual <- fastpls_nmr_score_prefix(model, X[61:75, ], Y[61:75, ], k, width)
                stopifnot(isTRUE(all.equal(actual, expected, tolerance = 2e-5)))
                prepared <- fastpls_nmr_prepare_scoring(model,
                    X[61:75, ], Y[61:75, ], width)
                reused <- fastpls_nmr_score_prepared(prepared, Y[61:75, ], k, width)
                stopifnot(identical(actual, reused))
                checks <- checks + 2L
                if (family == "plssvd") {
                    compact <- fastPLS:::.fastpls_restore_internal_output_fields(model)
                    compact$W_latent <- NULL
                    lazy <- fastpls_nmr_score_prefix(compact,
                        X[61:75, ], Y[61:75, ], k, width)
                    stopifnot(isTRUE(all.equal(lazy, expected, tolerance = 2e-5)))
                    checks <- checks + 1L
                }
            }
        }
    }
}
stopifnot(checks == if (has_metal()) 90L else 45L)
cat(checks, "blocked NMR scoring checks match public prediction\n")
