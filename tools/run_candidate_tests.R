#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
stopifnot(length(args) == 3L)
library_path <- normalizePath(args[[1L]], mustWork = TRUE)
test_path <- normalizePath(args[[2L]], mustWork = TRUE)
output <- args[[3L]]
.libPaths(unique(c(library_path, .libPaths())))
suppressPackageStartupMessages(library(fastPLS))
stopifnot(startsWith(normalizePath(find.package("fastPLS")),
                    paste0(library_path, "/")))
cat("Candidate library:", find.package("fastPLS"), "\n")
cat("Version:", as.character(packageVersion("fastPLS")), "\n")
dir.create(dirname(output), recursive = TRUE, showWarnings = FALSE)
result <- testthat::test_dir(test_path, reporter = "summary",
                             stop_on_failure = FALSE)
saveRDS(result, output)
summary <- as.data.frame(result)
flat_summary <- summary[!vapply(summary, is.list, logical(1))]
write.csv(flat_summary, sub("[.]rds$", ".csv", output), row.names = FALSE)
cat("Passed:", sum(summary$passed), "Failed:", sum(summary$failed),
    "Errors:", sum(summary$error), "Warnings:", sum(summary$warning), "\n")
if (any(summary$failed > 0L | summary$error)) quit(status = 1L)
