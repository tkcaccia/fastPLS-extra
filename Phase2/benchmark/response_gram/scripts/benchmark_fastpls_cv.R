args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 6L) {
    stop(
        paste(
            "usage: benchmark_fastpls_cv.R",
            "PACKAGE_LIBRARY NMR.RData OUTPUT.csv PRECISION NCOMP REPETITIONS"
        ),
        call. = FALSE
    )
}

package_library <- normalizePath(args[[1L]], mustWork = TRUE)
data_path <- normalizePath(args[[2L]], mustWork = TRUE)
output_path <- args[[3L]]
precision <- match.arg(args[[4L]], c("float32", "float64"))
components <- as.integer(args[[5L]])
repetitions <- as.integer(args[[6L]])
if (!is.finite(components) || components < 1L ||
        !is.finite(repetitions) || repetitions < 1L) {
    stop("NCOMP and REPETITIONS must be positive integers", call. = FALSE)
}

.libPaths(c(package_library, .libPaths()))
suppressPackageStartupMessages(library(fastPLS))
loaded_version <- as.character(packageVersion("fastPLS"))

environment <- new.env(parent = emptyenv())
load(data_path, envir = environment)
required <- c("Xtrain", "Ytrain")
if (!all(required %in% ls(environment))) {
    stop("NMR file must contain Xtrain and Ytrain", call. = FALSE)
}
predictors <- as.matrix(environment$Xtrain)
responses <- as.matrix(environment$Ytrain)
if (precision == "float32") {
    predictors <- float::fl(predictors)
    responses <- float::fl(responses)
}

rows <- vector("list", repetitions)
for (repetition in seq_len(repetitions)) {
    invisible(gc())
    started <- proc.time()[["elapsed"]]
    fit <- pls.single.cv(
        predictors,
        responses,
        ncomp = components,
        scaling = "centering",
        method = "simpls",
        backend = "cpu",
        seed = 11L,
        kfold = 10L,
        fit = FALSE
    )
    elapsed <- proc.time()[["elapsed"]] - started
    rows[[repetition]] <- data.frame(
        package_version = loaded_version,
        precision = precision,
        n = nrow(predictors),
        p = ncol(predictors),
        q = ncol(responses),
        components = components,
        folds = 10L,
        repetition = repetition,
        elapsed_seconds = elapsed,
        Q2Y = unname(fit$Q2Y[[length(fit$Q2Y)]]),
        RMSD = unname(fit$RMSD[[length(fit$RMSD)]]),
        best_ncomp = fit$best_ncomp,
        route = fit$xprod,
        stringsAsFactors = FALSE
    )
}

result <- do.call(rbind, rows)
dir.create(dirname(output_path), recursive = TRUE, showWarnings = FALSE)
write.csv(result, output_path, row.names = FALSE)
print(result)
