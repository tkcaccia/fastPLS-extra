#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 2L) {
    stop("Usage: prepare_task.R OUTPUT_RDS MANIFEST_PREFIX", call. = FALSE)
}

script_arg <- grep("^--file=", commandArgs(FALSE), value = TRUE)[[1L]]
script_path <- normalizePath(sub("^--file=", "", script_arg))
benchmark_dir <- dirname(dirname(script_path))
source(file.path(benchmark_dir, "helpers_dataset_memory_compare.R"))

source_path <- find_dataset_rdata("tabula")
task <- as_task(source_path, "tabula", split_seed = 123L)
dir.create(dirname(args[[1L]]), recursive = TRUE, showWarnings = FALSE)
dir.create(dirname(args[[2L]]), recursive = TRUE, showWarnings = FALSE)
saveRDS(task, args[[1L]], compress = FALSE)

labels <- c(as.character(task$Ytrain), as.character(task$Ytest))
counts <- data.frame(
    class = names(table(labels)),
    count = as.integer(table(labels)),
    stringsAsFactors = FALSE
)
write.csv(counts, paste0(args[[2L]], "_class_counts.csv"), row.names = FALSE)

checksum <- system2("sha256sum", source_path, stdout = TRUE, stderr = TRUE)
writeLines(c(
    paste0("source=", source_path),
    paste0("source_sha256=", checksum),
    paste0("n_train=", task$n_train),
    paste0("n_test=", task$n_test),
    paste0("p=", task$p),
    paste0("classes=", task$n_classes),
    paste0("missing_labels=", sum(is.na(labels))),
    paste0("blank_labels=", sum(!nzchar(trimws(labels)))),
    paste0("split_seed=", task$split_seed)
), paste0(args[[2L]], ".txt"))
