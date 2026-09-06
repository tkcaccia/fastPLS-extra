# GPL-3. Compare two current development snapshots, never frozen comparators.
args <- commandArgs(trailingOnly = TRUE)
stopifnot(length(args) %in% c(2L, 3L))
if (any(grepl("frozen|ikpls", args, ignore.case = TRUE))) {
    stop("This validator executes current development snapshots only")
}
.libPaths(unique(c(normalizePath(args[[1L]]), .libPaths())))
suppressPackageStartupMessages(library(fastPLS))
options(backend = "cpu", cores = 1L)
Sys.setenv(FASTPLS_RETURN_TTRAIN = "1", FASTPLS_FAST_OPTIMIZED = "1",
    FASTPLS_FAST_DEFLCACHE = "1", FASTPLS_INCREMENTAL_COEFFICIENTS = "1")
cases <- list(
    tall = c(320L, 30L, 4L, 22L),
    wide = c(90L, 150L, 8L, 6L),
    response_wide = c(200L, 35L, 600L, 10L),
    ordinary = c(100L, 24L, 12L, 6L),
    classification = c(300L, 30L, 5L, 8L),
    classification_block = c(4000L, 320L, 400L, 12L)
)
outputs <- list()
timings <- list()
diagnostics <- list()
for (name in names(cases)) {
    shape <- cases[[name]]
    n <- shape[[1L]]
    p <- shape[[2L]]
    q <- shape[[3L]]
    set.seed(523)
    X <- matrix(rnorm(n * p), n, p) + 2
    Y <- if (startsWith(name, "classification")) {
        diag(q)[rep(seq_len(q), length.out = n), , drop = FALSE]
    } else {
        X %*% matrix(rnorm(p * q), p, q) + matrix(rnorm(n * q), n, q)
    }
    Xt <- matrix(rnorm(25L * p), 25L, p) + 2
    original <- serialize(list(X, Y, Xt), NULL)
    counts <- as.integer(unique(c(1L, 3L, shape[[4L]])))
    # The large case deliberately crosses the current candidate-block threshold.
    solvers <- if (name == "classification_block") "rsvd" else c("rsvd", "irlba")
    scales <- if (name == "ordinary") 1:3 else 2L
    for (solver in solvers) for (scaling in scales) for (seed in c(17L, 29L)) {
        solver_id <- fastPLS:::.svd_method_id(
            if (solver == "rsvd") "cpu_rsvd" else "irlba")
        for (full in c(FALSE, TRUE)) {
            key <- paste(name, solver, scaling, seed, full, sep = "_")
            Sys.setenv(FASTPLS_STORE_B = if (full) "always" else "never")
            warnings <- character()
            result <- withCallingHandlers({
                model <- fastPLS:::pls_model2_fast(X, Y, counts, scaling,
                    full, solver_id,
                    20L, 2L, 0, seed)
                model$predict_latent_ok <- TRUE
                model$pls_method <- "simpls"
                pred <- fastPLS:::pls_predict(model, Xt, TRUE)
                list(model = model[c("R", "Q", "B", "Ttrain", "mX", "vX",
                    "mY", "ncomp", "Yfit", "R2Y")], prediction = pred)
            }, warning = function(w) {
                warnings <<- c(warnings, conditionMessage(w))
                invokeRestart("muffleWarning")
            })
            stopifnot(identical(serialize(list(X, Y, Xt), NULL), original))
            outputs[[key]] <- result
            diagnostics[[key]] <- warnings
        }
        # Warmed current-code timings, not external or manuscript benchmarks.
        Sys.setenv(FASTPLS_STORE_B = "never")
        elapsed <- replicate(11L, system.time(fastPLS:::pls_model2_fast(
            X, Y, counts, scaling, FALSE,
            solver_id,
            20L, 2L, 0, seed))[["elapsed"]])[-1L]
        timings[[paste(name, solver, scaling, seed, sep = "_")]] <- elapsed
    }
    cat(name, "completed\n")
}
actual <- list(outputs = outputs, diagnostics = diagnostics, timings = timings,
    library = normalizePath(args[[1L]]), session = sessionInfo())
saveRDS(actual, args[[2L]])
if (length(args) == 3L) {
    expected <- readRDS(args[[3L]])
    stopifnot(identical(names(outputs), names(expected$outputs)))
    report <- do.call(rbind, lapply(names(outputs), function(key) {
        difference <- all.equal(outputs[[key]], expected$outputs[[key]],
            tolerance = 1e-12)
        data.frame(case = key,
            identical = identical(outputs[[key]], expected$outputs[[key]]),
            agrees = isTRUE(difference),
            details = paste(difference, collapse = "; "))
    }))
    write.csv(report, paste0(args[[2L]], ".csv"), row.names = FALSE)
    stopifnot(all(report$agrees), identical(diagnostics, expected$diagnostics))
    cat(nrow(report), "current-code paths agree at 1e-12;",
        sum(report$identical), "are bit-identical\n")
}
