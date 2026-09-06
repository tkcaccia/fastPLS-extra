#!/usr/bin/env Rscript

# Run one isolated repetition of the deposited Nature Communications
# fastsimpls PLS-SVD implementation under the current NMR protocol.

args <- commandArgs(trailingOnly = TRUE)
get_arg <- function(name, default = NULL) {
    key <- paste0("--", name, "=")
    value <- args[startsWith(args, key)]
    if (!length(value)) return(default)
    sub(key, "", value[[1L]], fixed = TRUE)
}

input <- get_arg("input")
reference_source <- get_arg("reference_source")
output <- get_arg("output")
prediction_output <- get_arg("prediction_output")
ncomp <- as.integer(get_arg("ncomp", "165"))
seed <- as.integer(get_arg("seed", "123"))
replicate <- as.integer(get_arg("replicate", "1"))

required <- c(input, reference_source, output, prediction_output)
if (any(!nzchar(required)) || !all(file.exists(required[1:2]))) {
    stop(
        paste0(
            "Provide existing --input and --reference_source files plus ",
            "--output and --prediction_output paths."
        ),
        call. = FALSE
    )
}

script_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
script_path <- normalizePath(
    sub("^--file=", "", script_arg[[1L]]), mustWork = TRUE
)
source(file.path(dirname(script_path), "nmr_protocol_helpers.R"))

fastpls_library <- Sys.getenv("FASTPLS_LIB", unset = "")
if (nzchar(fastpls_library)) {
    .libPaths(unique(c(fastpls_library, .libPaths())))
}
suppressPackageStartupMessages(library(fastPLS))
protocol <- fastpls_nmr_protocol(input)
reference <- new.env(parent = globalenv())
sys.source(reference_source, envir = reference)
if (!exists("fastsimpls", envir = reference, inherits = FALSE) ||
        !exists("predict.simpls", envir = reference, inherits = FALSE)) {
    stop(
        "The reference script must define fastsimpls() and predict.simpls().",
        call. = FALSE
    )
}

current_rss_mb <- function() {
    if (file.exists("/proc/self/status")) {
        line <- grep(
            "^VmRSS:", readLines("/proc/self/status", warn = FALSE),
            value = TRUE
        )
        if (length(line)) {
            return(
                as.numeric(sub("^VmRSS:\\s*([0-9.]+).*", "\\1", line[[1L]])) /
                    1024
            )
        }
    }
    value <- suppressWarnings(as.numeric(system2(
        "ps", c("-o", "rss=", "-p", as.character(Sys.getpid())),
        stdout = TRUE, stderr = FALSE
    )))
    if (length(value) && is.finite(value[[1L]])) value[[1L]] / 1024 else NA_real_
}

set.seed(seed)
gc(FALSE)
baseline_rss_mb <- current_rss_mb()
fit_time <- system.time({
    model <- reference$fastsimpls(
        protocol$Xtrain,
        protocol$Ytrain,
        ncomp = ncomp,
        cent = TRUE,
        scal = FALSE,
        fit = FALSE,
        fast = TRUE,
        iter = FALSE
    )
})[["elapsed"]]
predict_time <- system.time({
    predicted <- as.matrix(
        reference$predict.simpls(
            model, protocol$Xtest, Ypred = TRUE
        )$Ypred
    )
})[["elapsed"]]

if (!identical(dim(predicted), dim(protocol$Ytest))) {
    stop("The deposited prediction dimensions do not match Ytest.", call. = FALSE)
}

prediction_error <- predicted - protocol$Ytest
press <- sum(prediction_error^2)
training_mean <- colMeans(protocol$Ytrain)
training_tss <- sum(
    sweep(protocol$Ytest, 2L, training_mean, "-")^2
)
metrics <- c(
    RMSD = sqrt(mean(prediction_error^2)),
    Q2 = if (is.finite(training_tss) && training_tss > 0) {
        1 - press / training_tss
    } else {
        NA_real_
    },
    MAE = mean(abs(prediction_error))
)
sample_rmsd <- sqrt(rowMeans((protocol$Ytest - predicted)^2))

row <- data.frame(
    dataset = "nmr",
    analysis_package_version = as.character(packageVersion("fastPLS")),
    protocol_version = protocol$metadata$protocol_version,
    canonical_input_verified = protocol$metadata$canonical_input_verified,
    water_columns_masked = protocol$metadata$water_columns_masked,
    response_columns_scored = protocol$metadata$response_columns_scored,
    family = "plssvd",
    implementation = "deposited_fastsimpls",
    backend = "cpu",
    solver = "irlba",
    precision = "float64",
    ncomp = ncomp,
    seed = seed,
    replicate = replicate,
    fit_time_sec = unname(fit_time),
    predict_time_sec = unname(predict_time),
    total_time_sec = unname(fit_time + predict_time),
    RMSD = unname(metrics[["RMSD"]]),
    Q2 = unname(metrics[["Q2"]]),
    MAE = unname(metrics[["MAE"]]),
    median_sample_RMSD = median(sample_rmsd),
    p95_sample_RMSD = unname(quantile(sample_rmsd, 0.95)),
    baseline_rss_mb = baseline_rss_mb,
    process_peak_rss_mb = NA_real_,
    status = "success",
    stringsAsFactors = FALSE
)

dir.create(dirname(output), recursive = TRUE, showWarnings = FALSE)
dir.create(dirname(prediction_output), recursive = TRUE, showWarnings = FALSE)
write.csv(row, output, row.names = FALSE, na = "")
saveRDS(
    list(
        observed = protocol$Ytest,
        predicted = predicted,
        per_sample_RMSD = sample_rmsd,
        protocol = protocol$metadata
    ),
    prediction_output
)
print(row)
