# Run in the isolated CUDA build directory after compiling resident_package_kernels.o.
library(fastPLS)
Sys.setenv(PKG_CPPFLAGS = "-DFASTPLS_HAS_CUDA", PKG_LIBS = paste(
    normalizePath("resident_package_kernels.o"),
    "-L/usr/local/cuda-13.0/lib64 -Wl,-rpath,/usr/local/cuda-13.0/lib64",
    "-lcudart -lcublas -lcusolver -lcurand"))
api <- new.env(parent = asNamespace("fastPLS"))
Rcpp::sourceCpp("cuda_resident_r.cpp", env = api)
sys.source("main.R", envir = api)
sys.source("backend.R", envir = api)
sys.source("resident_cuda.R", envir = api)
set.seed(23)
X <- matrix(rnorm(64 * 7), 64, 7)
Y <- matrix(rnorm(64 * 3), 64, 3)
labels <- factor(rep(c("a", "b", "c"), length.out = 64))
Xtest <- matrix(rnorm(11 * 7), 11, 7)
for (method in c("simpls", "plssvd")) for (precision in c("double", "float32")) {
    for (task in c("regression", "argmax", "lda")) {
        floating <- precision == "float32"
        x <- if (floating) float::fl(X) else X
        xt <- if (floating) float::fl(Xtest) else Xtest
        y <- if (task != "regression") labels else if (floating) float::fl(Y) else Y
        yt <- if (task != "regression") labels[1:11] else if (floating) float::fl(Y[1:11, ]) else Y[1:11, ]
        model <- api$pls(x, y, xt, yt, ncomp = 1:2, backend = "cuda",
            method = method, classifier = if (task == "lda") "lda" else "argmax",
            fit = TRUE, proj = TRUE, return_loadings = TRUE, return_variance = TRUE,
            scaling = "autoscaling", seed = 17, oversample = 10, power = 2)
        internal <- api$.fastpls_restore_internal_output_fields(model)
        stopifnot(!is.null(internal$resident_state),
            all(is.finite(model$Q2Y)), all(is.finite(model$R2Y)),
            identical(dim(model$P), c(7L, 2L)), identical(dim(model$Ttest), c(11L, 2L)),
            identical(model$diagnostics$residency$decomposition, "cuda"),
            !"resident_state" %in% names(model))
        predicted <- api$predict.fastPLS(model, xt, yt, proj = TRUE)
        stopifnot(isTRUE(all.equal(model$Ypred, predicted$Ypred)),
            isTRUE(all.equal(model$Q2Y, predicted$Q2Y)))
        if (task != "regression") {
            stopifnot(all(model$accuracy >= 0 & model$accuracy <= 1))
            ranked <- api$predict.fastPLS(model, xt, yt, top = 3)
            stopifnot(all(ranked$top_k_accuracy == 1))
        }
        if (floating) stopifnot(inherits(model$R, "float32"), inherits(model$P, "float32"))
        wrong_backend <- tryCatch(api$predict.fastPLS(model, xt, backend = "cpu"), error = conditionMessage)
        stopifnot(is.character(wrong_backend), grepl("No CPU fallback", wrong_backend))
        cat("public source integration", method, precision, task, "PASS\n")
    }
}
