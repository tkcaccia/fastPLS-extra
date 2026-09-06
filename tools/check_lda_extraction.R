args <- commandArgs(TRUE)
stopifnot(length(args) %in% c(2L, 3L),
    !grepl("frozen|ikpls", args[[1L]], ignore.case = TRUE))
.libPaths(c(normalizePath(args[[1L]]), .libPaths()))
suppressPackageStartupMessages(library(fastPLS))
options(backend = "cpu", cores = 1L)
set.seed(697)
x <- matrix(rnorm(60 * 7), 60, 7)
y <- rep(1:3, each = 20)
records <- list()
for (condition in c("ordinary", "collinear", "constant")) {
    scores <- x
    if (condition == "collinear") scores[, 7] <- scores[, 1]
    if (condition == "constant") scores[, ] <- 0
    for (precision in c("double", "float")) {
        models <- if (precision == "double") {
            fastPLS:::lda_train_prefix_cpp(scores, y, 3L, c(1L, 3L, 7L), 0)
        } else {
            fastPLS:::lda_train_prefix_float32_cpp(
                float::fl(scores), y, 3L, c(1L, 3L, 7L))
        }
        predicted <- lapply(seq_along(models), function(index) {
            model <- models[[index]]
            test <- scores[, seq_len(c(1L, 3L, 7L)[index]), drop = FALSE]
            if (precision == "double") {
                fastPLS:::lda_predict_cpp(test, model)
            } else {
                fastPLS:::lda_predict_float32_cpp(float::fl(test), model)
            }
        })
        records[[paste(condition, precision)]] <- list(models, predicted)
    }
}
if (length(args) == 3L) {
    stopifnot(identical(records, readRDS(args[[3L]])))
    cat("All LDA coefficients, regularization diagnostics and predictions are identical\n")
}
dir.create(dirname(args[[2L]]), recursive = TRUE, showWarnings = FALSE)
saveRDS(records, args[[2L]])
cat(length(records), "precision/condition paths, three prefixes each, recorded\n")
