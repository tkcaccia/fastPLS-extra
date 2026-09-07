#!/usr/bin/env Rscript

options(stringsAsFactors = FALSE)

suppressPackageStartupMessages({
    library(ggplot2)
    library(patchwork)
    library(scales)
    library(jsonlite)
})

args <- commandArgs(trailingOnly = TRUE)
pkg_value <- if (length(args) >= 1L) args[[1L]] else Sys.getenv("FASTPLS_SOURCE_ROOT")
evidence_value <- Sys.getenv("FASTPLS_EVIDENCE_ROOT")
out_value <- if (length(args) >= 2L) args[[2L]] else
    Sys.getenv("FASTPLS_MANUSCRIPT_OUTPUT")
ikpls_panel_value <- Sys.getenv("FASTPLS_IKPLS_PANEL_SUMMARY")
ikpls_large_value <- Sys.getenv("FASTPLS_IKPLS_LARGE_DIR")
nmr_current_value <- Sys.getenv("FASTPLS_CURRENT_NMR_ROOT")
if (!nzchar(pkg_value) || !nzchar(evidence_value) || !nzchar(out_value) ||
        !nzchar(ikpls_panel_value) || !nzchar(ikpls_large_value) ||
        !nzchar(nmr_current_value)) {
    stop(
        "Set FASTPLS_SOURCE_ROOT, FASTPLS_EVIDENCE_ROOT, and ",
        "FASTPLS_MANUSCRIPT_OUTPUT (or pass source/output arguments), and ",
        "FASTPLS_IKPLS_PANEL_SUMMARY, FASTPLS_IKPLS_LARGE_DIR, and ",
        "FASTPLS_CURRENT_NMR_ROOT.",
        call. = FALSE
    )
}
pkg <- normalizePath(pkg_value, mustWork = TRUE)
evidence <- normalizePath(evidence_value, mustWork = TRUE)
out <- normalizePath(out_value, mustWork = FALSE)
ikpls_panel_path <- normalizePath(ikpls_panel_value, mustWork = TRUE)
ikpls_large_dir <- normalizePath(ikpls_large_value, mustWork = TRUE)
nmr_current <- normalizePath(nmr_current_value, mustWork = TRUE)
figdir <- file.path(out, "figures")
tabdir <- file.path(out, "tables")
dir.create(figdir, recursive = TRUE, showWarnings = FALSE)
dir.create(tabdir, recursive = TRUE, showWarnings = FALSE)

candidate <- file.path(evidence, "publication_results", "0.99.39",
                       "current_candidate_20260905")
optimized <- file.path(candidate, "final_optimized_20260906")
release <- file.path(evidence, "publication_results", "0.99.39", "current_release")

read_required <- function(path) {
    if (!file.exists(path)) stop("Missing required evidence: ", path)
    read.csv(path, check.names = FALSE)
}

save_plot <- function(plot, stem, width, height) {
    ggsave(file.path(figdir, paste0(stem, ".png")), plot,
           width = width, height = height, units = "in", dpi = 320,
           bg = "white")
    ggsave(file.path(figdir, paste0(stem, ".pdf")), plot,
           width = width, height = height, units = "in", device = cairo_pdf,
           bg = "white")
}

# Copy the compact current-release numerical-validation summaries used by the
# Supplement. Detailed prefix-level records remain with the benchmark archive.
validation_sources <- c(
    simpls_exact_reference_case_summary = file.path(
        release, "simpls_exact", "simpls_exact_reference_case_summary.csv"
    ),
    rsvd_qualification_summary = file.path(
        release, "rsvd_qualification", "rsvd_qualification_summary.csv"
    ),
    opls_kernel_estimator_validation_summary = file.path(
        release, "opls_kernel_estimator",
        "opls_kernel_estimator_validation_summary.csv"
    ),
    simpls_multidataset_ablation_effects = file.path(
        release, "simpls_ablation", "simpls_multidataset_ablation_effects.csv"
    )
)
for (name in names(validation_sources)) {
    source <- validation_sources[[name]]
    if (!file.exists(source)) stop("Missing current validation evidence: ", source)
    file.copy(source, file.path(tabdir, paste0(name, ".csv")), overwrite = TRUE)
}

theme_publication <- function(base_size = 9) {
    theme_minimal(base_size = base_size, base_family = "Helvetica") +
        theme(
            plot.title = element_text(face = "bold", size = rel(1.12), hjust = 0),
            plot.subtitle = element_text(size = rel(0.88), colour = "grey25"),
            axis.title = element_text(face = "bold"),
            axis.text = element_text(colour = "grey15"),
            panel.grid.minor = element_blank(),
            legend.title = element_text(face = "bold"),
            plot.margin = margin(6, 8, 6, 8)
        )
}

dataset_ids <- c(
    "ccle", "cifar100", "gtex_v8", "metref", "retina", "tabula",
    "tcga_brca", "tcga_hnsc_methylation", "tcga_pan_cancer"
)
dataset_labels <- c(
    ccle = "CCLE", cifar100 = "CIFAR-100", gtex_v8 = "GTEx v8",
    metref = "MetRef", retina = "Retina", tabula = "Tabula\nMuris",
    tcga_brca = "TCGA-\nBRCA", tcga_hnsc_methylation = "TCGA-HNSC\nmethyl.",
    tcga_pan_cancer = "TCGA Pan-\nCancer"
)

