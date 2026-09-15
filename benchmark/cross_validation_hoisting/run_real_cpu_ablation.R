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
selected_datasets <- strsplit(
    Sys.getenv("FASTPLS_CV_DATASETS", paste(names(specifications), collapse = ",")),
    ",", fixed = TRUE
)[[1L]]
selected_methods <- strsplit(
    Sys.getenv("FASTPLS_CV_METHODS", "plssvd,simpls,kernelpls"),
    ",", fixed = TRUE
)[[1L]]
selected_classifiers <- strsplit(
    Sys.getenv("FASTPLS_CV_CLASSIFIERS", "argmax,lda"),
    ",", fixed = TRUE
)[[1L]]
repetitions <- as.integer(Sys.getenv("FASTPLS_CV_REPETITIONS", "7"))
if (any(!selected_datasets %in% names(specifications))) {
    stop("FASTPLS_CV_DATASETS contains an unknown dataset.")
}
if (any(!selected_methods %in% c("plssvd", "simpls", "kernelpls"))) {
    stop("FASTPLS_CV_METHODS contains an unsupported method.")
}
if (any(!selected_classifiers %in% c("argmax", "lda"))) {
    stop("FASTPLS_CV_CLASSIFIERS contains an unsupported classifier.")
}
if (is.na(repetitions) || repetitions < 1L) {
    stop("FASTPLS_CV_REPETITIONS must be a positive integer.")
}

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
for (dataset in selected_datasets) {
    task <- readRDS(file.path(data_root, paste0(dataset, "_task.rds")))
    if (inherits(task$Xtrain, "float32")) {
        task$Xtrain <- float::dbl(task$Xtrain)
    }
    for (method in selected_methods) {
        for (classifier in selected_classifiers) {
            for (replicate in seq_len(repetitions)) {
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
