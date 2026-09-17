args <- commandArgs(TRUE)
stopifnot(length(args) >= 2L, !grepl("frozen", args[[1L]], ignore.case = TRUE))
lib <- normalizePath(args[[1L]])
out <- args[[2L]]
before <- if (length(args) > 2L) readRDS(args[[3L]]) else NULL
.libPaths(c(lib, .libPaths()))
library(fastPLS)
dir.create(out, recursive = TRUE, showWarnings = FALSE)
set.seed(614)
U <- qr.Q(qr(matrix(rnorm(160L * 100L), 160L, 100L)))
V <- qr.Q(qr(matrix(rnorm(125L * 100L), 125L, 100L)))
spectra <- list(
    decay = 1 / seq_len(100L),
    slow = 1 - 0.005 * (0:99),
    tied = c(rep(1, 15L), seq(0.8, 0.01, length.out = 85L)),
    rank12 = c(1 / seq_len(12L), rep(0, 88L)),
    rank12_overrequest = c(1 / seq_len(12L), rep(0, 88L))
)
rows <- records <- list()
as_double <- function(x) if (inherits(x, "float32")) float::dbl(x) else x
for (shape in names(spectra)) {
    A <- U %*% (spectra[[shape]] * t(V))
    for (precision in c("float64", "float32")) {
        X <- if (precision == "float32") float::fl(A) else A
        Xd <- as_double(X)
        target <- if (shape == "rank12_overrequest") 15L else 6L
        exact <- svd(Xd, nu = 0L, nv = 0L)$d[seq_len(target)]
        for (seed in c(1L, 7L, 19L)) {
            for (controls in c("default", "small_sketch")) {
                key <- paste(shape, precision, seed, controls, sep = "_")
                warnings <- character()
                call <- list(x = X, ncomp = target, backend = "cpu", seed = seed)
                if (controls == "small_sketch") {
                    call$oversample <- 0L
                    call$power <- 0L
                }
                timing <- system.time(result <- tryCatch(withCallingHandlers(
                    do.call(fastsvd, call), warning = function(w) {
                        warnings <<- c(warnings, conditionMessage(w))
                        invokeRestart("muffleWarning")
                    }), error = function(e) e))[["elapsed"]]
                row <- data.frame(key, shape, precision, seed, controls,
                    elapsed = timing, status = "ok", attempts = NA_integer_,
                    requested_rank = target, returned_rank = NA_integer_,
                    deterministic_recovery = NA, triplet_residual = NA_real_,
                    singular_error = NA_real_, numerical_change = NA_real_,
                    message = paste(warnings, collapse = "; "))
                if (inherits(result, "error")) {
                    row$status <- "error"
                    row$message <- conditionMessage(result)
                    records[[key]] <- list(error = conditionMessage(result))
                } else {
                    u <- as_double(result$u)
                    v <- as_double(result$v)
                    d <- as.numeric(result$d)
                    residual <- vapply(seq_along(d), function(j) max(
                        sqrt(sum((Xd %*% v[, j] - d[j] * u[, j])^2)),
                        sqrt(sum((crossprod(Xd, u[, j]) - d[j] * v[, j])^2))
                        ) / max(d[1L], 1e-6), numeric(1))
                    audit <- result$diagnostics$rsvd_case_audit
                    row$attempts <- audit$attempts
                    row$returned_rank <- length(d)
                    row$deterministic_recovery <- audit$deterministic_fallback
                    row$triplet_residual <- max(residual)
                    row$singular_error <- max(abs(d - exact[seq_along(d)])) / exact[1L]
                    records[[key]] <- list(u = u, v = v, d = d, audit = audit)
                    old <- before[[key]]
                    if (!is.null(old$d) && identical(dim(u), dim(old$u)) &&
                        identical(dim(v), dim(old$v)) && length(d) == length(old$d)) {
                        row$numerical_change <- max(
                            abs(u - old$u), abs(v - old$v), abs(d - old$d))
                    }
                }
                rows[[key]] <- row
                write.csv(do.call(rbind, rows), file.path(out, "summary.csv"), row.names = FALSE)
                saveRDS(records, file.path(out, "records.rds"))
                cat(key, row$status, "attempts", row$attempts,
                    "residual", row$triplet_residual, "\n")
            }
        }
    }
}