# Figure 1: current public fastPLS rows plus retained independent implementations.
argmax <- read_required(file.path(
    optimized, "external_current_argmax_canonical_mem",
    "current_simpls_argmax_summary.csv"
))
lda <- read_required(file.path(
    optimized, "external_current_lda_canonical_mem",
    "current_simpls_lda_summary.csv"
))
external <- read_required(file.path(
    release, "r_package_panel", "pls_package_comparison_summary.csv"
))
ikpls <- read_required(ikpls_panel_path)
ikpls_task_ids <- c(dataset_ids, "cbmc_citeseq", "prism")
ikpls_panel <- ikpls[
    ikpls$implementation == "IKPLS_numpy_alg2" &
        ikpls$dataset %in% ikpls_task_ids,
]
missing_ikpls <- setdiff(ikpls_task_ids, ikpls_panel$dataset)
if (length(missing_ikpls)) {
    stop("IKPLS panel is incomplete: ", paste(missing_ikpls, collapse = ", "))
}
if (anyDuplicated(ikpls_panel$dataset)) {
    stop("IKPLS panel contains duplicated dataset summaries.")
}
if (any(ikpls_panel$repetitions < 10L)) {
    stop("IKPLS panel contains fewer than ten successful repetitions.")
}
matched_counts <- merge(
    argmax[, c("dataset", "ncomp")],
    ikpls_panel[, c("dataset", "ncomp")],
    by = "dataset", suffixes = c("_fastpls", "_ikpls")
)
if (any(matched_counts$ncomp_fastpls != matched_counts$ncomp_ikpls)) {
    stop("IKPLS and fastPLS component counts differ in Figure 1.")
}
write.csv(
    ikpls_panel,
    file.path(tabdir, "ikpls_complete_panel_summary.csv"),
    row.names = FALSE, na = ""
)

ikpls_standard_status <- data.frame(
    dataset = ikpls_panel$dataset,
    task_type = ikpls_panel$task_type,
    ncomp = ikpls_panel$ncomp,
    status = "success",
    metric_name = ifelse(ikpls_panel$task_type == "classification",
                         "accuracy", "RMSD"),
    metric_value = ifelse(ikpls_panel$task_type == "classification",
                          ikpls_panel$accuracy, ikpls_panel$rmsd),
    top5_accuracy = ikpls_panel$top5_accuracy,
    median_total_sec = ikpls_panel$median_total_sec,
    iqr_total_sec = ikpls_panel$iqr_total_sec,
    peak_rss_mib = ikpls_panel$median_peak_rss_mib,
    incremental_peak_rss_mib = ikpls_panel$median_incremental_peak_rss_mib,
    repetitions = ikpls_panel$repetitions,
    error = "",
    stringsAsFactors = FALSE
)
large_paths <- c(
    file.path(ikpls_large_dir, "nmr_ikpls_f32_n50.csv"),
    file.path(ikpls_large_dir, paste0(
        "imagenet_ikpls_f32_n", c(100, 200, 500, 1000), ".csv"
    ))
)
ikpls_large <- do.call(rbind, lapply(large_paths, read_required))
ikpls_large_status <- data.frame(
    dataset = ikpls_large$dataset,
    task_type = ifelse(ikpls_large$dataset == "nmr", "regression",
                       "classification"),
    ncomp = ikpls_large$ncomp,
    status = ikpls_large$status,
    metric_name = ifelse(ikpls_large$dataset == "nmr", "RMSD", "accuracy"),
    metric_value = ikpls_large$top1_accuracy_or_rmsd,
    top5_accuracy = ikpls_large$top5_accuracy,
    median_total_sec = ikpls_large$total_sec,
    iqr_total_sec = NA_real_,
    peak_rss_mib = ikpls_large$peak_rss_mib,
    incremental_peak_rss_mib = ikpls_large$incremental_peak_rss_mib,
    repetitions = 1L,
    error = ikpls_large$error,
    stringsAsFactors = FALSE
)
write.csv(
    rbind(ikpls_standard_status, ikpls_large_status),
    file.path(tabdir, "ikpls_all_dataset_status.csv"),
    row.names = FALSE, na = ""
)

fast_row <- function(data, label) {
    data.frame(
        dataset = data$dataset,
        display = label,
        accuracy = data$median_accuracy,
        time_sec = data$median_time_sec,
        peak_rss_mib = ifelse(is.na(data$median_peak_rss_mib),
                              data$median_baseline_rss_mib,
                              data$median_peak_rss_mib),
        memory_lower_bound = is.na(data$median_peak_rss_mib),
        ncomp = data$ncomp,
        repetitions = data$successful,
        precision = "float32",
        stringsAsFactors = FALSE
    )
}

comparison <- rbind(
    fast_row(argmax, "fastPLS SIMPLS / argmax"),
    fast_row(lda, "fastPLS SIMPLS / LDA")
)

external_map <- c(
    pls_simpls_fit = "pls / SIMPLS",
    plsgenomics_pls_lda = "plsgenomics / PLS-LDA",
    mdatools_plsda_or_pls = "mdatools / PLS-DA",
    plsdepot_simpls = "plsdepot / SIMPLS",
    pcv_simpls = "pcv / SIMPLS",
    chemometrics_pls_eigen = "chemometrics / PLS eigen",
    mixOmics_plsda = "mixOmics / PLS-DA",
    spls_splsda = "spls / sPLS-DA"
)
ext <- external[
    external$dataset %in% dataset_ids & external$method_id %in% names(external_map),
]
if (nrow(ext)) {
    ext_rows <- data.frame(
        dataset = ext$dataset,
        display = unname(external_map[ext$method_id]),
        accuracy = ext$median_accuracy,
        time_sec = ext$median_time_ms / 1000,
        peak_rss_mib = ext$median_peak_host_rss_mb,
        memory_lower_bound = FALSE,
        ncomp = ext$ncomp_requested,
        repetitions = ext$reps_ok,
        precision = ext$execution_precision,
        stringsAsFactors = FALSE
    )
    comparison <- rbind(comparison, ext_rows)
}

