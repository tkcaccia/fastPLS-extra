#!/usr/bin/env Rscript

`%||%` <- function(left, right) {
    if (is.null(left) || !length(left)) right else left
}

parse_args <- function(values = commandArgs(trailingOnly = TRUE)) {
    result <- list()
    for (entry in values) {
        if (!startsWith(entry, "--")) next
        fields <- strsplit(substring(entry, 3L), "=", fixed = TRUE)[[1L]]
        result[[gsub("-", "_", fields[[1L]], fixed = TRUE)]] <-
            paste(fields[-1L], collapse = "=")
    }
    result
}

args <- parse_args()
required <- c("library", "tasks", "selection", "output", "backends")
missing <- required[!vapply(required, function(name) {
    is.character(args[[name]]) && nzchar(args[[name]])
}, logical(1L))]
if (length(missing)) stop("Missing --", paste(missing, collapse = ", --"))

file_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
if (!length(file_arg)) stop("Cannot locate run_selected_matrix.R.")
script_dir <- dirname(normalizePath(sub("^--file=", "", file_arg[[1L]])))
worker <- normalizePath(file.path(script_dir, "public_fit_cv_worker.R"),
    mustWork = TRUE)
tasks_dir <- normalizePath(args$tasks, mustWork = TRUE)
selection <- read.csv(args$selection, stringsAsFactors = FALSE)
output_dir <- normalizePath(args$output, mustWork = FALSE)
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

lock_dir <- file.path(output_dir, ".run_selected_matrix.lock")
if (!dir.create(lock_dir, showWarnings = FALSE)) {
    stop(
        "A selected-matrix lock already exists. Confirm that no runner is ",
        "active before removing: ", lock_dir
    )
}
writeLines(as.character(Sys.getpid()), file.path(lock_dir, "pid"))
on.exit(unlink(lock_dir, recursive = TRUE), add = TRUE)

backends <- strsplit(args$backends, ",", fixed = TRUE)[[1L]]
repetitions <- as.integer(args$repetitions %||% "5")
kfold <- as.integer(args$kfold %||% "10")
seed <- as.integer(args$seed %||% "123")
timeout_sec <- as.integer(args$timeout_sec %||% "1800")
precision <- args$precision %||% "float32"
context_mode <- args$context_mode %||% "cold"
if (is.na(timeout_sec) || timeout_sec < 1L) {
    stop("--timeout-sec must be a positive integer")
}
excluded_datasets <- strsplit(
    args$exclude_datasets %||% "", ",", fixed = TRUE
)[[1L]]
excluded_datasets <- excluded_datasets[nzchar(excluded_datasets)]
included_datasets <- strsplit(
    args$datasets %||% "", ",", fixed = TRUE
)[[1L]]
included_datasets <- included_datasets[nzchar(included_datasets)]
included_methods <- strsplit(
    args$methods %||% "plssvd,simpls,opls,kernelpls", ",", fixed = TRUE
)[[1L]]
included_workloads <- strsplit(
    args$workloads %||% "fit_predict,cv", ",", fixed = TRUE
)[[1L]]
if (!length(included_methods) ||
        !all(included_methods %in% c("plssvd", "simpls", "opls", "kernelpls"))) {
    stop("--methods contains an unsupported PLS family")
}
if (!length(included_workloads) ||
        !all(included_workloads %in% c("fit_predict", "cv"))) {
    stop("--workloads must contain fit_predict, cv, or both")
}

selection <- selection[
    selection$status == "success" &
        selection$family %in% included_methods &
        !selection$dataset %in% excluded_datasets,
    , drop = FALSE
]
if (length(included_datasets)) {
    selection <- selection[
        selection$dataset %in% included_datasets,
        , drop = FALSE
    ]
}
large_last <- c("nmr", "imagenet")
dataset_order <- c(
    sort(setdiff(unique(selection$dataset), large_last)),
    large_last[large_last %in% selection$dataset]
)
selection <- selection[order(
    match(selection$dataset, dataset_order), selection$family
), , drop = FALSE]

task_path <- function(dataset) {
    override <- args[[paste0(gsub("[^a-z0-9]", "_", dataset), "_task")]]
    if (!is.null(override) && nzchar(override)) {
        return(normalizePath(override, mustWork = TRUE))
    }
    candidate <- file.path(tasks_dir, paste0(dataset, "_task.rds"))
    if (file.exists(candidate)) normalizePath(candidate) else NA_character_
}

