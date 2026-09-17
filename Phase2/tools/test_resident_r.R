Sys.setenv(
    PKG_CPPFLAGS = "-DFASTPLS_HAS_CUDA",
    PKG_LIBS = paste(
        normalizePath("resident_package_kernels.o"),
        "-L/usr/local/cuda-13.0/lib64 -Wl,-rpath,/usr/local/cuda-13.0/lib64",
        "-lcudart -lcublas -lcusolver -lcurand"
    )
)
Rcpp::sourceCpp("cuda_resident_r.cpp")
set.seed(19)
X <- matrix(rnorm(64 * 7), 64, 7)
Y <- matrix(rnorm(64 * 3), 64, 3)
Xtest <- matrix(rnorm(11 * 7), 11, 7)
labels <- rep(1:3, length.out = 64)
bits <- function(x) matrix(readBin(writeBin(as.double(x), raw(), size = 4),
    integer(), n = length(x), size = 4), nrow(x), ncol(x))
decode <- function(x) matrix(readBin(writeBin(as.integer(x), raw(), size = 4),
    double(), n = length(x), size = 4), nrow(x), ncol(x))
for (method in c(1L, 3L)) for (classification in c(FALSE, TRUE)) {
    components <- if (method == 1L) 2L else 4L
    outputs <- list()
    for (precision in c(32L, 64L)) {
        xx <- if (precision == 32L) bits(X) else X
        xt <- if (precision == 32L) bits(Xtest) else Xtest
        yy <- if (classification) NULL else if (precision == 32L) bits(Y) else Y
        model <- cuda_resident_simpls_fit_cpp(xx, yy,
            if (classification) labels else NULL, 3L, precision, components, 2L, 3L, 2L, 123L, method)
        stopifnot(isTRUE(model$resident))
        if (method == 1L) {
            stopifnot(model$refresh_block == components)
        } else {
            stopifnot(model$refresh_block == 1L)
        }
        stopifnot(model$effective_oversample == 3L, model$effective_power == 2L)
        exported <- cuda_resident_export_cpp(model)
        if (precision == 32L) exported <- lapply(exported, decode)
        stopifnot(identical(dim(exported$Ttrain), c(64L, components)),
            max(abs(exported$Ttrain - scale(X) %*% exported$R)) < if (precision == 32L) 1e-4 else 1e-10)
        optional <- cuda_resident_export_cpp(model, loadings = TRUE, variance = TRUE)
        if (precision == 32L) optional <- lapply(optional, decode)
        standardized <- sweep(sweep(X, 2L, as.vector(optional$mX), "-"),
            2L, as.vector(optional$vX), "/")
        expected_p <- sweep(crossprod(standardized, optional$Ttrain),
            2L, colSums(optional$Ttrain^2), "/")
        residual <- standardized
        expected_ss <- numeric(components)
        for (j in seq_len(components)) {
            t <- optional$Ttrain[, j]
            before <- sum(residual^2)
            residual <- residual - tcrossprod(t, as.vector(crossprod(residual, t)) / sum(t^2))
            expected_ss[j] <- max(0, before - sum(residual^2))
        }
        expected_ss <- c(expected_ss, sum(standardized^2))
        optional_error <- max(abs(optional$P - expected_p) / (1 + abs(expected_p)),
            abs(as.vector(optional$predictor_ss) - expected_ss) / (1 + abs(expected_ss)))
        stopifnot(optional_error < if (precision == 32L) 2e-4 else 1e-10)
        cat("optional outputs", method, classification, precision, optional_error, "\n")
        prefix_values <- numeric()
        for (a in c(seq_len(components), rev(seq_len(components)))) {
            pred <- cuda_resident_simpls_predict_cpp(model, xt, a)
            stopifnot(identical(pred, cuda_resident_simpls_predict_cpp(model, xt, a)))
            if (precision == 32L) pred <- decode(pred)
            stopifnot(identical(dim(pred), c(11L, 3L)), all(is.finite(pred)))
            projected <- cuda_resident_project_cpp(model, xt, a)
            if (precision == 32L) projected <- decode(projected)
            standardized_test <- sweep(sweep(Xtest, 2L, as.vector(optional$mX), "-"),
                2L, as.vector(optional$vX), "/")
            stopifnot(max(abs(projected - standardized_test %*% optional$R[, seq_len(a), drop = FALSE])) <
                if (precision == 32L) 1e-4 else 1e-10)
            observed <- if (classification) diag(3)[labels[1:11], ] else Y[1:11, ]
            observed_input <- if (classification) NULL else if (precision == 32L) bits(observed) else observed
            sums <- cuda_resident_response_sums_cpp(model, xt, observed_input,
                if (classification) labels[1:11] else NULL, a)
            if (precision == 32L) sums <- decode(sums)
            expected_sums <- rbind(colSums((observed - pred)^2),
                colSums(sweep(observed, 2L, as.vector(optional$mY), "-")^2),
                colSums(sweep(observed, 2L, colMeans(observed), "-")^2))
            stopifnot(max(abs(sums - expected_sums) / (1 + abs(expected_sums))) <
                if (precision == 32L) 1e-4 else 1e-10)
            prefix_values <- c(prefix_values, as.double(pred))
            if (method == 1L) {
                xx_ref <- scale(X)
                yy_ref <- if (classification) diag(3)[labels, ] else Y
                centered_y <- scale(yy_ref, center = TRUE, scale = FALSE)
                u <- svd(crossprod(xx_ref, centered_y), nu = components, nv = 0)$u
                t <- xx_ref %*% u[, seq_len(a), drop = FALSE]
                test_scaled <- sweep(sweep(Xtest, 2L, attr(xx_ref, "scaled:center"), "-"),
                    2L, attr(xx_ref, "scaled:scale"), "/")
                test_scores <- test_scaled %*% u[, seq_len(a), drop = FALSE]
                reference <- sweep(test_scores %*% solve(crossprod(t), crossprod(t, centered_y)),
                    2L, colMeans(yy_ref), "+")
                delta <- max(abs(pred - reference))
                stopifnot(delta < if (precision == 32L) 1e-4 else 1e-10)
                cat("PLS-SVD dense reference:", precision, "prefix", a, "error", delta, "\n")
            }
            if (classification) {
                ranked <- cuda_resident_classify_cpp(model, xt, a, 0L, 3L)
                expected_rank <- t(apply(pred, 1, order, decreasing = TRUE))
                stopifnot(identical(unname(ranked), unname(expected_rank)))
                lda_scores <- cuda_resident_simpls_predict_cpp(model, xt, a, 1L)
                stopifnot(identical(lda_scores, cuda_resident_simpls_predict_cpp(model, xt, a, 1L)))
                if (precision == 32L) lda_scores <- decode(lda_scores)
                stopifnot(all(is.finite(lda_scores)))
                lda_rank <- cuda_resident_classify_cpp(model, xt, a, 1L, 3L)
                stopifnot(identical(unname(lda_rank), unname(t(apply(lda_scores, 1, order, decreasing = TRUE)))))
                if (method == 1L) {
                    counts <- tabulate(labels, 3)
                    means <- rowsum(t, labels) / counts
                    centered <- t - means[labels, , drop = FALSE]
                    covariance <- crossprod(centered) / (nrow(t) - 3L)
                    scale <- mean(diag(covariance))
                    if (!is.finite(scale) || scale <= 0) scale <- 1
                    linear <- solve(covariance + diag(1e-8 * scale, a), t(means))
                    constants <- -0.5 * colSums(t(means) * linear) + log(counts / length(labels))
                    lda_reference <- sweep(test_scores %*% linear, 2L, constants, "+")
                    delta <- max(abs(lda_scores - lda_reference))
                    stopifnot(delta < if (precision == 32L) 5e-4 else 1e-9)
                    cat("PLS-SVD LDA reference:", precision, "prefix", a, "error", delta, "\n")
                }
            }
        }
        outputs[[as.character(precision)]] <- prefix_values
        err <- tryCatch(cuda_resident_simpls_predict_cpp(model, xx[, 1:2], 1L),
            error = conditionMessage)
        stopifnot(is.character(err), grepl("dimension differs", err))
        cat("R CUDA interface:", precision, "method =", method, "classification =", classification, "PASS\n")
    }
    difference <- max(abs(outputs[["32"]] - outputs[["64"]]))
    stopifnot(difference < 1e-4)
    cat("float32/float64 prediction difference:", difference, "\n")
}
