args <- commandArgs(TRUE)
stopifnot(length(args) >= 3L, !grepl("frozen", args[[1L]], ignore.case = TRUE))
.libPaths(c(args[[1L]], .libPaths()))
library(fastPLS)
out <- args[[2L]]
backend <- args[[3L]]
before <- if (length(args) > 3L) args[[4L]] else ""
dir.create(out, recursive = TRUE, showWarnings = FALSE)
set.seed(936)
n <- 200L
ntest <- 3000L
p <- 400L
X <- float::fl(matrix(rnorm((n + ntest) * p), n + ntest, p))
Y <- X[, 1:20] + float::fl(matrix(rnorm((n + ntest) * 20L, sd = 0.1), n + ntest, 20L))
rows <- list()
for (family in c("simpls", "plssvd", "opls", "kernelpls")) {
    key <- paste(backend, family, sep = "_")
    model <- suppressWarnings(pls(X[seq_len(n), ], Y[seq_len(n), ],
        method = family, ncomp = 1:10, backend = backend, seed = 56,
        return_variance = FALSE))
    test <- X[n + seq_len(ntest), ]
    invisible(predict(model, test))
    elapsed <- replicate(20L, {
        gc(FALSE)
        unname(system.time(prediction <- predict(model, test))[["elapsed"]])
    })
    # The retained output is from a separate untimed call, not a timing replicate.
    prediction <- lapply(predict(model, test)$Ypred, float::dbl)
    difference <- NA_real_
    if (nzchar(before)) {
        old <- readRDS(file.path(before, paste0(key, ".rds")))
        stopifnot(length(old) == length(prediction), length(prediction) == 10L)
        difference <- max(vapply(seq_along(old), function(i) {
            sqrt(sum((prediction[[i]] - old[[i]])^2) /
                max(sum(old[[i]]^2), .Machine$double.eps))
        }, numeric(1)))
        stopifnot(is.finite(difference), difference < 1e-5)
    } else {
        saveRDS(prediction, file.path(out, paste0(key, ".rds")))
    }
    rows[[length(rows) + 1L]] <- data.frame(
        backend, family, ntrain = n, ntest, p, q = 20L, requested_prefixes = 10L,
        repetitions = length(elapsed), median_prediction_sec = median(elapsed),
        iqr_prediction_sec = IQR(elapsed), relative_prediction_change = difference,
        status = "success")
    write.csv(data.frame(replicate = seq_along(elapsed), prediction_sec = elapsed),
        file.path(out, paste0(key, "_timing.csv")), row.names = FALSE)
    write.csv(do.call(rbind, rows), file.path(out, "summary.csv"), row.names = FALSE)
}
print(do.call(rbind, rows))
