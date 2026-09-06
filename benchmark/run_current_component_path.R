#!/usr/bin/env Rscript

# Benchmark predictive and computational paths over sparse component grids.
# Each row is measured in a fresh R process using the current public API.

args <- commandArgs(trailingOnly = TRUE)
benchmark_lib <- Sys.getenv("FASTPLS_BENCH_LIB", "")
if (nzchar(benchmark_lib)) {
    .libPaths(unique(c(benchmark_lib, .libPaths())))
}

suppressPackageStartupMessages(library(fastPLS))

script_arg <- commandArgs()[grep("^--file=", commandArgs())]
script_path <- normalizePath(sub("^--file=", "", script_arg[[1L]]))
repo_dir <- normalizePath(file.path(dirname(script_path), ".."))
worker <- file.path(
    repo_dir,
    "benchmark",
    "metal_validation",
    "metal_worker.R"
)

out_dir <- if (length(args)) {
    args[[1L]]
} else {
    results_root <- Sys.getenv("FASTPLS_RESULTS_ROOT")
    if (!nzchar(results_root)) {
        stop("Supply an output directory or set FASTPLS_RESULTS_ROOT.", call. = FALSE)
    }
    file.path(results_root, paste0(
        "component_path_", format(Sys.time(), "%Y%m%d_%H%M%S")
    ))
}
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

accelerator <- tolower(Sys.getenv("FASTPLS_COMPONENT_ACCELERATOR", "metal"))
if (!accelerator %in% c("cuda", "metal")) {
    stop(
        "FASTPLS_COMPONENT_ACCELERATOR must be 'cuda' or 'metal'.",
        call. = FALSE
    )
}
if (accelerator == "cuda" && !isTRUE(has_cuda())) {
    stop("CUDA is unavailable; no CPU fallback is permitted.", call. = FALSE)
}
if (accelerator == "metal" && !isTRUE(has_metal())) {
    stop("Metal is unavailable; no CPU fallback is permitted.", call. = FALSE)
}

task_root <- normalizePath(
    Sys.getenv("FASTPLS_COMPONENT_TASK_ROOT", Sys.getenv("FASTPLS_DATA_ROOT")),
    mustWork = TRUE
)
selection_path <- normalizePath(
    Sys.getenv("FASTPLS_SELECTED_COMPONENTS_CSV"),
    mustWork = TRUE
)
replicates <- as.integer(Sys.getenv("FASTPLS_COMPONENT_REPLICATES", "5"))
if (!is.finite(replicates) || replicates < 1L) {
    stop("FASTPLS_COMPONENT_REPLICATES must be positive.", call. = FALSE)
}
component_precision <- tolower(Sys.getenv(
    "FASTPLS_COMPONENT_PRECISION",
    "float32"
))
if (!component_precision %in% c("float32", "float64")) {
    stop(
        "FASTPLS_COMPONENT_PRECISION must be 'float32' or 'float64'.",
        call. = FALSE
    )
}
if (accelerator == "metal" && component_precision != "float32") {
    stop(
        "Metal component paths require matched float32 CPU and Metal inputs.",
        call. = FALSE
    )
}

all_datasets <- c(
    "cbmc_citeseq", "ccle", "cifar100", "gtex_v8", "metref", "prism",
    "retina", "tabula", "tcga_brca", "tcga_hnsc_methylation",
    "tcga_pan_cancer"
)
all_families <- c("plssvd", "simpls", "opls", "kernelpls")

split_selection <- function(value, choices, label) {
    if (!nzchar(value)) {
        return(choices)
    }
    selected_values <- trimws(strsplit(value, ",", fixed = TRUE)[[1L]])
    selected_values <- selected_values[nzchar(selected_values)]
    invalid <- setdiff(selected_values, choices)
    if (length(invalid)) {
        stop(
            label,
            " contains unsupported values: ",
            paste(invalid, collapse = ", "),
            call. = FALSE
        )
    }
    selected_values
}

datasets <- split_selection(
    Sys.getenv("FASTPLS_COMPONENT_DATASETS", ""),
    all_datasets,
    "FASTPLS_COMPONENT_DATASETS"
)
families <- split_selection(
    Sys.getenv("FASTPLS_COMPONENT_FAMILIES", ""),
    all_families,
    "FASTPLS_COMPONENT_FAMILIES"
)