# IKPLS uses the same dataset-specific component counts as current fastPLS.
ik <- ikpls_panel[ikpls_panel$dataset %in% dataset_ids, ]
if (nrow(ik)) {
    ik_rows <- data.frame(
        dataset = ik$dataset,
        display = "IKPLS / algorithm 2",
        accuracy = ik$accuracy,
        time_sec = ik$median_total_sec,
        peak_rss_mib = ik$median_peak_rss_mib,
        memory_lower_bound = FALSE,
        ncomp = ik$ncomp,
        repetitions = ik$repetitions,
        precision = ik$precision,
        stringsAsFactors = FALSE
    )
    comparison <- rbind(comparison, ik_rows)
}

display_order <- c(
    "fastPLS SIMPLS / argmax", "fastPLS SIMPLS / LDA",
    "IKPLS / algorithm 2",
    "pls / SIMPLS", "plsgenomics / PLS-LDA",
    "mdatools / PLS-DA", "plsdepot / SIMPLS", "pcv / SIMPLS",
    "chemometrics / PLS eigen", "mixOmics / PLS-DA", "spls / sPLS-DA"
)
grid <- expand.grid(dataset = dataset_ids, display = display_order,
                    stringsAsFactors = FALSE)
comparison <- merge(grid, comparison, by = c("dataset", "display"), all.x = TRUE)
comparison$dataset <- factor(comparison$dataset, levels = dataset_ids,
                             labels = unname(dataset_labels[dataset_ids]))
comparison$display <- factor(comparison$display, levels = rev(display_order))
write.csv(comparison, file.path(tabdir, "figure1_independent_implementation_data.csv"),
          row.names = FALSE, na = "")

heat_panel <- function(data, value, title, subtitle, palette, label_fun,
                       trans = "identity", limits = NULL) {
    data$plot_value <- data[[value]]
    data$cell_label <- ifelse(is.na(data$plot_value), "NE", label_fun(data))
    ggplot(data, aes(dataset, display, fill = plot_value)) +
        geom_tile(colour = "white", linewidth = 0.45) +
        geom_text(aes(label = cell_label), size = 2.35, colour = "grey10") +
        scale_fill_gradientn(colours = palette, na.value = "grey88",
                             trans = trans, limits = limits, oob = squish) +
        labs(title = title, subtitle = subtitle, x = NULL, y = NULL,
             fill = NULL) +
        theme_publication(8.5) +
        theme(axis.text.x = element_text(face = "bold", size = 7.2),
              axis.text.y = element_text(size = 7.4),
              panel.grid = element_blank(), legend.position = "right")
}

p1a <- heat_panel(
    comparison, "accuracy", "A  Predictive accuracy",
    "Outer-test accuracy; NE denotes not evaluated",
    c("#edf5fb", "#77b5d9", "#084c8d"),
    function(d) ifelse(is.na(d$accuracy), "NE", sprintf("%.3f", d$accuracy)),
    limits = c(0.65, 1)
)
p1b <- heat_panel(
    comparison, "time_sec", "B  Total fitting plus prediction time",
    "Seconds; labels are medians from successful isolated runs",
    c("#fff4de", "#fdae6b", "#b30000"),
    function(d) ifelse(is.na(d$time_sec), "NE",
                       ifelse(d$time_sec < 0.1, sprintf("%.3f", d$time_sec),
                              ifelse(d$time_sec < 10, sprintf("%.2f", d$time_sec),
                                     sprintf("%.0f", d$time_sec)))),
    trans = "log10"
)
p1c <- heat_panel(
    comparison, "peak_rss_mib", "C  Peak host memory",
    "Absolute process RSS (MiB); < marks a baseline lower bound",
    c("#eef8ea", "#74c476", "#005a32"),
    function(d) ifelse(is.na(d$peak_rss_mib), "NE",
                       paste0(ifelse(d$memory_lower_bound, "<", ""),
                              sprintf("%.0f", d$peak_rss_mib))),
    trans = "log10"
)
figure1 <- (p1a / p1b / p1c) +
    plot_annotation(
        title = "Single-CPU SIMPLS classification workflows",
        subtitle = paste(
            "One effective BLAS thread; current fastPLS and IKPLS use the same",
            "dataset-specific component counts and ten isolated repetitions."
        ),
        theme = theme(plot.title = element_text(face = "bold", size = 14),
                      plot.subtitle = element_text(size = 9))
    )
save_plot(figure1, "figure1_independent_implementations", 9.3, 12.2)

# Figure 2: every paired CPU/accelerator runtime ratio is shown, irrespective
# of numerical agreement. Agreement and metric values remain in the table.
cuda <- read_required(file.path(optimized, "selected_backend_cuda",
                                "matched_cuda_summary.csv"))
metal <- read_required(file.path(optimized, "selected_backend_metal",
                                 "matched_metal_summary.csv"))

paired_ratios <- function(data, accelerator, platform) {
    cpu <- data[data$backend == "cpu", ]
    acc <- data[data$backend == accelerator, ]
    keys <- c("dataset", "method", "ncomp")
    paired <- merge(cpu, acc, by = keys, suffixes = c("_cpu", "_accelerator"))
    data.frame(
        platform = platform,
        dataset = paired$dataset,
        method = paired$method,
        ncomp = paired$ncomp,
        cpu_time_sec = paired$median_total_sec_cpu,
        accelerator_time_sec = paired$median_total_sec_accelerator,
        ratio = paired$median_total_sec_cpu / paired$median_total_sec_accelerator,
        cpu_incremental_rss_mib = paired$median_incremental_rss_mb_cpu,
        accelerator_incremental_rss_mib =
            paired$median_incremental_rss_mb_accelerator,
        memory_ratio = paired$median_incremental_rss_mb_accelerator /
            paired$median_incremental_rss_mb_cpu,
        cpu_metric = paired$median_metric_cpu,
        accelerator_metric = paired$median_metric_accelerator,
        metric_difference = paired$median_metric_accelerator - paired$median_metric_cpu,
        execution_route = paired$execution_route_accelerator,
        stringsAsFactors = FALSE
    )
}

