#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 5L) {
  stop(
    paste(
      "Usage: recheck_failed_controls.R SOURCE_DIR OUTPUT_DIR BACKEND",
      "OVERSAMPLE POWER"
    ),
    call. = FALSE
  )
}

source_dir <- normalizePath(args[[1L]], mustWork = TRUE)
out_dir <- args[[2L]]
backend <- match.arg(tolower(args[[3L]]), c("cpu", "cuda", "metal"))
automatic_controls <- identical(tolower(args[[4L]]), "auto") &&
  identical(tolower(args[[5L]]), "auto")
if (!automatic_controls &&
    (identical(tolower(args[[4L]]), "auto") ||
      identical(tolower(args[[5L]]), "auto"))) {
  stop("Use 'auto' for both OVERSAMPLE and POWER, or specify both integers.",
       call. = FALSE)
}
oversample <- if (automatic_controls) NA_integer_ else as.integer(args[[4L]])
power <- if (automatic_controls) NA_integer_ else as.integer(args[[5L]])
if (!automatic_controls &&
    (!is.finite(oversample) || oversample < 1L ||
      !is.finite(power) || power < 0L)) {
  stop("OVERSAMPLE and POWER must be valid non-negative integers or 'auto'.",
       call. = FALSE)
}

script_arg <- commandArgs()[grep("^--file=", commandArgs())]
script_path <- normalizePath(sub("^--file=", "", script_arg[[1L]]))
worker <- file.path(dirname(script_path), "worker.R")
dir.create(file.path(out_dir, "configs"), recursive = TRUE, showWarnings = FALSE)
dir.create(file.path(out_dir, "rows"), recursive = TRUE, showWarnings = FALSE)
dir.create(file.path(out_dir, "logs"), recursive = TRUE, showWarnings = FALSE)

failed <- read.csv(
  file.path(source_dir, "failures_and_numerical_discordance.csv"),
  stringsAsFactors = FALSE
)
source_backend <- Sys.getenv(
  "FASTPLS_RECHECK_SOURCE_BACKEND",
  unset = backend
)
source_backend <- match.arg(
  tolower(source_backend),
  c("cpu", "cuda", "metal")
)
failed <- failed[
  failed$backend == source_backend &
    failed$numerical_status == "outside_tolerance",
  ,
  drop = FALSE
]
route_pattern <- Sys.getenv("FASTPLS_RECHECK_ROUTE_PATTERN", unset = "")
if (nzchar(route_pattern)) {
  failed <- failed[
    grepl(route_pattern, failed$route, perl = TRUE),
    ,
    drop = FALSE
  ]
}
scenario_pattern <- Sys.getenv("FASTPLS_RECHECK_SCENARIO_PATTERN", unset = "")
if (nzchar(scenario_pattern)) {
  failed <- failed[
    grepl(scenario_pattern, failed$scenario_id, perl = TRUE),
    ,
    drop = FALSE
  ]
}
if (!nrow(failed)) {
  stop("No failed numerical comparisons were found for backend ", backend,
       call. = FALSE)
}

rows <- vector("list", nrow(failed))
for (index in seq_len(nrow(failed))) {
  original_id <- failed$run_id[[index]]
  config <- readRDS(file.path(source_dir, "configs", paste0(original_id, ".rds")))
  if (!file.exists(config$reference_file)) {
    relocated_reference <- file.path(
      source_dir,
      "references",
      basename(config$reference_file)
    )
    if (!file.exists(relocated_reference)) {
      stop("Reference file is unavailable for ", original_id, call. = FALSE)
    }
    config$reference_file <- relocated_reference
  }
  config$backend <- backend
  control_label <- if (automatic_controls) {
    "auto_profile"
  } else {
    paste0("explicit_o", oversample, "_p", power)
  }
  config$run_id <- paste0(
    config$scenario_id,
    "__", backend, "_rsvd_", control_label,
    "__rep", config$replicate
  )
  config$route <- paste0(backend, "_rsvd_", control_label)
  config$oversample <- oversample
  config$power <- power
  config$reference <- FALSE
  config_path <- file.path(out_dir, "configs", paste0(config$run_id, ".rds"))
  result_path <- file.path(out_dir, "rows", paste0(config$run_id, ".rds"))
  pid_path <- file.path(out_dir, "logs", paste0(config$run_id, ".pid"))
  done_path <- file.path(out_dir, "logs", paste0(config$run_id, ".done"))
  stdout_path <- file.path(out_dir, "logs", paste0(config$run_id, ".out"))
  stderr_path <- file.path(out_dir, "logs", paste0(config$run_id, ".err"))
  saveRDS(config, config_path)
  cat(sprintf("[%d/%d] %s\n", index, nrow(failed), config$run_id))
  status <- system2(
    file.path(R.home("bin"), "Rscript"),
    c(worker, config_path, result_path, pid_path, done_path),
    stdout = stdout_path,
    stderr = stderr_path
  )
  if (status != 0L || !file.exists(result_path)) {
    stop("Recheck worker failed for ", config$run_id, call. = FALSE)
  }
  rows[[index]] <- readRDS(result_path)
}

result <- do.call(rbind, rows)
write.csv(result, file.path(out_dir, "control_recheck.csv"), row.names = FALSE)
writeLines(
  c(
    paste("created:", format(Sys.time(), tz = "UTC", usetz = TRUE)),
    paste("source_dir:", source_dir),
    paste("source_backend:", source_backend),
    paste("backend:", backend),
    paste("route_pattern:", route_pattern),
    paste("scenario_pattern:", scenario_pattern),
    paste("controls:", if (automatic_controls) "automatic" else "explicit"),
    paste("oversample:", if (automatic_controls) "automatic" else oversample),
    paste("power:", if (automatic_controls) "automatic" else power),
    paste("completed:", sum(result$status == "success")),
    paste(
      "within_tolerance:",
      sum(result$numerical_status == "within_tolerance", na.rm = TRUE)
    )
  ),
  file.path(out_dir, "manifest.txt")
)
