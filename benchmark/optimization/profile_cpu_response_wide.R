#!/usr/bin/env Rscript
# Diagnostic runs only: profiling overhead is not publication timing evidence.
args <- commandArgs(trailingOnly = TRUE)
stopifnot(length(args) == 3L)
library_path <- normalizePath(args[[1L]], mustWork = TRUE)
source_root <- normalizePath(args[[2L]], mustWork = TRUE)
output <- args[[3L]]
dir.create(output, recursive = TRUE, showWarnings = FALSE)
.libPaths(unique(c(library_path, .libPaths())))
suppressPackageStartupMessages(library(fastPLS))
options(backend = "cpu", cores = 1L)
Sys.setenv(FASTPLS_BENCH_PHASE_TIMING = "1")

# Reuse the exact task generator without executing the benchmark worker.
worker <- parse(file.path(source_root, "benchmark/multicore_scaling/worker.R"))
definitions <- Filter(function(expr) {
    is.call(expr) && identical(expr[[1L]], as.name("<-")) &&
        identical(expr[[2L]], as.name("make_task"))
}, as.list(worker))
stopifnot(length(definitions) == 1L)
eval(definitions[[1L]])
task <- make_task("response-wide regression")
fit_model <- function(with_test = TRUE) {
    fastPLS::pls(task$Xtrain, task$Ytrain,
        Xtest = if (with_test) task$Xtest else NULL,
        Ytest = if (with_test) task$Ytest else NULL,
        ncomp = task$ncomp, method = "simpls", backend = "cpu",
        svd.method = "rsvd", oversample = 32L, power = 5L,
        fit = FALSE, proj = FALSE, return_variance = FALSE, seed = 8127L)
}

Rprof(file.path(output, "combined.Rprof"), interval = 0.005)
profiled <- tryCatch(fit_model(), finally = Rprof(NULL))
capture.output(summaryRprof(file.path(output, "combined.Rprof")),
    file = file.path(output, "combined_profile.txt"))
capture.output(str(profiled$diagnostics),
    file = file.path(output, "diagnostics.txt"))
capture.output(sessionInfo(), file = file.path(output, "session.txt"))
saveRDS(list(package_path = find.package("fastPLS"),
    dll = getLoadedDLLs()[["fastPLS"]][["path"]],
    package_version = as.character(packageVersion("fastPLS")),
    source_root = source_root, openblas_threads = Sys.getenv("OPENBLAS_NUM_THREADS")),
    file.path(output, "manifest.rds"))

rows <- list()
for (with_test in c(TRUE, FALSE)) {
    for (replicate in seq_len(3L)) {
        gc()
        elapsed <- system.time(model <- fit_model(with_test))[["elapsed"]]
        native <- attr(model, "fastPLS_internal", exact = TRUE)$benchmark_phase_timing
        row <- data.frame(with_test = with_test, replicate = replicate,
            elapsed_sec = elapsed)
        if (length(native)) row <- cbind(row, as.data.frame(native))
        rows[[length(rows) + 1L]] <- row
        print(row)
    }
}
write.csv(do.call(rbind, rows), file.path(output, "phases.csv"), row.names = FALSE)
saveRDS(profiled$Ypred, file.path(output, "prediction.rds"))
