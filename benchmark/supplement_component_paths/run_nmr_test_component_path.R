#!/usr/bin/env Rscript

# Fit each maximal NMR model on the predefined training partition and score
# every requested component prefix on the untouched predefined test partition.

args <- commandArgs(trailingOnly = TRUE)
get_arg <- function(name, default = NULL) {
    key <- paste0("--", name, "=")
    value <- args[startsWith(args, key)]
    if (!length(value)) return(default)
    sub(key, "", value[[1L]], fixed = TRUE)
}

input <- get_arg("input")
out_dir <- get_arg("out")
backend <- match.arg(get_arg("backend", "cpu"), c("cpu", "cuda", "metal"))
precision <- match.arg(
    get_arg("precision", "float32"), c("float32", "float64")
)
families <- strsplit(
    get_arg("families", "plssvd,simpls,opls,kernelpls"), ",", fixed = TRUE
)[[1L]]
valid_families <- c("plssvd", "simpls", "opls", "kernelpls")
if (length(setdiff(families, valid_families))) {
    stop("Unsupported PLS family: ", paste(setdiff(families, valid_families),
        collapse = ", "), call. = FALSE)
}
grid <- sort(unique(as.integer(strsplit(
    get_arg(
        "grid",
        "1,2,3,5,8,10,25,50,75,100,125,150,165,175,200,250,300"
    ),
    ",", fixed = TRUE
)[[1L]])))
seeds <- as.integer(strsplit(
    get_arg("seeds", "7,29,123"), ",", fixed = TRUE
)[[1L]])
response_block_size <- as.integer(get_arg("response_block_size", "2048"))

if (is.null(input) || is.null(out_dir)) {
    stop("Provide --input=NMR.RData and --out=RESULT_DIR.", call. = FALSE)
}
if (anyNA(grid) || min(grid) < 1L || any(diff(grid) <= 0L)) {
    stop("The component grid must contain increasing positive integers.",
        call. = FALSE)
}
if (anyNA(seeds) || !length(seeds)) {
    stop("At least one valid rSVD seed is required.", call. = FALSE)
}

script_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
script_path <- normalizePath(sub("^--file=", "", script_arg[[1L]]))
benchmark_dir <- dirname(dirname(script_path))
source(file.path(benchmark_dir, "nmr_protocol_helpers.R"))
source(file.path(benchmark_dir, "nmr_component_selection_helpers.R"))

fastpls_lib <- Sys.getenv("FASTPLS_LIB", unset = "")
if (nzchar(fastpls_lib)) .libPaths(c(fastpls_lib, .libPaths()))
suppressPackageStartupMessages(library(fastPLS))
if (backend == "cuda" && !isTRUE(has_cuda())) {
    stop("The selected fastPLS installation has no CUDA backend.", call. = FALSE)
}
if (backend == "metal" && !isTRUE(has_metal())) {
    stop("The selected fastPLS installation has no Metal backend.", call. = FALSE)
}

protocol <- fastpls_nmr_protocol(input)
Xtrain <- protocol$Xtrain
Ytrain <- protocol$Ytrain
Xtest <- protocol$Xtest
Ytest <- protocol$Ytest
protocol_metadata <- protocol$metadata
rm(protocol)

if (precision == "float32") {
    Xtrain <- float::fl(Xtrain)
    Ytrain <- float::fl(Ytrain)
    Xtest_fit <- float::fl(Xtest)
} else {
    Xtest_fit <- Xtest
}
rm(Xtest)
gc(full = TRUE)

dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
raw_rows <- list()
for (family in families) {
    for (seed in seeds) {
        message(sprintf(
            "[%s] fit family=%s seed=%d max_ncomp=%d backend=%s precision=%s",
            format(Sys.time(), "%Y-%m-%d %H:%M:%S"), family, seed,
            max(grid), backend, precision
        ))
        set.seed(seed)
        gc(full = TRUE)
        fit_error <- NULL
        fit_time <- system.time({
            model <- tryCatch(
                pls(
                    Xtrain, Ytrain, ncomp = grid, method = family,
                    backend = backend, scaling = "centering", fit = FALSE,
                    return_variance = FALSE, seed = seed, north = 1L,
                    kernel = "linear"
                ),
                error = function(error) {
                    fit_error <<- conditionMessage(error)
                    NULL
                }
            )
        })[["elapsed"]]

        if (is.null(model)) {
            raw_rows[[length(raw_rows) + 1L]] <- data.frame(
                family = family, seed = seed, ncomp = grid,
                RMSD = NA_real_, Q2Y = NA_real_, fit_seconds = fit_time,
                score_seconds = NA_real_, status = "failed",
                error = fit_error, stringsAsFactors = FALSE
            )
            next
        }

        score_time <- system.time({
            workspace <- fastpls_nmr_prepare_scoring(
                model, Xtest_fit, Ytest, response_block_size
            )
            metrics <- lapply(grid, function(component) {
                fastpls_nmr_score_prepared(
                    workspace, Ytest, component, response_block_size
                )
            })
        })[["elapsed"]]
        diagnostics <- model$diagnostics$rsvd
        raw_rows[[length(raw_rows) + 1L]] <- data.frame(
            family = family,
            seed = seed,
            ncomp = grid,
            RMSD = vapply(metrics, `[[`, numeric(1L), "RMSD"),
            Q2Y = vapply(metrics, `[[`, numeric(1L), "Q2"),
            fit_seconds = fit_time,
            score_seconds = score_time,
            control_profile = diagnostics$control_profile %||% NA_character_,
            oversample = diagnostics$oversample %||% NA_integer_,
            power = diagnostics$power %||% NA_integer_,
            status = "success",
            error = "",
            stringsAsFactors = FALSE
        )
        rm(model, workspace, metrics)
        gc(full = TRUE)
    }
    utils::write.csv(
        do.call(rbind, raw_rows),
        file.path(out_dir, "nmr_test_component_path_raw.csv"),
        row.names = FALSE
    )
}

raw <- do.call(rbind, raw_rows)
ok <- raw[raw$status == "success", , drop = FALSE]
if (!nrow(ok)) stop("All NMR held-out component-path fits failed.")
groups <- split(ok, interaction(ok$family, ok$ncomp, drop = TRUE))
summary <- do.call(rbind, lapply(groups, function(value) {
    data.frame(
        family = value$family[[1L]],
        ncomp = value$ncomp[[1L]],
        n_success = nrow(value),
        RMSD_median = stats::median(value$RMSD),
        RMSD_q25 = unname(stats::quantile(value$RMSD, 0.25)),
        RMSD_q75 = unname(stats::quantile(value$RMSD, 0.75)),
        Q2Y_median = stats::median(value$Q2Y),
        stringsAsFactors = FALSE
    )
}))
summary <- summary[order(match(summary$family, families), summary$ncomp), ]

utils::write.csv(raw,
    file.path(out_dir, "nmr_test_component_path_raw.csv"), row.names = FALSE)
utils::write.csv(summary,
    file.path(out_dir, "nmr_test_component_path_summary.csv"), row.names = FALSE)
write_fastpls_nmr_manifest(
    protocol_metadata,
    file.path(out_dir, "nmr_test_component_path_manifest.txt"),
    extra = list(
        evaluation_scope = paste(
            "fit only on predefined Xtrain/Ytrain; RMSD and Q2Y scored only",
            "on predictions for predefined Xtest against Ytest"
        ),
        package_version = as.character(packageVersion("fastPLS")),
        backend = backend,
        precision = precision,
        families = paste(families, collapse = ","),
        component_grid = paste(grid, collapse = ","),
        rsvd_seeds = paste(seeds, collapse = ",")
    )
)

message("Wrote held-out NMR component paths to ", out_dir)
