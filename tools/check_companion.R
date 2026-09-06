# GPL-3. Execute only the current companion; reference results are read-only.
args <- commandArgs(TRUE)
stopifnot(length(args) == 3L,
    !grepl("frozen|ikpls", args[[1L]], ignore.case = TRUE))
.libPaths(c(normalizePath(args[[1L]]), .libPaths()))
library(fastPLSextra)
reference <- readRDS(args[[2L]])
stopifnot(length(reference) == 96L)
dir.create(args[[3L]], recursive = TRUE, showWarnings = FALSE)
rows <- records <- list()
for (shape in c("ordinary", "wide", "response_wide", "dummy")) {
    set.seed(972)
    p <- if (shape == "wide") 140L else 30L
    q <- if (shape == "response_wide") 240L else 18L
    X <- matrix(rnorm(110L * p), 110L, p) + 2
    Y <- if (shape == "dummy") diag(q)[rep(1:q, length.out = 110L), ] else
        X %*% matrix(rnorm(p * q), p, q) + matrix(rnorm(110L * q), 110L, q)
    Xt <- matrix(rnorm(13L * p), 13L, p) + 2
    original <- serialize(list(X, Y, Xt), NULL)
    for (family in c("simpls", "plssvd")) for (scaling in 1:3) {
        for (fitted in c(FALSE, TRUE)) for (seed in c(17L, 29L)) {
            key <- paste(shape, family, scaling, fitted, seed, sep = "_")
            set.seed(seed)
            saved <- reference[[key]]
            stopifnot(!is.null(saved$previous),
                !is.null(saved$previous_prediction))
            old <- saved$previous
            old_prediction <- saved$previous_prediction
            previous_seed <- .Random.seed
            new <- pls_irlba(X, Y, Xt, ncomp = c(1L, 3L, 6L), method = family,
                scaling = c("center", "autoscale", "none")[[scaling]],
                fit = fitted, seed = seed)
            stopifnot(identical(previous_seed, .Random.seed),
                identical(original, serialize(list(X, Y, Xt), NULL)))
            values <- c("R", "Q", "mX", "vX", "mY",
                if (fitted) c("Yfit", "R2Y"))
            aligned <- new
            signs <- sign(colSums(new$R * old$R))
            signs[signs == 0] <- 1
            aligned$R <- sweep(new$R, 2L, signs, "*")
            aligned$Q <- sweep(new$Q, 2L, signs, "*")
            difference <- max(vapply(values, function(name) {
                stopifnot(identical(dim(new[[name]]), dim(old[[name]])))
                if (!length(new[[name]])) 0 else max(abs(aligned[[name]] - old[[name]]))
            }, numeric(1)))
            predicted <- max(vapply(seq_len(3L), function(j) {
                max(abs(new$Ypred[[j]] - old_prediction[, , j]))
            }, numeric(1)))
            rows[[key]] <- data.frame(key, maximum_sign_aligned_model_difference = difference,
                maximum_prediction_difference = predicted,
                converged = all(new$convergence$status == 0L))
            records[[key]] <- list(previous = old, candidate = new,
                previous_prediction = old_prediction)
            write.csv(do.call(rbind, rows), file.path(args[[3L]], "comparison.csv"), row.names = FALSE)
            saveRDS(records, file.path(args[[3L]], "records.rds"))
            stopifnot(difference <= 1e-9, predicted <= 1e-9, all(new$convergence$status == 0L))
        }
    }
    cat(shape, "completed\n")
}