# Sparse checkpoints preserve the earlier component-path design while adding
# one component and each current training-selected component.
base_grids <- list(
    cbmc_citeseq = c(1L, 2L, 5L, 10L, 20L, 50L),
    ccle = c(1L, 2L, 5L, 10L, 18L, 50L, 100L),
    cifar100 = c(1L, 2L, 5L, 10L, 20L, 50L, 100L, 200L, 300L),
    gtex_v8 = c(1L, 2L, 5L, 10L, 20L, 32L, 50L, 100L, 200L),
    metref = c(1L, 2L, 5L, 10L, 22L, 50L, 100L, 150L),
    prism = c(1L, 2L, 5L, 10L, 20L, 50L, 100L),
    retina = c(1L, 2L, 5L, 10L, 20L, 30L, 50L),
    tabula = c(1L, 2L, 5L, 10L, 20L, 32L, 50L),
    tcga_brca = c(1L, 2L, 3L, 5L, 10L, 20L, 50L),
    tcga_hnsc_methylation = c(1L, 2L, 5L, 10L, 20L, 50L),
    tcga_pan_cancer = c(1L, 2L, 5L, 10L, 20L, 32L, 50L, 100L, 200L)
)

selected <- read.csv(selection_path, stringsAsFactors = FALSE)
if (!"method" %in% names(selected) && "family" %in% names(selected)) {
    selected$method <- selected$family
}
if (!"ncomp" %in% names(selected) &&
    "selected_ncomp" %in% names(selected)) {
    selected$ncomp <- selected$selected_ncomp
}
required <- c("dataset", "method", "ncomp")
missing_columns <- setdiff(required, names(selected))
if (length(missing_columns)) {
    stop(
        "Selected-component table is missing: ",
        paste(missing_columns, collapse = ", "),
        call. = FALSE
    )
}
selected <- selected[required]
selected$dataset <- tolower(selected$dataset)
selected$method <- tolower(selected$method)
selected$ncomp <- as.integer(selected$ncomp)

task_path <- function(dataset) {
    path <- file.path(task_root, paste0(dataset, "_task.rds"))
    if (!file.exists(path)) {
        stop("Missing task: ", path, call. = FALSE)
    }
    normalizePath(path)
}

task_metadata <- lapply(datasets, function(dataset) {
    task <- readRDS(task_path(dataset))
    classification <- identical(task$task_type, "classification") ||
        is.factor(task$Ytrain) || is.character(task$Ytrain)
    q <- if (classification) {
        if (!is.null(task$n_classes)) {
            as.integer(task$n_classes)
        } else {
            nlevels(factor(task$Ytrain))
        }
    } else {
        ncol(as.matrix(task$Ytrain))
    }
    n_train <- if (!is.null(task$n_train)) {
        as.integer(task$n_train)
    } else {
        nrow(task$Xtrain)
    }
    n_test <- if (!is.null(task$n_test)) {
        as.integer(task$n_test)
    } else {
        nrow(task$Xtest)
    }
    p <- if (!is.null(task$p)) as.integer(task$p) else ncol(task$Xtrain)
    data.frame(
        dataset = dataset,
        task_type = if (classification) "classification" else "regression",
        n_train = n_train,
        n_test = n_test,
        p = p,
        q = q,
        stringsAsFactors = FALSE
    )
})
task_metadata <- do.call(rbind, task_metadata)
write.csv(
    task_metadata,
    file.path(out_dir, "component_path_task_manifest.csv"),
    row.names = FALSE
)

component_grid <- function(dataset, method, metadata) {
    selected_ncomp <- selected$ncomp[
        selected$dataset == dataset & selected$method == method
    ]
    if (length(selected_ncomp) != 1L) {
        stop("Missing unique selected component for ", dataset, "/", method)
    }
    upper <- min(metadata$n_train - 1L, metadata$p)
    if (identical(method, "plssvd")) {
        upper <- min(upper, metadata$q)
    }
    sort(unique(c(base_grids[[dataset]], selected_ncomp)))[
        sort(unique(c(base_grids[[dataset]], selected_ncomp))) <= upper
    ]
}

