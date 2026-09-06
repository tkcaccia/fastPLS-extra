# Reuse only named data/preprocessing functions, never a benchmark's top-level
# loop or an external estimator. Loading a dataset is not fitting that package.
load_replay_functions <- function(path, names, envir) {
    loaded <- character()
    for (expression in parse(path)) {
        if (!is.call(expression) || !identical(expression[[1L]], as.name("<-")) ||
            !is.symbol(expression[[2L]]) || !is.call(expression[[3L]]) ||
            !identical(expression[[3L]][[1L]], as.name("function"))) next
        name <- as.character(expression[[2L]])
        if (name %in% names) {
            eval(expression, envir = envir)
            loaded <- c(loaded, name)
        }
    }
    if (!setequal(names, loaded)) stop("Missing replay helpers: ",
        paste(setdiff(names, loaded), collapse = ", "))
    invisible(envir)
}

load_replay_settings <- function(path, envir) {
    wanted <- c("opls_settings", "kernel_settings")
    loaded <- character()
    for (expression in parse(path)) {
        if (!is.call(expression) || !identical(expression[[1L]], as.name("<-")) ||
            !is.symbol(expression[[2L]])) next
        name <- as.character(expression[[2L]])
        if (name %in% wanted) {
            if (!is.call(expression[[3L]]) ||
                !identical(expression[[3L]][[1L]], as.name("data.frame"))) {
                stop("Unexpected settings declaration")
            }
            eval(expression, envir)
            loaded <- c(loaded, name)
        }
    }
    stopifnot(setequal(wanted, loaded))
    invisible(envir)
}

load_simpls_replay_tasks <- function(path, envir) {
    expressions <- parse(path)
    lhs <- function(expression) {
        if (is.call(expression) && identical(expression[[1L]], as.name("<-")) &&
            is.symbol(expression[[2L]])) as.character(expression[[2L]]) else ""
    }
    names <- vapply(expressions, lhs, "")
    first <- which(names == "synthetic_seeds")
    stopifnot(length(first) == 1L)
    boundaries <- which(names == "task_manifest" & seq_along(names) > first)
    if (!length(boundaries)) stop("Task-construction boundary is missing")
    # The later release-annotation assignment has the same name. Stop at the
    # first manifest, before any fit or benchmark-output construction.
    last <- boundaries[[1L]]
    for (index in seq.int(first, last - 1L)) eval(expressions[[index]], envir)
    envir$tasks
}

replay_setting_grid <- function(cases, opls, kernels) {
    rows <- list()
    for (case in cases) {
        q <- if (is.matrix(case$y_train)) ncol(case$y_train) else nlevels(factor(case$y_train))
        for (index in seq_len(nrow(opls) + nrow(kernels))) {
            orthogonal <- index <= nrow(opls)
            setting <- if (orthogonal) opls[index, , drop = FALSE] else
                kernels[index - nrow(opls), , drop = FALSE]
            row <- data.frame(case = case$name, family = if (orthogonal) "OPLS" else "kernelPLS",
                source = case$source, task = case$task, n_train = nrow(case$x_train),
                n_test = nrow(case$x_test), p = ncol(case$x_train), q = q,
                ncomp = case$ncomp, setting = setting$setting,
                north = if (orthogonal) setting$north else NA_integer_,
                kernel = if (orthogonal) NA_character_ else setting$kernel,
                gamma = NA_real_, degree = NA_integer_, coef0 = NA_real_,
                fast_metric = NA_real_, reference_metric = NA_real_, status = "not_loaded")
            if (!orthogonal) {
                multiplier <- if (is.na(setting$gamma_multiplier)) 1 else setting$gamma_multiplier
                row$gamma <- multiplier / ncol(case$x_train)
                row$degree <- if (is.na(setting$degree)) 3L else setting$degree
                row$coef0 <- if (is.na(setting$coef0)) 1 else setting$coef0
            }
            rows[[length(rows) + 1L]] <- row
        }
    }
    do.call(rbind, rows)
}

replay_metric <- function(prediction, truth, classification) {
    if (classification) return(mean(as.character(prediction) == as.character(truth)))
    sqrt(mean((prediction - truth)^2))
}

replay_prediction <- function(fit) {
    value <- fit$Ypred
    if (is.data.frame(value)) return(value[[ncol(value)]])
    if (is.list(value)) value <- value[[length(value)]]
    if (length(dim(value)) == 3L) {
        value <- value[, , dim(value)[3L], drop = FALSE][, , 1L]
    }
    value
}

