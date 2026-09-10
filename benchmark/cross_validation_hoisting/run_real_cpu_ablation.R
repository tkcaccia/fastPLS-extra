args <- commandArgs(trailingOnly = TRUE)
output <- if (length(args)) args[[1L]] else tempfile(fileext = ".csv")
library_path <- Sys.getenv("FASTPLS_LIBRARY", unset = NA_character_)
if (!is.na(library_path)) .libPaths(c(library_path, .libPaths()))
suppressPackageStartupMessages(library(fastPLS))

data_root <- Sys.getenv(
    "FASTPLS_METAL_TASK_ROOT",
    "/Users/stefano/Documents/GPUPLS/Data/metal_matched"
)
specifications <- list(
    retina = list(ncomp = c(10L, 20L, 30L)),
    tabula = list(ncomp = c(10L, 20L, 30L, 44L)),
    cifar100 = list(ncomp = c(50L, 100L))
)

set_cache <- function(enabled) {
    value <- if (enabled) "1" else "0"
    Sys.setenv(
        FASTPLS_CV_FOLD_GRAM_CACHE = value,
        FASTPLS_CV_FOLD_CROSSCOV_CACHE = value,
        FASTPLS_CV_CLASS_SUM_CACHE = value
    )
}

run_once <- function(task, dataset, method, classifier, enabled, replicate) {
    set_cache(enabled)
    gc()
    started <- proc.time()[["elapsed"]]
    fit <- pls.single.cv(
        task$Xtrain, task$Ytrain,
        ncomp = specifications[[dataset]]$ncomp,
        kfold = 10L, method = method, backend = "cpu",
        classifier = classifier, seed = 123L, fit = FALSE
    )
    elapsed <- proc.time()[["elapsed"]] - started
    signature <- vapply(
        fit$pred, function(value) paste(as.character(value), collapse = "|"),
        character(1L)
    )
    data.frame(
        dataset = dataset,
        method = method,
        classifier = classifier,
        cache = if (enabled) "hoisted" else "fold_local",
        replicate = replicate,
        elapsed_sec = elapsed,
        best_ncomp = fit$best_ncomp,
        metric = fit$best_metric_value,
        prediction_signature = paste(signature, collapse = "||"),
        stringsAsFactors = FALSE
    )
}

rows <- list()
for (dataset in names(specifications)) {
    task <- readRDS(file.path(data_root, paste0(dataset, "_task.rds")))
    if (inherits(task$Xtrain, "float32")) {
        task$Xtrain <- float::dbl(task$Xtrain)
    }
    for (method in c("simpls", "kernelpls")) {
        for (classifier in c("argmax", "lda")) {
            for (replicate in seq_len(7L)) {
                for (enabled in c(FALSE, TRUE)) {
                    rows[[length(rows) + 1L]] <- run_once(
                        task, dataset, method, classifier, enabled, replicate
                    )
                }
            }
        }
    }
}
result <- do.call(rbind, rows)
write.csv(result, output, row.names = FALSE)
print(aggregate(elapsed_sec ~ dataset + method + classifier + cache, result, median))