make_config <- function(metadata, method, ncomp, backend, replicate) {
    list(
        run_id = paste(
            "component_path", metadata$dataset, method,
            paste0("k", ncomp), backend, paste0("r", replicate),
            sep = "__"
        ),
        experiment = "current_release_component_path",
        dataset = metadata$dataset,
        task_type = metadata$task_type,
        method = method,
        backend = backend,
        precision = component_precision,
        classifier = "argmax",
        ncomp = as.integer(ncomp),
        replicate = as.integer(replicate),
        seed = as.integer(1000L + replicate),
        data_seed = 777L,
        oversample = NA_integer_,
        power = NA_integer_,
        svd_method = "rsvd",
        task_path = task_path(metadata$dataset),
        n_train = metadata$n_train,
        n_test = metadata$n_test,
        p = metadata$p,
        q = metadata$q,
        latent_rank = NA_integer_,
        noise = NA_real_,
        train_n = NULL,
        test_n = NULL,
        p_limit = NULL,
        q_limit = NULL,
        kernel = "linear",
        gamma = NULL,
        degree = 3L,
        coef0 = 1,
        north = 1L,
        scaling = "centering",
        save_diagnostics = FALSE,
        save_prediction = FALSE
    )
}

configs <- list()
for (index in seq_len(nrow(task_metadata))) {
    metadata <- task_metadata[index, , drop = FALSE]
    for (method in families) {
        grid <- component_grid(metadata$dataset, method, metadata)
        for (ncomp in grid) {
            for (backend in c("cpu", accelerator)) {
                for (replicate in seq_len(replicates)) {
                    configs[[length(configs) + 1L]] <- make_config(
                        metadata,
                        method,
                        ncomp,
                        backend,
                        replicate
                    )
                }
            }
        }
    }
}
saveRDS(configs, file.path(out_dir, "configurations.rds"))

parse_peak_rss <- function(path) {
    if (!file.exists(path)) {
        return(NA_real_)
    }
    lines <- readLines(path, warn = FALSE)
    hit <- grep("maximum resident set size", lines, value = TRUE)
    if (!length(hit)) {
        hit <- grep("maximum resident set size", tolower(lines), value = TRUE)
    }
    if (!length(hit)) {
        return(NA_real_)
    }
    value <- suppressWarnings(as.numeric(gsub("[^0-9]", "", tail(hit, 1L))))
    if (!is.finite(value)) {
        return(NA_real_)
    }
    if (identical(Sys.info()[["sysname"]], "Darwin")) {
        value / 1024^2
    } else {
        value / 1024
    }
}

raw_path <- file.path(out_dir, "component_path_raw.csv")
rows <- list()
time_flag <- if (identical(Sys.info()[["sysname"]], "Darwin")) "-l" else "-v"
for (index in seq_along(configs)) {
    cfg <- configs[[index]]
    cfg_path <- file.path(out_dir, paste0(cfg$run_id, "_config.rds"))
    result_path <- file.path(out_dir, paste0(cfg$run_id, "_result.rds"))
    stdout_path <- file.path(out_dir, paste0(cfg$run_id, ".out"))
    time_path <- file.path(out_dir, paste0(cfg$run_id, ".time"))

    if (!file.exists(result_path)) {
        saveRDS(cfg, cfg_path)
        cat(sprintf(
            "[%d/%d] %s\n",
            index,
            length(configs),
            cfg$run_id
        ))
        status <- system2(
            "/usr/bin/time",
            c(
                time_flag,
                file.path(R.home("bin"), "Rscript"),
                worker,
                cfg_path,
                result_path
            ),
            stdout = stdout_path,
            stderr = time_path
        )
        if (!file.exists(result_path)) {
            failure <- data.frame(
                run_id = cfg$run_id,
                experiment = cfg$experiment,
                dataset = cfg$dataset,
                task_type = cfg$task_type,
                method = cfg$method,
                backend_requested = cfg$backend,
                backend_reported = NA_character_,
                prediction_backend = NA_character_,
                svd_method = cfg$svd_method,
                classifier = cfg$classifier,
                precision = cfg$precision,
                ncomp = cfg$ncomp,
                seed = cfg$seed,
                replicate = cfg$replicate,
                status = "process_failed",
                error = paste("exit status", status),
                stringsAsFactors = FALSE
            )
            saveRDS(failure, result_path)
        }
        unlink(cfg_path)
    }

    row <- readRDS(result_path)
    if (identical(row$status, "success")) {
        # Explicit accelerator requests use strict dispatch; success proves
        # that the requested backend executed without a CPU fallback.
        row$backend_reported <- cfg$backend
    }
    row$peak_rss_mb <- parse_peak_rss(time_path)
    row$incremental_peak_rss_mb <- if (
        is.finite(row$peak_rss_mb) && is.finite(row$baseline_rss_mb)
    ) {
        max(0, row$peak_rss_mb - row$baseline_rss_mb)
    } else {
        NA_real_
    }
    row$package_version <- as.character(packageVersion("fastPLS"))
    if (identical(row$status, "success") && cfg$backend != "cpu") {
        expected <- cfg$backend
        reported <- tolower(as.character(row$backend_reported))
        if (!identical(reported, expected)) {
            row$status <- "backend_mismatch"
            row$error <- paste0(
                "Requested ", expected, " but model reported ", reported,
                "; no fallback result accepted."
            )
        }
    }
    saveRDS(row, result_path)
    write.csv(
        row,
        sub("[.]rds$", ".csv", result_path),
        row.names = FALSE
    )
    rows[[length(rows) + 1L]] <- row
    if (index %% 10L == 0L || index == length(configs)) {
        write.csv(do.call(rbind, rows), raw_path, row.names = FALSE)
    }
}