ratios <- rbind(paired_ratios(cuda, "cuda", "CUDA"),
                paired_ratios(metal, "metal", "Metal"))
write.csv(ratios, file.path(tabdir, "figure2_backend_runtime_ratios.csv"),
          row.names = FALSE)
backend_dataset_order <- unique(c(dataset_ids, "cbmc_citeseq", "prism"))
backend_labels <- c(dataset_labels, cbmc_citeseq = "CBMC CITE-seq", prism = "PRISM")
method_labels <- c(plssvd = "PLS-SVD", simpls = "SIMPLS",
                   opls = "OPLS", kernelpls = "kernel PLS")

ratio_panel <- function(data, platform) {
    data <- data[data$platform == platform, ]
    data$dataset <- factor(data$dataset, levels = rev(backend_dataset_order),
                           labels = rev(unname(backend_labels[backend_dataset_order])))
    data$method <- factor(data$method, levels = names(method_labels),
                          labels = unname(method_labels))
    data$log_ratio <- log2(data$ratio)
    ggplot(data, aes(method, dataset, fill = log_ratio)) +
        geom_tile(colour = "white", linewidth = 0.6) +
        geom_text(aes(label = sprintf("%.2fx", ratio)), size = 2.6) +
        scale_fill_gradient2(low = "#bd2d2d", mid = "#f7f7f7",
                             high = "#2166ac", midpoint = 0,
                             name = paste0("log2 CPU/", platform)) +
        labs(title = paste0(platform, " runtime ratio"),
             subtitle = "CPU/accelerator; values above 1 favour the accelerator",
             x = NULL, y = NULL) +
        theme_publication(8.5) +
        theme(axis.text.x = element_text(angle = 28, hjust = 1),
              panel.grid = element_blank(), legend.position = "bottom")
}

memory_ratio_panel <- function(data, platform) {
    data <- data[data$platform == platform & is.finite(data$memory_ratio) &
                     data$memory_ratio > 0, ]
    data$dataset <- factor(data$dataset, levels = rev(backend_dataset_order),
                           labels = rev(unname(backend_labels[backend_dataset_order])))
    data$method <- factor(data$method, levels = names(method_labels),
                          labels = unname(method_labels))
    data$log_ratio <- log2(data$memory_ratio)
    ggplot(data, aes(method, dataset, fill = log_ratio)) +
        geom_tile(colour = "white", linewidth = 0.6) +
        geom_text(aes(label = sprintf("%.2fx", memory_ratio)), size = 2.6) +
        scale_fill_gradient2(low = "#2166ac", mid = "#f7f7f7",
                             high = "#b2182b", midpoint = 0,
                             name = paste0("log2 ", platform, "/CPU")) +
        labs(title = paste0(platform, " incremental host-memory ratio"),
             subtitle = "Accelerator/CPU; values below 1 favour the accelerator",
             x = NULL, y = NULL) +
        theme_publication(8.5) +
        theme(axis.text.x = element_text(angle = 28, hjust = 1),
              panel.grid = element_blank(), legend.position = "bottom")
}

figure2 <- (ratio_panel(ratios, "CUDA") + ratio_panel(ratios, "Metal")) /
    (memory_ratio_panel(ratios, "CUDA") + memory_ratio_panel(ratios, "Metal")) +
    plot_layout(guides = "collect") +
    plot_annotation(
        title = "Runtime effects of CUDA and Metal across the benchmark panel",
        subtitle = paste(
            "All completed paired tests are shown. CPU comparisons are made within each workstation;",
            "numerical metrics and execution residency are reported separately."
        ),
        theme = theme(plot.title = element_text(face = "bold", size = 13),
                      plot.subtitle = element_text(size = 9))
    ) & theme(legend.position = "bottom")
save_plot(figure2, "figure2_backend_runtime", 10.5, 12.0)

# Figure 3: fixed 165-component NMR comparison and current spectra.
read_many <- function(paths) do.call(rbind, lapply(paths, read_required))
nmr_run <- function(paths, implementation, workstation) {
    value <- read_many(paths)
    data.frame(
        implementation = implementation,
        family = value$family[[1L]],
        backend = value$backend[[1L]],
        precision = value$precision[[1L]],
        ncomp = value$ncomp[[1L]],
        total_time_sec = median(value$total_time_sec),
        time_q1_sec = unname(quantile(value$total_time_sec, 0.25)),
        time_q3_sec = unname(quantile(value$total_time_sec, 0.75)),
        repetitions = nrow(value),
        RMSD = median(value$RMSD),
        Q2 = median(value$Q2),
        MAE = median(value$MAE),
        workstation = workstation,
        stringsAsFactors = FALSE
    )
}
nmr_summary <- do.call(rbind, list(
    nmr_run(
        file.path(nmr_current, "mac", "fixed165_plssvd_cpu_rsvd.csv"),
        "PLS-SVD / CPU (Mac)", "Apple M3"
    ),
    nmr_run(
        file.path(nmr_current, "linux",
                  paste0("fixed165_plssvd_cuda_fresh", 1:3, ".csv")),
        "PLS-SVD / CUDA", "Intel i7-13700 + RTX 5060 Ti"
    ),
    nmr_run(
        file.path(nmr_current, "mac",
                  "fixed165_plssvd_metal_rsvd_final.csv"),
        "PLS-SVD / Metal", "Apple M3"
    ),
    nmr_run(
        file.path(nmr_current, "linux",
                  paste0("fixed165_simpls_cpu_fresh", 1:3, ".csv")),
        "SIMPLS / CPU (Linux)", "Intel i7-13700"
    ),
    nmr_run(
        file.path(nmr_current, "linux",
                  paste0("fixed165_simpls_cuda_fresh", 1:3, ".csv")),
        "SIMPLS / CUDA", "Intel i7-13700 + RTX 5060 Ti"
    ),
    nmr_run(
        file.path(nmr_current, "mac", "fixed165_simpls_cpu_rsvd.csv"),
        "SIMPLS / CPU (Mac)", "Apple M3"
    ),
    nmr_run(
        file.path(nmr_current, "mac",
                  paste0("fixed165_simpls_metal_onecmd_fresh", 1:3, ".csv")),
        "SIMPLS / Metal", "Apple M3"
    )
))

