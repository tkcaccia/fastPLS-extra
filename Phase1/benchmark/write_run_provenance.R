#!/usr/bin/env Rscript

# Write immutable run provenance before launching a publication benchmark.
args <- commandArgs(trailingOnly = TRUE)

`%||%` <- function(x, y) if (is.null(x)) y else x

parse_args <- function(values) {
  out <- list()
  for (value in values) {
    if (!startsWith(value, "--") || !grepl("=", value, fixed = TRUE)) {
      stop("Arguments must use --name=value syntax.", call. = FALSE)
    }
    pair <- strsplit(sub("^--", "", value), "=", fixed = TRUE)[[1]]
    out[[pair[[1]]]] <- paste(pair[-1], collapse = "=")
  }
  out
}

git_value <- function(repo, ...) {
  if (!file.exists(file.path(repo, ".git"))) {
    return(NA_character_)
  }
  result <- suppressWarnings(
    system2("git", c("-C", repo, ...), stdout = TRUE, stderr = FALSE)
  )
  if (!length(result)) NA_character_ else paste(result, collapse = "\n")
}

md5_file <- function(path) {
  if (is.null(path) || !nzchar(path) || !file.exists(path)) {
    return(NA_character_)
  }
  unname(tools::md5sum(path)) # Retained for base-R portability; field names identify MD5.
}

sha256_file <- function(path) {
  if (is.null(path) || !nzchar(path) || !file.exists(path)) {
    return(NA_character_)
  }
  unname(tools::sha256sum(path))
}

opt <- parse_args(args)
required <- c("analysis", "output", "script")
missing <- required[!vapply(required, function(x) nzchar(opt[[x]] %||% ""), logical(1))]
if (length(missing)) {
  stop("Missing required arguments: ", paste(missing, collapse = ", "), call. = FALSE)
}

repo <- normalizePath(opt$repo %||% ".", mustWork = TRUE)
script <- normalizePath(opt$script, mustWork = TRUE)
output <- normalizePath(opt$output, mustWork = FALSE)
dir.create(dirname(output), recursive = TRUE, showWarnings = FALSE)

status <- git_value(repo, "status", "--porcelain")
record <- data.frame(
  field = c(
    "analysis_id", "created_utc", "repository", "repository_remote",
    "repository_commit", "repository_tree", "repository_tag",
    "repository_dirty", "script", "script_md5", "script_sha256",
    "source_archive", "source_archive_sha256", "fastPLS_version",
    "external_core_repository", "external_core_commit",
    "data_id", "split_id", "seed", "notes"
  ),
  value = c(
    opt$analysis,
    format(Sys.time(), tz = "UTC", usetz = TRUE),
    repo,
    git_value(repo, "config", "--get", "remote.origin.url"),
    git_value(repo, "rev-parse", "HEAD"),
    git_value(repo, "rev-parse", "HEAD^{tree}"),
    git_value(repo, "describe", "--tags", "--exact-match", "HEAD"),
    if (is.na(status) || !nzchar(status)) "FALSE" else "TRUE",
    script,
    md5_file(script),
    sha256_file(script),
    opt$archive %||% NA_character_,
    sha256_file(opt$archive),
    as.character(utils::packageVersion("fastPLS")),
    opt$core_repo %||% NA_character_,
    if (!is.null(opt$core_repo)) git_value(opt$core_repo, "rev-parse", "HEAD") else NA_character_,
    opt$data %||% NA_character_,
    opt$split %||% NA_character_,
    opt$seed %||% NA_character_,
    opt$notes %||% NA_character_
  ),
  stringsAsFactors = FALSE
)

utils::write.csv(record, output, row.names = FALSE, na = "")
capture.output(sessionInfo(), file = paste0(output, ".session_info.txt"))
message("Wrote provenance: ", output)