raw <- do.call(rbind, rows)
write.csv(raw, raw_path, row.names = FALSE)

group_columns <- c(
    "dataset", "task_type", "method", "backend_requested", "precision",
    "classifier", "svd_method", "ncomp"
)
keys <- unique(raw[group_columns])
summary_rows <- lapply(seq_len(nrow(keys)), function(index) {
    key <- keys[index, , drop = FALSE]
    keep <- rep(TRUE, nrow(raw))
    for (column in group_columns) {
        keep <- keep & raw[[column]] == key[[column]][[1L]]
    }
    values <- raw[keep, , drop = FALSE]
    ok <- values$status == "success"
    summarize <- function(column, fun) {
        x <- values[[column]][ok]
        if (length(x) && any(is.finite(x))) fun(x[is.finite(x)]) else NA_real_
    }
    data.frame(
        package_version = as.character(packageVersion("fastPLS")),
        key,
        n_ok = sum(ok),
        n_failed = sum(!ok),
        median_fit_sec = summarize("fit_sec", median),
        iqr_fit_sec = summarize("fit_sec", IQR),
        median_prediction_sec = summarize("prediction_sec", median),
        iqr_prediction_sec = summarize("prediction_sec", IQR),
        median_total_sec = summarize("total_sec", median),
        iqr_total_sec = summarize("total_sec", IQR),
        median_metric = summarize("metric_value", median),
        median_peak_rss_mb = summarize("peak_rss_mb", median),
        median_incremental_rss_mb = summarize(
            "incremental_peak_rss_mb",
            median
        ),
        control_profile = paste(
            unique(values$control_profile[ok & nzchar(values$control_profile)]),
            collapse = " | "
        ),
        oversample = summarize("oversample", max),
        power = summarize("power", max),
        direction_rule = paste(
            unique(values$direction_rule[ok & nzchar(values$direction_rule)]),
            collapse = " | "
        ),
        fresh_start = {
            observed <- values$fresh_start[ok & !is.na(values$fresh_start)]
            if (length(observed)) all(observed %in% TRUE) else NA
        },
        errors = paste(unique(values$error[!ok & nzchar(values$error)]),
                       collapse = " | "),
        stringsAsFactors = FALSE,
        check.names = FALSE
    )
})
summary <- do.call(rbind, summary_rows)
write.csv(
    summary,
    file.path(out_dir, "component_path_summary.csv"),
    row.names = FALSE
)

writeLines(c(
    paste("created:", format(Sys.time(), tz = "UTC", usetz = TRUE)),
    paste("fastPLS:", as.character(packageVersion("fastPLS"))),
    paste("accelerator:", accelerator),
    paste("accelerator_available:", if (accelerator == "cuda") {
        has_cuda()
    } else {
        has_metal()
    }),
    paste("task_root:", task_root),
    paste("selected_components:", selection_path),
    paste("precision:", component_precision),
    paste("replicates:", replicates),
    capture.output(sessionInfo())
), file.path(out_dir, "session_info.txt"))

cat("Results:", normalizePath(out_dir), "\n")