deposited_file <- file.path(
    release, "nmr", "deposited", "deposited_plssvd_cpu_irlba_k165_rep1.csv"
)
deposited <- read_required(deposited_file)
deposited_row <- data.frame(
    family = "plssvd", backend = "deposited", precision = deposited$precision,
    ncomp = deposited$ncomp, total_time_sec = deposited$total_time_sec,
    time_q1_sec = deposited$total_time_sec,
    time_q3_sec = deposited$total_time_sec,
    repetitions = 1L,
    RMSD = deposited$RMSD, Q2 = deposited$Q2, MAE = deposited$MAE,
    implementation = "Deposited PLS-SVD / CPU",
    workstation = "Intel i7-13700",
    stringsAsFactors = FALSE
)
nmr_summary <- rbind(nmr_summary, deposited_row)

monitor_value <- function(path) {
    item <- fromJSON(path)$measurements
    data.frame(
        peak_rss_mib = item$peak_rss_mib[[1L]],
        incremental_rss_mib = item$incremental_rss_mib[[1L]],
        peak_gpu_mib = item$peak_gpu_mib[[1L]],
        incremental_gpu_mib = item$incremental_gpu_mib[[1L]]
    )
}
memory_paths <- c(
    "PLS-SVD / CPU (Mac)" = file.path(
        nmr_current, "mac", "memory_plssvd_cpu_final", "summary.json"
    ),
    "SIMPLS / CPU (Mac)" = file.path(
        nmr_current, "mac", "memory_simpls_cpu_final", "summary.json"
    ),
    "PLS-SVD / CUDA" = file.path(
        nmr_current, "linux", "memory", "plssvd_cuda", "summary.json"
    ),
    "SIMPLS / CUDA" = file.path(
        nmr_current, "linux", "memory", "cuda", "summary.json"
    ),
    "PLS-SVD / Metal" = file.path(
        nmr_current, "mac", "memory_plssvd_metal_final", "summary.json"
    ),
    "SIMPLS / Metal" = file.path(
        nmr_current, "mac", "memory_simpls_metal_onecmd_final", "summary.json"
    ),
    "SIMPLS / CPU (Linux)" = file.path(
        nmr_current, "linux", "memory", "cpu", "summary.json"
    )
)
memory_rows <- lapply(names(memory_paths), function(implementation) {
        path <- memory_paths[[implementation]]
        value <- monitor_value(path)
        value$implementation <- implementation
        value
})
memory <- do.call(rbind, memory_rows)
memory <- rbind(memory, data.frame(
    peak_rss_mib = deposited$process_peak_rss_mb,
    incremental_rss_mib = deposited$process_peak_rss_mb - deposited$baseline_rss_mb,
    peak_gpu_mib = NA_real_, incremental_gpu_mib = NA_real_,
    implementation = "Deposited PLS-SVD / CPU"
))
nmr_summary <- merge(nmr_summary, memory, by = "implementation", all.x = TRUE)
write.csv(nmr_summary, file.path(tabdir, "figure3_nmr_fixed165_summary.csv"),
          row.names = FALSE)

implementation_order <- c(
    "Deposited PLS-SVD / CPU", "PLS-SVD / CPU (Mac)", "PLS-SVD / CUDA",
    "PLS-SVD / Metal", "SIMPLS / CPU (Linux)", "SIMPLS / CUDA",
    "SIMPLS / CPU (Mac)", "SIMPLS / Metal"
)
nmr_summary$implementation <- factor(nmr_summary$implementation,
                                     levels = implementation_order)
cols <- c(
    "Deposited PLS-SVD / CPU" = "#606060",
    "PLS-SVD / CPU (Mac)" = "#4878A8",
    "PLS-SVD / CUDA" = "#1B9E77", "PLS-SVD / Metal" = "#D95F02",
    "SIMPLS / CPU (Linux)" = "#7B6FD0", "SIMPLS / CUDA" = "#2AA198",
    "SIMPLS / CPU (Mac)" = "#8E79C6",
    "SIMPLS / Metal" = "#E69F00"
)

