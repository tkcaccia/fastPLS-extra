#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 1L) {
    stop("Usage: audit_figure2_cv_lda.R <summary-dir>", call. = FALSE)
}

summary_dir <- normalizePath(args[[1L]], mustWork = TRUE)
raw <- read.csv(
    file.path(summary_dir, "gpu_cv_raw_combined.csv"),
    stringsAsFactors = FALSE
)
runtime <- read.csv(
    file.path(summary_dir, "gpu_cv_runtime_summary.csv"),
    stringsAsFactors = FALSE
)
accelerator <- read.csv(
    file.path(summary_dir, "gpu_cv_cpu_accelerator_comparison.csv"),
    stringsAsFactors = FALSE
)

datasets <- c(
    "ccle", "cifar100", "gtex_v8", "metref", "retina", "tabula",
    "tcga_brca", "tcga_hnsc_methylation", "tcga_pan_cancer",
    "cbmc_citeseq", "prism", "nmr", "imagenet"
)
families <- c("plssvd", "simpls", "opls", "kernelpls")
backends <- c("cpu", "cuda")
workloads <- c("fit_predict", "cv")

if (!identical(sort(unique(raw$platform)), "linux_nvidia")) {
    stop("Figure 2C-D evidence must contain Linux/NVIDIA rows only.")
}
if (!setequal(unique(raw$dataset), datasets)) {
    stop("Figure 2C-D dataset coverage is incomplete or contains extras.")
}
if (!setequal(unique(raw$method), families) ||
        !setequal(unique(raw$backend), backends) ||
        !setequal(unique(raw$workload), workloads)) {
    stop("Figure 2C-D family, backend, or workload coverage is incomplete.")
}
if (any(raw$status != "success") || any(!is.finite(raw$elapsed_sec))) {
    stop("At least one Figure 2C-D worker failed or returned invalid timing.")
}

classification <- !is.na(raw$classifier)
if (any(raw$classifier[classification] != "lda")) {
    stop("Every classification row in Figure 2C-D must use LDA.")
}
if (any(tolower(raw$selection[classification]) != "accuracy")) {
    stop("Every classification row must report accuracy.")
}
if (any(tolower(raw$selection[!classification]) != "rmsd")) {
    stop("Every regression row must report RMSD.")
}

cell <- interaction(
    raw$dataset, raw$method, raw$backend, raw$workload,
    drop = TRUE
)
counts <- table(cell)
cell_dataset <- vapply(
    split(raw$dataset, cell),
    function(value) unique(value)[[1L]],
    character(1L)
)
expected <- ifelse(cell_dataset == "imagenet", 1L, 5L)
if (!identical(as.integer(counts[names(expected)]), as.integer(expected))) {
    stop("Repetition counts do not match five runs or one ImageNet run.")
}

cv <- raw[raw$workload == "cv", , drop = FALSE]
fold_group <- interaction(cv$dataset, drop = TRUE)
fold_counts <- vapply(
    split(cv$fold_signature, fold_group),
    function(value) length(unique(value)),
    integer(1L)
)
if (any(fold_counts != 1L)) {
    stop("Fold assignments differ across paired Figure 2C-D cells.")
}

if (any(runtime$status != "success")) {
    stop("At least one summarized Figure 2C-D cell is incomplete.")
}
if (any(!is.finite(accelerator$metric_difference))) {
    stop("At least one paired CPU/CUDA metric difference is unavailable.")
}

accuracy <- tolower(accelerator$selection_metric) == "accuracy"
rmsd <- tolower(accelerator$selection_metric) == "rmsd"
relative_rmsd <- abs(accelerator$metric_difference[rmsd]) /
    pmax(abs(accelerator$cpu_metric[rmsd]), .Machine$double.eps)
audit <- data.frame(
    check = c(
        "raw_rows", "successful_summary_cells", "lda_classification_rows",
        "regression_rows", "paired_fold_assignments",
        "maximum_accuracy_difference", "maximum_relative_rmsd_difference"
    ),
    value = c(
        nrow(raw), nrow(runtime), sum(classification), sum(!classification),
        length(fold_counts),
        max(abs(accelerator$metric_difference[accuracy]), na.rm = TRUE),
        max(relative_rmsd, na.rm = TRUE)
    ),
    stringsAsFactors = FALSE
)
write.csv(
    audit,
    file.path(summary_dir, "figure2_cv_lda_audit.csv"),
    row.names = FALSE
)
print(audit, row.names = FALSE)
