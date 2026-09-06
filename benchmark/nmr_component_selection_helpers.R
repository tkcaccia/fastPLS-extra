# Reuse validation preprocessing and the maximal score projection across prefixes.
fastpls_nmr_prepare_scoring <- function(model, X_validation, Y_validation,
                                       block_size) {
    model <- fastPLS:::.fastpls_restore_internal_output_fields(model)
    if (!is.null(model$resident_state)) {
        backend <- if (!is.null(model$resident_backend)) {
            as.character(model$resident_backend)[1L]
        } else {
            sub("_resident$", "", as.character(model$predict_backend)[1L])
        }
        if (identical(backend, "metal")) {
            x <- fastPLS:::.resident_metal_input(
                X_validation, "X_validation")
            y <- fastPLS:::.resident_metal_input(
                Y_validation, "Y_validation")
        } else if (identical(backend, "cuda")) {
            precision <- as.character(model$precision)[1L]
            x <- fastPLS:::.resident_cuda_input(
                X_validation, precision, "X_validation")
            y <- fastPLS:::.resident_cuda_input(
                Y_validation, precision, "Y_validation")
        } else {
            stop("Unsupported resident NMR scoring backend: ", backend)
        }
        return(list(
            resident_backend = backend,
            resident_state = model$resident_state,
            precision = as.character(model$precision)[1L],
            x = x,
            y = y,
            response_elements = length(Y_validation)
        ))
    }
    to_double <- function(x) {
        if (inherits(x, "float32")) float::dbl(x) else as.matrix(x)
    }
    R <- to_double(model$R)
    Q <- to_double(model$Q)
    X_validation <- to_double(X_validation)
    Y_validation <- to_double(Y_validation)
    if (nrow(X_validation) != nrow(Y_validation) ||
        ncol(X_validation) != nrow(R) || ncol(Y_validation) != nrow(Q) ||
        length(block_size) != 1L || !is.finite(block_size) || block_size < 1L) {
        stop("Invalid validation dimensions or response block size.")
    }
    X_centered <- sweep(X_validation, 2L, as.numeric(model$mX), "-")
    scale_values <- as.numeric(model$vX)
    if (length(scale_values) == ncol(X_centered) && any(scale_values != 1)) {
        X_centered <- sweep(X_centered, 2L, scale_values, "/")
    }
    rank <- min(max(model$ncomp), ncol(R), ncol(Q))
    scores <- X_centered %*% R[, seq_len(rank), drop = FALSE]
    response_mean <- as.numeric(model$mY)
    total_sum_squares <- 0
    for (first in seq.int(1L, ncol(Y_validation), by = block_size)) {
        index <- first:min(ncol(Y_validation), first + block_size - 1L)
        centered <- sweep(Y_validation[, index, drop = FALSE],
            2L, response_mean[index], "-")
        total_sum_squares <- total_sum_squares + sum(centered * centered)
    }
    list(model = model, Q = Q, scores = scores,
        response_mean = response_mean, total_sum_squares = total_sum_squares)
}

fastpls_nmr_score_prepared <- function(workspace, Y_validation, k, block_size) {
    if (!is.null(workspace$resident_state)) {
        if (identical(workspace$resident_backend, "metal")) {
            sums <- fastPLS:::.resident_metal_summary(
                fastPLS:::metal_resident_response_sums_cpp(
                    workspace$resident_state, workspace$x, workspace$y,
                    NULL, k
                )
            )
        } else {
            sums <- fastPLS:::.resident_cuda_summary(
                fastPLS:::cuda_resident_response_sums_cpp(
                    workspace$resident_state, workspace$x, workspace$y,
                    NULL, k
                ),
                workspace$precision
            )
        }
        squared_error <- sum(sums[1L, ])
        total_sum_squares <- sum(sums[2L, ])
        return(c(
            RMSD = sqrt(squared_error / workspace$response_elements),
            MAE = NA_real_,
            Q2 = if (total_sum_squares > 0) {
                1 - squared_error / total_sum_squares
            } else {
                NA_real_
            }
        ))
    }
    model <- workspace$model
    slice <- match(k, model$ncomp)
    if (is.na(slice) || ncol(workspace$scores) < k) {
        stop("The fitted model does not contain the requested prefix.")
    }
    scores <- workspace$scores[, seq_len(k), drop = FALSE]
    squared_error <- absolute_error <- 0
    for (first in seq.int(1L, ncol(Y_validation), by = block_size)) {
        index <- first:min(ncol(Y_validation), first + block_size - 1L)
        if (identical(model$pls_method, "plssvd")) {
            weights <- if (is.list(model$W_latent)) {
                model$W_latent[[slice]][seq_len(k), index, drop = FALSE]
            } else if (!is.null(model$W_latent)) {
                matrix(model$W_latent[seq_len(k), index, slice], nrow = k)
            } else if (!is.null(model$C_latent)) {
                coefficient <- matrix(model$C_latent[seq_len(k), seq_len(k), slice],
                    nrow = k, ncol = k)
                coefficient %*% t(workspace$Q[index, seq_len(k), drop = FALSE])
            } else {
                stop("PLS-SVD prefix scoring requires its latent regression coefficients.")
            }
            predicted <- scores %*% weights
        } else {
            predicted <- scores %*% t(workspace$Q[index, seq_len(k), drop = FALSE])
        }
        predicted <- sweep(predicted, 2L, workspace$response_mean[index], "+")
        residual <- Y_validation[, index, drop = FALSE] - predicted
        squared_error <- squared_error + sum(residual * residual)
        absolute_error <- absolute_error + sum(abs(residual))
    }
    c(RMSD = sqrt(squared_error / length(Y_validation)),
        MAE = absolute_error / length(Y_validation),
        Q2 = if (workspace$total_sum_squares > 0) {
            1 - squared_error / workspace$total_sum_squares
        } else NA_real_)
}

fastpls_nmr_score_prefix <- function(model, X_validation, Y_validation,
                                    k, block_size) {
    workspace <- fastpls_nmr_prepare_scoring(
        model, X_validation, Y_validation, block_size)
    fastpls_nmr_score_prepared(workspace, Y_validation, k, block_size)
}
