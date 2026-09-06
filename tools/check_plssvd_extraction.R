# GPL-3. Extraction validation against an existing current-code snapshot.
args <- commandArgs(trailingOnly = TRUE)
stopifnot(length(args) %in% c(2L, 3L))
if (any(grepl("frozen|ikpls", args, ignore.case = TRUE))) {
    stop("Only current development snapshots may be executed")
}
.libPaths(unique(c(normalizePath(args[[1L]]), .libPaths())))
suppressPackageStartupMessages(library(fastPLS))
options(backend = "cpu", cores = 1L)
outputs <- list()
warnings <- list()
for (shape in c("tall", "wide", "response_wide", "classification")) {
    set.seed(972)
    p <- if (shape == "wide") 240L else 30L
    q <- if (shape == "response_wide") 300L else 8L
    X <- matrix(rnorm(180L * p), 180L, p) + 2
    Y <- if (shape == "classification") {
        diag(q)[rep(seq_len(q), length.out = 180L), , drop = FALSE]
    } else {
        X %*% matrix(rnorm(p * q), p, q) + matrix(rnorm(180L * q), 180L, q)
    }
    Xt <- matrix(rnorm(23L * p), 23L, p) + 2
    original <- serialize(list(X, Y, Xt), NULL)
    for (solver in c("rsvd", "irlba")) for (scaling in 1:3) {
        for (cached in c(FALSE, TRUE)) for (full in c(FALSE, TRUE)) {
            key <- paste(shape, solver, scaling, cached, full, sep = "_")
            Sys.setenv(FASTPLS_STORE_B = if (full) "always" else "never",
                FASTPLS_PLSSVD_OPTIMIZED = as.integer(cached))
            messages <- character()
            outputs[[key]] <- withCallingHandlers({
                model <- fastPLS:::pls_model1(X, Y, c(1L, 3L, 6L), scaling,
                    full, fastPLS:::.svd_method_id(
                        if (solver == "rsvd") "cpu_rsvd" else "irlba"),
                    20L, 2L, 0, 17L)
                # The old low-level routine left R2Y uninitialized without fit.
                # That unused internal field is now zero; compare defined outputs.
                if (!full) model$R2Y <- NULL
                model$pls_method <- "plssvd"
                model$predict_latent_ok <- TRUE
                prediction <- fastPLS:::pls_predict(model, Xt, TRUE)
                list(model = model, prediction = prediction)
            }, warning = function(w) {
                messages <<- c(messages, conditionMessage(w))
                invokeRestart("muffleWarning")
            })
            warnings[[key]] <- messages
            stopifnot(identical(serialize(list(X, Y, Xt), NULL), original))
        }
    }
    cat(shape, "completed\n")
}
saveRDS(list(outputs = outputs, warnings = warnings, session = sessionInfo()), args[[2L]])
if (length(args) == 3L) {
    previous <- readRDS(args[[3L]])
    stopifnot(identical(names(outputs), names(previous$outputs)))
    comparisons <- do.call(rbind, lapply(names(outputs), function(key) {
        delta <- all.equal(outputs[[key]], previous$outputs[[key]], tolerance = 1e-12)
        data.frame(case = key,
            identical = identical(outputs[[key]], previous$outputs[[key]]),
            agrees = isTRUE(delta), details = paste(delta, collapse = "; "))
    }))
    write.csv(comparisons, paste0(args[[2L]], ".csv"), row.names = FALSE)
    stopifnot(all(comparisons$agrees), identical(warnings, previous$warnings))
    cat(nrow(comparisons), "PLS-SVD paths agree at 1e-12;",
        sum(comparisons$identical), "are bit-identical\n")
}
