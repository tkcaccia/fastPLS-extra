#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 3L) {
  stop(
    "Usage: summarize_cuda_prediction_agreement.R ",
    "JOBS_CSV RUN_DIRECTORY OUTPUT_CSV"
  )
}

jobs <- utils::read.csv(
  args[[1L]],
  stringsAsFactors = FALSE,
  check.names = FALSE
)
run_dir <- normalizePath(args[[2L]], winslash = "/", mustWork = TRUE)
keys <- unique(jobs[, c("dataset", "method_panel")])

prediction_agreement <- function(cpu, cuda) {
  a <- as.vector(cpu$pred)
  b <- as.vector(cuda$pred)
  if (length(a) != length(b)) return(NA_real_)
  if (
    is.factor(a) || is.character(a) ||
      is.factor(b) || is.character(b)
  ) {
    return(mean(as.character(a) == as.character(b), na.rm = TRUE))
  }
  a <- as.numeric(a)
  b <- as.numeric(b)
  denominator <- sqrt(sum(a^2))
  if (!is.finite(denominator) || denominator == 0) return(NA_real_)
  1 - sqrt(sum((a - b)^2)) / denominator
}

rows <- lapply(seq_len(nrow(keys)), function(i) {
  dataset <- keys$dataset[[i]]
  family <- keys$method_panel[[i]]
  cpu_path <- file.path(
    run_dir,
    "predictions",
    paste0(dataset, "__", family, "__CPU.rds")
  )
  cuda_path <- file.path(
    run_dir,
    "predictions",
    paste0(dataset, "__", family, "__CUDA.rds")
  )
  if (!file.exists(cpu_path) || !file.exists(cuda_path)) {
    return(data.frame(
      dataset = dataset,
      method_panel = family,
      prediction_agreement = NA_real_,
      status = "missing",
      stringsAsFactors = FALSE
    ))
  }
  cpu <- readRDS(cpu_path)
  cuda <- readRDS(cuda_path)
  data.frame(
    dataset = dataset,
    method_panel = family,
    prediction_agreement = prediction_agreement(cpu, cuda),
    status = "complete",
    stringsAsFactors = FALSE
  )
})

output <- do.call(rbind, rows)
utils::write.csv(output, args[[3L]], row.names = FALSE)
print(output)