replay_row_key <- function(data, keys) {
    if (!all(keys %in% names(data))) stop("Missing stored protocol keys")
    do.call(paste, c(lapply(data[keys], function(x) ifelse(is.na(x), "<NA>",
        as.character(x))), sep = "\r"))
}

replay_stored_match <- function(row, stored, keys) {
    key <- replay_row_key(row, keys)
    matches <- which(replay_row_key(stored, keys) == key)
    if (length(matches) != 1L) stop("Expected one stored row, found ",
        length(matches), " for ", gsub("\r", "/", key))
    stored[matches, , drop = FALSE]
}

replay_write_rows <- function(rows, path) {
    if (!length(rows)) return(invisible(NULL))
    write.csv(do.call(rbind, rows), path, row.names = FALSE)
}

replay_check_completion <- function(endpoints, folds, selections,
                                    expected_endpoints, expected_selections) {
    endpoints <- do.call(rbind, endpoints)
    folds <- do.call(rbind, folds)
    selections <- do.call(rbind, selections)
    complete <- nrow(endpoints) == expected_endpoints &&
        nrow(selections) == expected_selections &&
        all(endpoints$status == "success") &&
        all(is.finite(endpoints$candidate_metric)) &&
        all(folds$status == "success") &&
        all(is.finite(folds$candidate_metric)) && all(selections$complete)
    if (!isTRUE(complete)) stop("Replay incomplete; inspect retained error rows")
    invisible(TRUE)
}

replay_setting_arguments <- function(case, row) {
    args <- list(ncomp = case$ncomp, scaling = "autoscaling", backend = "cpu",
        svd.method = "irlba", classifier = "argmax", fit = TRUE, proj = TRUE,
        return_variance = FALSE, seed = 123L)
    if (identical(row$family, "OPLS")) {
        args$method <- "opls"
        args$north <- as.integer(row$north)
    } else {
        args$method <- "kernelpls"
        args$kernel <- row$kernel
        args$gamma <- as.numeric(row$gamma)
        if (!is.null(row$setting)) {
            multiplier <- if (grepl("^rbf_gamma_", row$setting)) {
                as.numeric(sub("_over_p$", "", sub("^rbf_gamma_", "", row$setting)))
            } else 1
            exact_gamma <- multiplier / ncol(case$x_train)
            if (!isTRUE(all.equal(exact_gamma, args$gamma, tolerance = 1e-12))) {
                stop("Stored gamma disagrees with the recorded setting formula")
            }
            args$gamma <- exact_gamma
        }
        args$degree <- as.integer(row$degree)
        args$coef0 <- as.numeric(row$coef0)
    }
    args
}

replay_case_fit <- function(case, row, fit_function = fastPLS::pls) {
    captured <- character()
    started <- proc.time()[["elapsed"]]
    fit <- tryCatch(withCallingHandlers(do.call(fit_function, c(list(
        Xtrain = case$x_train, Ytrain = case$y_train,
        Xtest = case$x_test, Ytest = case$y_test
    ), replay_setting_arguments(case, row))), warning = function(w) {
        captured <<- c(captured, conditionMessage(w))
        invokeRestart("muffleWarning")
    }), error = identity)
    elapsed <- proc.time()[["elapsed"]] - started
    if (inherits(fit, "error")) return(list(metric = NA_real_, elapsed = elapsed,
        prediction = NULL, status = "error", error = conditionMessage(fit),
        warnings = paste(unique(captured), collapse = " | ")))
    prediction <- replay_prediction(fit)
    list(metric = replay_metric(prediction, case$y_test,
        identical(case$task, "classification")), elapsed = elapsed,
        prediction = prediction, status = "success", error = "",
        warnings = paste(unique(captured), collapse = " | "))
}

replay_result_row <- function(identity, result, stored) {
    cbind(identity, data.frame(
        candidate_metric = result$metric, frozen_fastpls_metric = stored$fast_metric,
        stored_external_metric = stored$reference_metric,
        candidate_minus_frozen = result$metric - stored$fast_metric,
        candidate_minus_stored_external = result$metric - stored$reference_metric,
        candidate_fit_prediction_sec = result$elapsed,
        status = result$status, frozen_status = stored$status,
        warnings = result$warnings, error = result$error,
        reference_execution = "none; any comparison uses stored metrics only",
        prediction_agreement = NA_real_, stringsAsFactors = FALSE
    ))
}