nmr_bar <- function(value, title, ylab, log_scale = FALSE, digits = 3) {
    label_data <- nmr_summary
    label_data$plot_label <- if (identical(value, "RMSD")) {
        formatC(label_data[[value]], format = "e", digits = 2)
    } else {
        formatC(label_data[[value]], format = "f", digits = digits)
    }
    p <- ggplot(nmr_summary, aes(implementation, .data[[value]],
                                 colour = implementation, fill = implementation))
    if (log_scale) {
        p <- p +
            geom_segment(aes(xend = implementation, y = 0.2,
                             yend = .data[[value]]), linewidth = 1.1) +
            geom_point(size = 3.2) +
            geom_errorbar(aes(ymin = time_q1_sec, ymax = time_q3_sec),
                          width = 0.22, linewidth = 0.45)
    } else {
        p <- p + geom_col(width = 0.72)
    }
    p <- p +
        geom_text(data = label_data, aes(label = plot_label),
                  angle = 90, hjust = -0.18, size = 2.4, colour = "grey12") +
        scale_fill_manual(values = cols, guide = "none") +
        scale_colour_manual(values = cols, guide = "none") +
        labs(title = title, x = NULL, y = ylab) +
        theme_publication(8) +
        theme(axis.text.x = element_text(angle = 45, hjust = 1, size = 6.7)) +
        coord_cartesian(clip = "off")
    if (log_scale) p <- p + scale_y_log10(limits = c(0.18, NA),
                                           expand = expansion(mult = c(0.02, 0.24)))
    else p <- p + scale_y_continuous(expand = expansion(mult = c(0.02, 0.22)))
    p
}

p3a <- nmr_bar("total_time_sec", "A  Fitting plus prediction", "Seconds",
               log_scale = TRUE, digits = 2)
p3b <- nmr_bar("RMSD", "B  Held-out prediction error", "RMSD",
               digits = 6)

mem_long <- rbind(
    data.frame(implementation = nmr_summary$implementation,
               memory = nmr_summary$incremental_rss_mib, type = "Host RSS increment"),
    data.frame(implementation = nmr_summary$implementation,
               memory = nmr_summary$incremental_gpu_mib, type = "CUDA device increment")
)
p3c <- ggplot(mem_long[is.finite(mem_long$memory), ],
              aes(implementation, memory, fill = type)) +
    geom_col(position = position_dodge(width = 0.8), width = 0.72) +
    scale_fill_manual(values = c("Host RSS increment" = "#4C78A8",
                                 "CUDA device increment" = "#F58518")) +
    labs(title = "C  Incremental peak memory", x = NULL, y = "MiB", fill = NULL) +
    theme_publication(8) +
    theme(axis.text.x = element_text(angle = 45, hjust = 1, size = 6.7),
          legend.position = "top")

prediction_files <- c(
    "Deposited PLS-SVD / CPU" = file.path(
        release, "nmr", "deposited",
        "deposited_plssvd_cpu_irlba_k165_rep1_prediction.rds"
    ),
    "PLS-SVD / CPU (Mac)" = file.path(
        nmr_current, "mac", "fixed165_plssvd_cpu_rsvd_prediction.rds"
    ),
    "SIMPLS / CPU (Mac)" = file.path(
        nmr_current, "mac", "fixed165_simpls_cpu_rsvd_prediction.rds"
    ),
    "SIMPLS / CUDA" = file.path(
        nmr_current, "linux", "fixed165_simpls_cuda_rsvd_prediction.rds"
    ),
    "SIMPLS / Metal" = file.path(
        nmr_current, "mac",
        "fixed165_simpls_metal_onecmd_final_prediction.rds"
    )
)
prediction_objects <- lapply(prediction_files, readRDS)
per_sample <- do.call(rbind, lapply(names(prediction_objects), function(name) {
    value <- prediction_objects[[name]]
    rmsd <- value$per_sample_rmsd
    if (is.null(rmsd)) rmsd <- value$per_sample_RMSD
    data.frame(implementation = name, rmsd = as.numeric(rmsd))
}))
p3d <- ggplot(per_sample, aes(implementation, rmsd, fill = implementation)) +
    geom_violin(scale = "width", trim = TRUE, alpha = 0.75, colour = "grey25") +
    geom_boxplot(width = 0.15, outlier.size = 0.35, fill = "white") +
    scale_fill_manual(values = cols, guide = "none") +
    labs(title = "D  Per-spectrum prediction error", x = NULL, y = "RMSD") +
    theme_publication(8) +
    theme(axis.text.x = element_text(angle = 35, hjust = 1, size = 7))

simpls_prediction <- prediction_objects[["SIMPLS / CPU (Mac)"]]
rmsd <- simpls_prediction$per_sample_rmsd
sample_index <- which.min(abs(rmsd - median(rmsd)))
ppm <- suppressWarnings(as.numeric(colnames(simpls_prediction$observed)))
if (any(!is.finite(ppm))) ppm <- seq_len(ncol(simpls_prediction$observed))
spectrum <- rbind(
    data.frame(ppm = ppm, intensity = simpls_prediction$observed[sample_index, ],
               series = "Observed"),
    data.frame(ppm = ppm, intensity = simpls_prediction$predicted[sample_index, ],
               series = "Predicted")
)
spectrum_cols <- c(Observed = "#202020", Predicted = "#D55E00")
spectrum_panel <- function(data, title, limits) {
    ggplot(data, aes(ppm, intensity, colour = series)) +
        geom_line(linewidth = 0.35, alpha = 0.9) +
        scale_colour_manual(values = spectrum_cols) +
        scale_x_reverse() +
        coord_cartesian(xlim = sort(limits)) +
        labs(title = title, x = "Chemical shift (ppm)", y = "Intensity",
             colour = NULL) +
        theme_publication(8) +
        theme(legend.position = "top")
}
p3e <- spectrum_panel(spectrum, "E  Representative held-out spectrum",
                      c(12, 0))
p3f <- spectrum_panel(spectrum, "F  Expanded spectral region", c(1.7, 0.5))

time_for <- function(label) {
    nmr_summary$total_time_sec[as.character(nmr_summary$implementation) == label]
}
cuda_simpls_speedup <-
    time_for("SIMPLS / CPU (Linux)") / time_for("SIMPLS / CUDA")
metal_simpls_ratio <-
    time_for("SIMPLS / CPU (Mac)") / time_for("SIMPLS / Metal")
