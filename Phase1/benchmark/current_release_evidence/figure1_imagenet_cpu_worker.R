args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 4L) {
    stop(paste(
        "Usage: figure1_imagenet_cpu_worker.R TASK_RDS METHOD",
        "CLASSIFIER OUTPUT_CSV"
    ))
}

task_path <- normalizePath(args[[1L]], mustWork = TRUE)
method <- match.arg(args[[2L]], c("simpls", "plssvd"))
classifier <- match.arg(args[[3L]], c("argmax", "lda"))
output_path <- args[[4L]]

library(fastPLS, lib.loc = Sys.getenv("FASTPLS_BENCH_LIBRARY"))
if (as.character(packageVersion("fastPLS")) != "0.99.65") {
    stop("The Figure 1 ImageNet worker requires fastPLS 0.99.65")
}
if (!identical(fastPLS_blas(), "OpenBLAS")) {
    stop("The Figure 1 ImageNet worker requires the OpenBLAS-linked build")
}

options(backend = "cpu", n.cores = 1L)
task <- readRDS(task_path)
Xtrain <- readRDS(task$Xtrain_rds)
Xtest <- readRDS(task$Xtest_rds)
if (!inherits(Xtrain, "float32") || !inherits(Xtest, "float32")) {
    stop("ImageNet predictors must use float32 storage")
}
if (!identical(dim(Xtrain), c(task$n_train, task$p)) ||
        !identical(dim(Xtest), c(task$n_test, task$p))) {
    stop("ImageNet predictor dimensions do not match the task descriptor")
}

started <- proc.time()[["elapsed"]]
fit <- pls(
    Xtrain,
    task$Ytrain,
    ncomp = 1000L,
    scaling = "centering",
    method = method,
    classifier = classifier,
    fit = FALSE,
    return_variance = FALSE,
    return_loadings = FALSE,
    proj = FALSE,
    backend = "cpu",
    n.cores = 1L,
    seed = 123L
)
fit_elapsed <- proc.time()[["elapsed"]] - started
started <- proc.time()[["elapsed"]]
prediction <- predict(fit, Xtest, backend = "cpu", n.cores = 1L)
prediction_elapsed <- proc.time()[["elapsed"]] - started

component_names <- names(prediction$Ypred)
if (!length(component_names)) {
    stop("ImageNet prediction did not return a component path")
}
component_name <- component_names[[length(component_names)]]
effective_ncomp <- as.integer(sub("^ncomp=", "", component_name))
predicted <- factor(
    prediction$Ypred[[component_name]],
    levels = levels(factor(task$Ytrain))
)
truth <- factor(task$Ytest, levels = levels(predicted))
accuracy <- mean(predicted == truth)
if (!is.finite(accuracy)) {
    stop("ImageNet accuracy is not finite")
}
if (!identical(fit$diagnostics$rsvd$backend, "cpu")) {
    stop("The requested CPU backend was not executed")
}

row <- data.frame(
    dataset = "ImageNet/DINOv2",
    display = paste(
        "fastPLS", if (method == "plssvd") "PLS-SVD" else "SIMPLS", "/",
        if (classifier == "lda") "LDA" else "argmax"
    ),
    accuracy = accuracy,
    fit_sec = fit_elapsed,
    prediction_sec = prediction_elapsed,
    time_sec = fit_elapsed + prediction_elapsed,
    peak_rss_mib = NA_real_,
    memory_lower_bound = FALSE,
    ncomp_requested = 1000L,
    ncomp = effective_ncomp,
    repetitions = 1L,
    precision = "float32",
    workstation = paste(
        "Ubuntu 22.04; Intel Core i7-13700; 32 GiB RAM;",
        "OpenBLAS 0.3.29"
    ),
    package_version = as.character(packageVersion("fastPLS")),
    method = method,
    classifier = classifier,
    solver = fit$diagnostics$solver,
    oversample = fit$diagnostics$rsvd$oversample,
    power = fit$diagnostics$rsvd$power,
    seed = fit$diagnostics$rsvd$seed,
    status = "success",
    stringsAsFactors = FALSE
)
write.csv(row, output_path, row.names = FALSE, na = "")