manifest <- do.call(rbind, lapply(seq_len(nrow(selection)), function(index) {
    row <- selection[index, ]
    task <- task_path(row$dataset)
    if (is.na(task)) return(NULL)
    classifier <- if (identical(row$task_type, "classification")) "lda" else "argmax"
    selection_metric <- if (identical(row$task_type, "classification")) {
        "accuracy"
    } else {
        "rmsd"
    }
    expand.grid(
        dataset = row$dataset,
        task = task,
        task_type = row$task_type,
        method = row$family,
        ncomp = as.integer(row$selected_ncomp),
        backend = backends,
        workload = included_workloads,
        replicate = seq_len(repetitions),
        classifier = classifier,
        selection_metric = selection_metric,
        stringsAsFactors = FALSE
    )
}))
manifest$precision <- precision
manifest$kfold <- kfold
manifest$seed <- seed
manifest$context_mode <- context_mode
manifest$n.cores <- as.integer(args$n_cores %||% "1")
write.csv(manifest, file.path(output_dir, "configuration_manifest.csv"), row.names = FALSE)

for (index in seq_len(nrow(manifest))) {
    row <- manifest[index, ]
    output <- file.path(output_dir, sprintf(
        "%s__%s__%s__%s__r%02d.csv",
        row$dataset, row$method, row$backend, row$workload, row$replicate
    ))
    log <- sub("\\.csv$", ".log", output)
    if (file.exists(output) && file.info(output)$size > 0L) next
    command <- c(
        worker,
        paste0("--library=", args$library),
        paste0("--task=", row$task),
        paste0("--dataset-id=", row$dataset),
        paste0("--output=", output),
        paste0("--backend=", row$backend),
        paste0("--precision=", row$precision),
        paste0("--method=", row$method),
        paste0("--classifier=", row$classifier),
        "--kernel=linear", "--north=1",
        paste0("--ncomp=", row$ncomp),
        paste0("--kfold=", row$kfold),
        paste0("--seed=", row$seed),
        paste0("--workload=", row$workload),
        paste0("--replicate=", row$replicate),
        paste0("--n.cores=", row$n.cores),
        paste0("--source-id=", args$source_id %||% "selected-release-matrix")
    )
    started <- proc.time()[["elapsed"]]
    status <- suppressWarnings(system2(
        file.path(R.home("bin"), "Rscript"), command,
        stdout = log, stderr = log, timeout = timeout_sec
    ))
    elapsed <- proc.time()[["elapsed"]] - started
    if (status != 0L) {
        message("Worker failed: ", paste(command, collapse = " "))
        failure_status <- if (identical(as.integer(status), 124L)) {
            "timeout"
        } else {
            "error"
        }
        failure <- data.frame(
            package_version = as.character(utils::packageVersion("fastPLS")),
            package_path = normalizePath(args$library, mustWork = TRUE),
            source_id = args$source_id %||% "selected-release-matrix",
            dataset = row$dataset,
            task = basename(row$task),
            workload = row$workload,
            backend = row$backend,
            precision = row$precision,
            method = row$method,
            classifier = if (identical(row$task_type, "classification")) {
                row$classifier
            } else {
                NA_character_
            },
            kernel = if (identical(row$method, "kernelpls")) {
                "linear"
            } else {
                NA_character_
            },
            north = if (identical(row$method, "opls")) 1L else NA_integer_,
            n = NA_integer_,
            test_n = NA_integer_,
            p = NA_integer_,
            q = NA_integer_,
            folds = row$kfold,
            requested_ncomp = as.character(row$ncomp),
            best_ncomp = NA_integer_,
            selection = row$selection_metric,
            metric_name = row$selection_metric,
            metric_value = NA_real_,
            elapsed_sec = elapsed,
            baseline_rss_mib = NA_real_,
            final_rss_mib = NA_real_,
            output_mib = NA_real_,
            fold_signature = NA_character_,
            prediction_signature = NA_character_,
            execution_route = NA_character_,
            seed = row$seed,
            n.cores = row$n.cores,
            replicate = row$replicate,
            status = failure_status,
            error_message = sprintf(
                "worker exit status %d after %.3f seconds", status, elapsed
            ),
            stringsAsFactors = FALSE
        )
        write.csv(failure, output, row.names = FALSE)
    }
}
