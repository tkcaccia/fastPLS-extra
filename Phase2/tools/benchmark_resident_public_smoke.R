args <- commandArgs(trailingOnly = TRUE)
library_path <- if (length(args)) args[[1L]] else NULL
if (!is.null(library_path)) .libPaths(c(library_path, .libPaths()))
library(fastPLS)

data_file <- Sys.getenv("FASTPLS_METREF_INPUT")
output_file <- Sys.getenv("FASTPLS_SMOKE_OUTPUT")
if (!nzchar(data_file) || !nzchar(output_file)) {
    stop("Set FASTPLS_METREF_INPUT and FASTPLS_SMOKE_OUTPUT.", call. = FALSE)
}
environment <- new.env(parent = emptyenv())
load(data_file, envir = environment)
data <- environment$out
rows <- list()
for (precision in c("float32", "float64")) {
    Xtrain <- if (precision == "float32") float::fl(data$Xtrain) else data$Xtrain
    Xtest <- if (precision == "float32") float::fl(data$Xtest) else data$Xtest
    for (method in c("plssvd", "simpls")) {
        for (classifier in c("argmax", "lda")) {
            components <- if (method == "plssvd") 20L else 22L
            collected <- gc()
            elapsed <- system.time({
                model <- pls(Xtrain, data$Ytrain, Xtest, data$Ytest,
                    ncomp = components, method = method,
                    classifier = classifier, backend = "cuda",
                    svd.method = "rsvd", fit = FALSE,
                    return_variance = FALSE, return_loadings = FALSE,
                    seed = 17)
            })[["elapsed"]]
            internal <- fastPLS:::.fastpls_restore_internal_output_fields(model)
            stopifnot(!is.null(internal$resident_state),
                identical(model$diagnostics$residency$decomposition, "cuda"),
                is.finite(model$accuracy[[1L]]), is.finite(model$Q2Y[[1L]]))
            rows[[length(rows) + 1L]] <- data.frame(
                dataset = "MetRef", precision = precision, method = method,
                classifier = classifier, ncomp = components,
                elapsed_seconds = elapsed, accuracy = model$accuracy[[1L]],
                q2 = model$Q2Y[[1L]], resident = TRUE
            )
            rm(model); gc()
        }
    }
}
result <- do.call(rbind, rows)
print(result, row.names = FALSE)
write.csv(result, output_file, row.names = FALSE)
