#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 4L) {
    stop("Usage: worker.R WORKLOAD CORES REPLICATE OUTPUT_CSV", call. = FALSE)
}

workload <- args[[1L]]
cores <- as.integer(args[[2L]])
replicate_id <- as.integer(args[[3L]])
output_csv <- args[[4L]]

benchmark_library <- Sys.getenv("FASTPLS_MULTICORE_LIB", unset = "")
if (nzchar(benchmark_library)) {
    .libPaths(unique(c(benchmark_library, .libPaths())))
}
suppressPackageStartupMessages(library(fastPLS))

if (!identical(as.character(packageVersion("fastPLS")), "0.99.39")) {
    stop("The multicore benchmark requires fastPLS 0.99.39.", call. = FALSE)
}

options(backend = "cpu", cores = cores)

# A probe of an unrelated OpenBLAS installation cannot establish that fastPLS
# itself uses that library. Verify the candidate shared object's dependencies.
package_dll <- getLoadedDLLs()[["fastPLS"]][["path"]]
dependency_command <- if (identical(Sys.info()[["sysname"]], "Darwin")) {
    "otool"
} else {
    "ldd"
}
dependency_arguments <- if (identical(dependency_command, "otool")) {
    c("-L", shQuote(package_dll))
} else {
    shQuote(package_dll)
}
dependencies <- system2(dependency_command, dependency_arguments, stdout = TRUE)
if (!any(grepl("openblas", dependencies, ignore.case = TRUE))) {
    stop("The fastPLS shared library is not linked to OpenBLAS.", call. = FALSE)
}

probe <- Sys.getenv("FASTPLS_OPENBLAS_PROBE", unset = "")
if (!nzchar(probe) || !file.exists(probe)) {
    stop("The direct OpenBLAS thread probe is unavailable.", call. = FALSE)
}
dyn.load(probe)
active_threads <- .Call("fastpls_openblas_threads")
if (!identical(as.integer(active_threads), cores)) {
    stop(
        "Requested ", cores, " OpenBLAS threads but observed ",
        active_threads, ".", call. = FALSE
    )
}

make_task <- function(name) {
    set.seed(31001L)
    if (identical(name, "sample-rich classification")) {
        n_train <- 12000L
        n_test <- 3000L
        p <- 768L
        classes <- 50L
        latent <- 20L
        X <- matrix(rnorm((n_train + n_test) * p), ncol = p)
        U <- matrix(rnorm(p * latent), p, latent) / sqrt(p)
        W <- matrix(rnorm(latent * classes), latent, classes) / sqrt(latent)
        score <- X %*% U %*% W
        score <- score + matrix(rnorm(length(score), sd = 0.8), ncol = classes)
        y <- max.col(score, ties.method = "first")
        y[seq_len(classes)] <- seq_len(classes)
        return(list(
            Xtrain = X[seq_len(n_train), , drop = FALSE],
            Ytrain = factor(y[seq_len(n_train)], levels = seq_len(classes)),
            Xtest = X[n_train + seq_len(n_test), , drop = FALSE],
            Ytest = factor(y[n_train + seq_len(n_test)], levels = seq_len(classes)),
            ncomp = 40L,
            task = "classification"
        ))
    }
    if (identical(name, "predictor-wide regression")) {
        n_train <- 1200L
        n_test <- 300L
        p <- 6000L
        q <- 20L
        latent <- 15L
    } else if (identical(name, "response-wide regression")) {
        n_train <- 1200L
        n_test <- 300L
        p <- 600L
        q <- 6000L
        latent <- 15L
    } else {
        stop("Unknown workload: ", name, call. = FALSE)
    }
    X <- matrix(rnorm((n_train + n_test) * p), ncol = p)
    U <- matrix(rnorm(p * latent), p, latent) / sqrt(p)
    V <- matrix(rnorm(latent * q), latent, q) / sqrt(latent)
    Y <- X %*% U %*% V
    Y <- Y + matrix(rnorm(length(Y), sd = 0.5), ncol = q)
    list(
        Xtrain = X[seq_len(n_train), , drop = FALSE],
        Ytrain = Y[seq_len(n_train), , drop = FALSE],
        Xtest = X[n_train + seq_len(n_test), , drop = FALSE],
        Ytest = Y[n_train + seq_len(n_test), , drop = FALSE],
        ncomp = 30L,
        task = "regression"
    )
}

task <- make_task(workload)
gc()
elapsed <- system.time({
    fit <- fastPLS::pls(
        task$Xtrain,
        task$Ytrain,
        task$Xtest,
        task$Ytest,
        ncomp = task$ncomp,
        method = "simpls",
        backend = "cpu",
        svd.method = "rsvd",
        oversample = 32L,
        power = 5L,
        classifier = "argmax",
        fit = FALSE,
        proj = FALSE,
        return_variance = FALSE,
        seed = 8127L
    )
})[["elapsed"]]

if (identical(task$task, "classification")) {
    predicted <- fit$Ypred[[length(fit$Ypred)]]
    metric_name <- "accuracy"
    metric_value <- mean(as.character(predicted) == as.character(task$Ytest))
    prediction_signature <- paste(as.character(predicted), collapse = "|")
} else {
    if (length(dim(fit$Ypred)) == 3L) {
        predicted <- fit$Ypred[, , dim(fit$Ypred)[3L], drop = TRUE]
    } else {
        predicted <- as.matrix(fit$Ypred)
    }
    metric_name <- "RMSD"
    metric_value <- sqrt(mean((as.matrix(predicted) - task$Ytest)^2))
    prediction_signature <- paste(
        format(signif(as.numeric(predicted)[seq_len(min(100L, length(predicted)))], 12L)),
        collapse = "|"
    )
}

result <- data.frame(
    package_version = as.character(packageVersion("fastPLS")),
    workload = workload,
    task = task$task,
    method = "SIMPLS",
    svd_method = "rSVD",
    precision = "float64",
    requested_cores = cores,
    active_openblas_threads = as.integer(active_threads),
    replicate = replicate_id,
    n_train = nrow(task$Xtrain),
    n_test = nrow(task$Xtest),
    p = ncol(task$Xtrain),
    q = if (is.factor(task$Ytrain)) nlevels(task$Ytrain) else ncol(task$Ytrain),
    ncomp = task$ncomp,
    rsvd_oversample = 32L,
    rsvd_power = 5L,
    seed = 8127L,
    elapsed_sec = elapsed,
    metric_name = metric_name,
    metric_value = metric_value,
    prediction_signature = prediction_signature,
    stringsAsFactors = FALSE
)

dir.create(dirname(output_csv), recursive = TRUE, showWarnings = FALSE)
write.table(
    result,
    output_csv,
    sep = ",",
    row.names = FALSE,
    col.names = !file.exists(output_csv),
    append = file.exists(output_csv),
    qmethod = "double"
)
