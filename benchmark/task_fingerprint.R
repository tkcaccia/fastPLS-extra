#!/usr/bin/env Rscript

# Compare fixed benchmark tasks across hosts without moving the underlying
# biomedical matrices. The fingerprint combines dimensions, full sums, and a
# deterministic sample checksum for each predictor and response object.

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 2L) {
  stop("Usage: task_fingerprint.R TASK_DIRECTORY OUTPUT.csv", call. = FALSE)
}

task_directory <- normalizePath(args[[1L]], mustWork = TRUE)
output <- args[[2L]]
files <- sort(list.files(
  task_directory,
  pattern = "_task[.]rds$",
  full.names = TRUE
))
if (!length(files)) {
  stop("No *_task.rds files found in ", task_directory, call. = FALSE)
}

named_or <- function(value, name, default) {
  if (name %in% names(value)) value[[name]] else default
}

sample_indices <- function(length_out, count = 257L) {
  if (length_out < 1L) return(integer())
  unique(as.integer(round(seq(1, length_out, length.out = min(count, length_out)))))
}

numeric_fingerprint <- function(value) {
  fingerprint_value <- if (inherits(value, "float32")) {
    float::dbl(value)
  } else {
    value
  }
  dimensions <- dim(fingerprint_value)
  if (is.null(dimensions)) dimensions <- c(length(fingerprint_value), 1L)
  indices <- sample_indices(prod(dimensions))
  sampled <- as.numeric(fingerprint_value[indices])
  weights <- seq_along(sampled)
  c(
    rows = dimensions[[1L]],
    columns = dimensions[[2L]],
    total = as.numeric(sum(fingerprint_value, na.rm = TRUE)),
    sample_total = sum(sampled, na.rm = TRUE),
    sample_square_total = sum(sampled^2, na.rm = TRUE),
    sample_weighted_total = sum(sampled * weights, na.rm = TRUE),
    missing = sum(is.na(sampled))
  )
}

factor_fingerprint <- function(value) {
  value <- factor(value)
  codes <- as.integer(value)
  indices <- sample_indices(length(codes))
  counts <- tabulate(codes, nbins = nlevels(value))
  c(
    rows = length(codes),
    columns = 1L,
    total = sum(codes, na.rm = TRUE),
    sample_total = sum(codes[indices], na.rm = TRUE),
    sample_square_total = sum(codes[indices]^2, na.rm = TRUE),
    sample_weighted_total = sum(codes[indices] * seq_along(indices),
                                na.rm = TRUE),
    missing = sum(is.na(codes)),
    level_count = nlevels(value),
    level_signature = paste(levels(value), collapse = "|"),
    count_signature = paste(counts, collapse = "|")
  )
}

fingerprint <- function(value) {
  if (is.factor(value) || is.character(value)) {
    factor_fingerprint(value)
  } else {
    numeric_fingerprint(value)
  }
}

rows <- list()
for (file in files) {
  task <- readRDS(file)
  dataset <- sub("_task[.]rds$", "", basename(file))
  for (field in c("Xtrain", "Xtest", "Ytrain", "Ytest")) {
    values <- fingerprint(task[[field]])
    rows[[length(rows) + 1L]] <- data.frame(
      dataset = dataset,
      field = field,
      storage_class = paste(class(task[[field]]), collapse = "/"),
      rows = as.integer(values[["rows"]]),
      columns = as.integer(values[["columns"]]),
      total = as.numeric(values[["total"]]),
      sample_total = as.numeric(values[["sample_total"]]),
      sample_square_total = as.numeric(values[["sample_square_total"]]),
      sample_weighted_total = as.numeric(values[["sample_weighted_total"]]),
      missing = as.integer(values[["missing"]]),
      level_count = as.integer(named_or(values, "level_count", NA_integer_)),
      level_signature = as.character(named_or(values, "level_signature", "")),
      count_signature = as.character(named_or(values, "count_signature", "")),
      stringsAsFactors = FALSE
    )
  }
}

result <- do.call(rbind, rows)
dir.create(dirname(output), recursive = TRUE, showWarnings = FALSE)
write.csv(result, output, row.names = FALSE, na = "")
cat("Wrote", nrow(result), "fingerprint rows to", output, "\n")