figure3 <- ((p3a | p3b) / (p3c | p3d) / (p3e | p3f)) +
    plot_annotation(
        title = "NMR prediction at a common 165-component workload",
        subtitle = paste0(
            "Matched SIMPLS CPU/CUDA speed-up: ",
            sprintf("%.1fx", cuda_simpls_speedup),
            "; matched Mac CPU/Metal runtime ratio: ",
            sprintf("%.2fx", metal_simpls_ratio),
            ". Values above one favour the accelerator."
        ),
        theme = theme(plot.title = element_text(face = "bold", size = 13),
                      plot.subtitle = element_text(size = 8.7))
    )
save_plot(figure3, "figure3_nmr_fixed165", 10.5, 12.0)

# Supplementary NMR component-selection curves.
selection_paths <- c(
    plssvd = file.path(optimized, "nmr_selection_cpu_plssvd_final",
                       "nmr_component_selection_summary.csv"),
    simpls = file.path(optimized, "nmr_selection_cpu_simpls_final",
                       "nmr_component_selection_summary.csv")
)
selection <- do.call(rbind, lapply(names(selection_paths), function(family) {
    value <- read_required(selection_paths[[family]])
    value$family <- family
    value
}))
decision <- do.call(rbind, lapply(names(selection_paths), function(family) {
    path <- file.path(dirname(selection_paths[[family]]),
                      "nmr_component_selection_decision.csv")
    value <- read_required(path)
    value$family <- family
    value
}))
write.csv(selection, file.path(tabdir, "supplement_nmr_component_path.csv"),
          row.names = FALSE)
write.csv(decision, file.path(tabdir, "supplement_nmr_component_decision.csv"),
          row.names = FALSE)

mean_col <- intersect(c("RMSD_mean", "mean_validation_RMSD", "mean_rmsd", "mean_RMSD"),
                      names(selection))[[1L]]
se_col <- intersect(c("RMSD_se", "se_validation_RMSD", "se_rmsd", "se_RMSD"),
                    names(selection))[[1L]]
ncomp_col <- intersect(c("ncomp", "components"), names(selection))[[1L]]
selection$family_label <- factor(selection$family,
                                 levels = c("plssvd", "simpls"),
                                 labels = c("PLS-SVD", "SIMPLS"))
pS1 <- ggplot(selection,
             aes(.data[[ncomp_col]], .data[[mean_col]], colour = family_label)) +
    geom_errorbar(aes(ymin = .data[[mean_col]] - .data[[se_col]],
                      ymax = .data[[mean_col]] + .data[[se_col]]),
                  width = 2, alpha = 0.5) +
    geom_line(linewidth = 0.65) +
    geom_point(size = 1.8) +
    scale_colour_manual(values = c("PLS-SVD" = "#4878A8", "SIMPLS" = "#D55E00")) +
    labs(title = "Training-only component selection for NMR prediction",
         subtitle = "Mean validation RMSD and standard error across five paired splits",
         x = "Number of components", y = "Validation RMSD", colour = NULL) +
    theme_publication(9) + theme(legend.position = "top")
save_plot(pS1, "figureS1_nmr_component_selection", 7.2, 4.8)

# Current fastPLS 0.99.39 ImageNet/DINOv2 stress test. The two files each
# describe one maximal fit and its requested prefix path, so total time and
# memory are shown once per classifier rather than repeated as independent fits.
image_dir <- file.path(optimized, "imagenet_current_final8")
image_files <- file.path(
    image_dir,
    paste0("imagenet_current_0.99.39_", c("argmax", "lda"), ".csv")
)
if (all(file.exists(image_files))) {
    image_data <- do.call(rbind, lapply(image_files, read_required))
    if (!all(image_data$status == "success") ||
        !all(image_data$loaded_package_version == "0.99.39")) {
        stop("Current ImageNet evidence contains failures or a package mismatch")
    }
    if (!all(image_data$fit_residency == "resident CUDA") ||
        !all(image_data$prediction_residency == "cuda_resident")) {
        stop("Current ImageNet evidence is not the required resident CUDA route")
    }
    image_data$classifier_label <- factor(
        toupper(image_data$classifier), levels = c("ARGMAX", "LDA")
    )
    write.csv(image_data,
              file.path(tabdir, "figure4_imagenet_current.csv"),
              row.names = FALSE, na = "")

    metric_long <- rbind(
        data.frame(ncomp = image_data$ncomp_requested,
                   classifier = image_data$classifier_label,
                   metric = "Top-1 accuracy", value = image_data$top1_accuracy),
        data.frame(ncomp = image_data$ncomp_requested,
                   classifier = image_data$classifier_label,
                   metric = "Top-5 accuracy", value = image_data$top5_accuracy)
    )
    p4a <- ggplot(metric_long,
                  aes(ncomp, value, colour = classifier, linetype = metric)) +
        geom_line(linewidth = 0.75) +
        geom_point(size = 1.8) +
        scale_colour_manual(values = c(ARGMAX = "#1676b8", LDA = "#d95f02")) +
        scale_linetype_manual(values = c("Top-1 accuracy" = "solid",
                                         "Top-5 accuracy" = "22")) +
        scale_x_continuous(breaks = seq(100, 1000, 100)) +
        scale_y_continuous(labels = label_percent(accuracy = 1),
                           limits = c(0.6, 1.0)) +
        labs(title = "A  Predictive accuracy", x = "Requested components",
             y = "Held-out accuracy", colour = "Classifier",
             linetype = "Metric") +
        theme_publication(9) +
        theme(axis.text.x = element_text(angle = 45, hjust = 1))

    run_summary <- image_data[!duplicated(image_data$classifier), ]
    timing_long <- rbind(
        data.frame(classifier = run_summary$classifier_label,
                   stage = "Fit plus primary prediction",
                   seconds = run_summary$fit_predict_time_sec),
        data.frame(classifier = run_summary$classifier_label,
                   stage = "Additional top-5 scoring",
                   seconds = run_summary$top5_prediction_time_sec)
    )
    p4b <- ggplot(timing_long,
                  aes(classifier, seconds, fill = stage)) +
        geom_col(width = 0.62) +
        geom_text(aes(label = sprintf("%.1f", seconds)),
                  position = position_stack(vjust = 0.5), size = 3) +
        scale_fill_manual(values = c("Fit plus primary prediction" = "#80b1d3",
                                     "Additional top-5 scoring" = "#fdb462")) +
        labs(title = "B  End-to-end time", x = NULL, y = "Seconds",
             fill = "Stage") +
        theme_publication(9)

    memory_long <- rbind(
        data.frame(classifier = run_summary$classifier_label,
                   memory = "Host RSS after fit", mib = run_summary$rss_after_fit_mb),
        data.frame(classifier = run_summary$classifier_label,
                   memory = "GPU after top-5", mib = run_summary$gpu_after_top5_mb)
    )
    p4c <- ggplot(memory_long,
                  aes(classifier, mib / 1024, fill = memory)) +
        geom_col(position = position_dodge(width = 0.7), width = 0.62) +
        geom_text(aes(label = sprintf("%.1f", mib / 1024)),
                  position = position_dodge(width = 0.7), vjust = -0.3,
                  size = 2.8) +
        scale_fill_manual(values = c("Host RSS after fit" = "#66c2a5",
                                     "GPU after top-5" = "#8da0cb")) +
        scale_y_continuous(expand = expansion(mult = c(0, 0.12))) +
        labs(title = "C  Recorded memory", x = NULL, y = "GiB", fill = NULL) +
        theme_publication(9)

    figure4 <- (p4a | p4b | p4c) +
        plot_annotation(
            title = "Million-sample ImageNet/DINOv2 SIMPLS stress test",
            subtitle = paste(
                "fastPLS 0.99.39, float32, resident CUDA fitting and prediction;",
                "1,000,000 training and 281,167 held-out embeddings"
            ),
            theme = theme(plot.title = element_text(face = "bold", size = 13),
                          plot.subtitle = element_text(size = 9))
        )
    save_plot(figure4, "figure4_imagenet_current", 11.0, 4.4)
}

