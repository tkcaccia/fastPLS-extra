args <- commandArgs(TRUE)
stopifnot(length(args) == 3L, !grepl("frozen", args[1L], ignore.case = TRUE))
.libPaths(c(normalizePath(args[1L]), .libPaths()))
library(fastPLS)
candidate <- new.env(parent = asNamespace("fastPLS"))
sys.source(args[2L], candidate)
dir.create(args[3L], recursive = TRUE, showWarnings = FALSE)
set.seed(305)
X <- matrix(rnorm(48L * 8L), 48L, 8L)
Y <- X[, 1:3] + matrix(rnorm(144L, sd = 0.2), 48L, 3L)
y <- factor(rep(letters[1:3], 16L))
fields <- c("Yfit", "Ypred", "R2Y", "Q2Y", "RMSD", "accuracy",
            "best_ncomp", "p.value", "Q2Ysampled")
rows <- list()
for (family in c("simpls", "plssvd", "opls", "kernelpls")) {
    for (task in c("regression", "argmax", "lda")) {
        for (api in c("pls", "pls.single.cv", "pls.double.cv")) {
            call <- list(X, if (task == "regression") Y else y,
                ncomp = 1:2, method = family, backend = "cpu", seed = 11L)
            if (task != "regression") call$classifier <- task
            if (family == "kernelpls") { call$kernel <- "rbf"; call$gamma <- 0.1 }
            if (api == "pls") {
                call$Xtest <- X[1:6, ]
                call$fit <- TRUE
            } else if (api == "pls.single.cv") {
                call$kfold <- 3L
            } else {
                call$kfold_outer <- 3L
                call$kfold_inner <- 3L
                call$perm.test <- TRUE
                call$times <- 2L
            }
            before <- do.call(get(api, asNamespace("fastPLS")), call)
            after <- do.call(candidate[[api]], call)
            keep <- intersect(fields, union(names(before), names(after)))
            extract <- function(x) setNames(lapply(keep, function(name) x[[name]]), keep)
            comparison <- all.equal(extract(before), extract(after), tolerance = 1e-12,
                                    check.attributes = FALSE)
            ok <- isTRUE(comparison)
            key <- paste(family, task, api, sep = "_")
            rows[[key]] <- data.frame(family, task, api, matched = ok,
                compared_fields = paste(keep, collapse = ";"),
                difference = if (ok) "" else paste(comparison, collapse = ";"))
            write.csv(do.call(rbind, rows), file.path(args[3L], "comparison.csv"),
                      row.names = FALSE)
            cat(key, ok, "\n")
            if (!ok) stop("Public rSVD migration regression: ", key)
        }
    }
}
cat("36 current-source API comparisons completed; compiled library unchanged\n")
