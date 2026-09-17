args <- commandArgs(trailingOnly = TRUE)
mode <- if (length(args) >= 1L) args[[1L]] else "core"
threads <- if (length(args) >= 2L) as.integer(args[[2L]]) else 1L
fixture <- if (length(args) >= 3L) {
    args[[3L]]
} else {
    "/tmp/fastpls-cifar100-task.rds"
}
library_path <- if (length(args) >= 4L) {
    args[[4L]]
} else {
    "/tmp/fastpls-mit-cv-lib"
}

stopifnot(mode %in% c(
    "legacy", "core", "core_predictions", "core_scores", "public",
    "core_float", "public_float"
), threads >= 1L)
Sys.setenv(
    OPENBLAS_NUM_THREADS = threads,
    OMP_NUM_THREADS = threads,
    MKL_NUM_THREADS = threads
)
.libPaths(c(library_path, .libPaths()))
suppressPackageStartupMessages(library(fastPLS))

task <- readRDS(fixture)
X <- task$Xtrain
if (endsWith(mode, "_float")) {
    X <- float::fl(X)
}
labels <- as.integer(task$Ytrain)
classes <- nlevels(task$Ytrain)
components <- c(10L, 25L, 50L)
groups <- seq_len(nrow(X))
seed <- 123L

set.seed(seed)
timing <- system.time({
    if (identical(mode, "legacy")) {
        result <- fastPLS:::pls_cv_predict_compiled(
            Xdata = X,
            Ydata = matrix(as.double(labels), ncol = 1L),
            constrain = groups,
            ncomp = components,
            scaling = 3L,
            kfold = 3L,
            method = 3L,
            backend = 0L,
            svd_method = fastPLS:::.svd_method_id("cpu_rsvd"),
            rsvd_oversample = 32L,
            rsvd_power = 5L,
            svds_tol = 0,
            seed = seed,
            classification = TRUE,
            n_response = classes,
            xprod = FALSE,
            opls_north = 0L,
            return_scores = FALSE,
            class_codes = matrix(numeric(), 0L, 0L),
            classifier = 0L,
            lda_ridge = 0,
            store_predictions = FALSE,
            metric_id = 1L
        )
    } else if (startsWith(mode, "core")) {
        folds <- fastPLS:::cv_folds_core_cpp(
            groups, labels, classes, 3L
        )
        keep_predictions <- !mode %in% c("core", "core_float")
        keep_scores <- identical(mode, "core_scores")
        runner <- if (endsWith(mode, "_float")) {
            fastPLS:::pls_cv_classification_float32_core_cpp
        } else {
            fastPLS:::pls_cv_classification_core_cpp
        }
        result <- runner(
            X, labels, classes, folds, components,
            3L, 3L, 0L, 32L, 5L, seed,
            keep_predictions, keep_scores
        )
    } else {
        result <- fastPLS::pls.single.cv(
            Xdata = X,
            Ydata = task$Ytrain,
            ncomp = components,
            constrain = groups,
            scaling = "none",
            method = "simpls",
            backend = "cpu",
            svd.method = "rsvd",
            classifier = "argmax",
            kfold = 3L,
            oversample = 32L,
            power = 5L,
            seed = seed,
            fit = FALSE
        )
    }
})

metrics <- if (identical(mode, "legacy")) {
    result$metrics$metric_value
} else if (startsWith(mode, "public")) {
    result$accuracy
} else {
    result$metric_value
}
record <- data.frame(
    mode = mode,
    threads = threads,
    elapsed_seconds = unname(timing[["elapsed"]]),
    accuracy_10 = metrics[[1L]],
    accuracy_25 = metrics[[2L]],
    accuracy_50 = metrics[[3L]],
    package_path = find.package("fastPLS"),
    stringsAsFactors = FALSE
)
write.table(record, row.names = FALSE, sep = ",")