# Verified OpenBLAS thread scaling. The benchmark probes the active thread
# count before every fit, so requested cores are not reported as measured
# multicore execution unless the linked library actually uses them.
multicore_file <- file.path(
    optimized, "multicore_scaling_final", "multicore_scaling_summary.csv"
)
multicore <- read_required(multicore_file)
if (!all(multicore$requested_cores == multicore$active_openblas_threads) ||
    !all(multicore$prediction_agreement)) {
    stop("Multicore evidence failed thread-count or prediction-agreement checks")
}
write.csv(multicore, file.path(tabdir, "multicore_scaling_summary.csv"),
          row.names = FALSE, na = "")
multicore$workload_label <- factor(
    multicore$workload,
    levels = c("sample-rich classification", "predictor-wide regression",
               "response-wide regression"),
    labels = c("Sample-rich\nclassification", "Predictor-wide\nregression",
               "Response-wide\nregression")
)
multicore$speedup_low <- multicore$one_core_sec / multicore$q3_sec
multicore$speedup_high <- multicore$one_core_sec / multicore$q1_sec
p_multicore <- ggplot(
    multicore,
    aes(requested_cores, speedup, colour = workload_label,
        group = workload_label)
) +
    geom_hline(yintercept = 1, colour = "grey65", linetype = "dotted") +
    geom_errorbar(aes(ymin = speedup_low, ymax = speedup_high),
                  width = 0.08, linewidth = 0.45) +
    geom_line(linewidth = 0.75) +
    geom_point(size = 2.1) +
    scale_x_continuous(breaks = c(1, 2, 4)) +
    scale_colour_manual(values = c("#2166AC", "#D95F02", "#2E8B57")) +
    labs(
        title = "Verified OpenBLAS thread scaling",
        subtitle = paste(
            "Five repetitions; identical predictions at 1, 2 and 4",
            "directly probed active threads"
        ),
        x = "Active OpenBLAS threads",
        y = "Speed-up relative to one thread",
        colour = "Controlled workload"
    ) +
    theme_publication(9) +
    theme(legend.position = "bottom")
save_plot(p_multicore, "figureS13_multicore_scaling", 7.2, 4.2)

# Supplementary component paths are generated by the current-release path
# summarizer after both workstation panels finish. Copy only the derived tables
# and publication figures, leaving per-run files in the benchmark repository.
component_path_dir <- file.path(optimized, "component_path_summary_final")
component_tables <- c(
    "component_path_summary.csv",
    "component_selection.csv",
    "component_metric_correlations.csv"
)
for (filename in component_tables) {
    source <- file.path(component_path_dir, filename)
    if (!file.exists(source)) stop("Missing required component-path evidence: ", source)
    file.copy(source, file.path(tabdir, filename), overwrite = TRUE)
}
component_plot_dir <- file.path(component_path_dir, "component_path_plots")
component_plots <- list.files(component_plot_dir, pattern = "^component_path_.*\\.png$",
                              full.names = TRUE)
if (length(component_plots) != 11L) {
    stop("Expected 11 current component-path figures; found ", length(component_plots))
}
file.copy(component_plots, file.path(figdir, basename(component_plots)), overwrite = TRUE)

cat("Wrote current 0.99.39 figures and source tables to:\n", out, "\n", sep = "")
