#!/usr/bin/env Rscript

options(stringsAsFactors = FALSE)
suppressPackageStartupMessages({
    library(ggplot2)
    library(patchwork)
    library(scales)
})

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 3L) {
    stop("Usage: build_current_09940_evidence.R RESULT_ROOT OUTPUT_ROOT OLD_TABLE")
}
result_root <- normalizePath(args[[1L]], mustWork = TRUE)
output_root <- normalizePath(args[[2L]], mustWork = FALSE)
old_table <- normalizePath(args[[3L]], mustWork = TRUE)
figdir <- file.path(output_root, "figures")
tabdir <- file.path(output_root, "tables")
dir.create(figdir, recursive = TRUE, showWarnings = FALSE)
dir.create(tabdir, recursive = TRUE, showWarnings = FALSE)

read_required <- function(path) {
    if (!file.exists(path)) stop("Missing evidence: ", path)
    read.csv(path, check.names = FALSE)
}

save_plot <- function(plot, stem, width, height) {
    ggsave(file.path(figdir, paste0(stem, ".png")), plot, width = width,
           height = height, units = "in", dpi = 320, bg = "white")
    ggsave(file.path(figdir, paste0(stem, ".pdf")), plot, width = width,
           height = height, units = "in", device = cairo_pdf, bg = "white")
}

theme_pub <- function(size = 9) {
    theme_minimal(base_size = size, base_family = "Helvetica") +
        theme(
            plot.title = element_text(face = "bold"),
            axis.title = element_text(face = "bold"),
            axis.text = element_text(colour = "grey15"),
            panel.grid.minor = element_blank(),
            legend.title = element_text(face = "bold")
        )
}

dataset_labels <- c(
    ccle = "CCLE", cifar100 = "CIFAR-100", gtex_v8 = "GTEx v8",
    metref = "MetRef", retina = "Retina", tabula = "Tabula Muris",
    tcga_brca = "TCGA-BRCA",
    tcga_hnsc_methylation = "TCGA-HNSC methylation",
    tcga_pan_cancer = "TCGA Pan-Cancer"
)

# Replace only the fastPLS rows in the existing independent-implementation
# table. Independent-package measurements are retained unchanged.
raw <- read_required(file.path(result_root, "figure1_fastpls_raw.csv"))
keys <- interaction(raw$dataset, raw$classifier, drop = TRUE)
current <- do.call(rbind, lapply(split(raw, keys), function(x) {
    data.frame(
        dataset = unname(dataset_labels[x$dataset[[1L]]]),
        display = paste0("fastPLS SIMPLS-rSVD / ",
                         if (x$classifier[[1L]] == "lda") "LDA" else "argmax"),
        accuracy = median(x$accuracy),
        time_sec = median(x$total_sec),
        peak_rss_mib = median(x$peak_rss_mib),
        memory_lower_bound = FALSE,
        ncomp = x$ncomp[[1L]],
        repetitions = nrow(x),
        precision = "float32",
        stringsAsFactors = FALSE
    )
}))
comparison <- read_required(old_table)
comparison <- comparison[!grepl("^fastPLS", comparison$display), ]
comparison$display[comparison$display == "IKPLS / algorithm 2"] <- "IKPLS"
canonical_dataset <- function(x) {
    x <- gsub("[[:space:]]+", " ", trimws(x))
    x[x == "Tabula Muris"] <- "Tabula Muris"
    x[x == "TCGA- BRCA"] <- "TCGA-BRCA"
    x[x == "TCGA-HNSC methyl."] <- "TCGA-HNSC methylation"
    x[x == "TCGA Pan- Cancer"] <- "TCGA Pan-Cancer"
    x
}
comparison$dataset <- canonical_dataset(comparison$dataset)
comparison <- rbind(comparison, current)

python_summary_path <- file.path(result_root, "python_pls_panel_summary.csv")
python_failed_keys <- character()
if (file.exists(python_summary_path)) {
    python_summary <- read_required(python_summary_path)
    write.csv(
        python_summary,
        file.path(tabdir, "python_pls_panel_summary.csv"),
        row.names = FALSE,
        na = ""
    )
    python_status_path <- file.path(result_root, "python_pls_panel_status.csv")
    if (file.exists(python_status_path)) {
        python_status <- read_required(python_status_path)
        write.csv(
            python_status,
            file.path(tabdir, "python_pls_panel_status.csv"),
            row.names = FALSE,
            na = ""
        )
    }
    python_summary <- python_summary[
        python_summary$task_type == "classification", , drop = FALSE
    ]
    python_names <- c(
        nirs4all_methods_simpls = "nirs4all-methods / SIMPLS",
        nirs4all_methods_rsvd = "nirs4all-methods / randomized-SVD PLS",
        sklearn_plsregression = "scikit-learn / PLSRegression"
    )
    python_rows <- data.frame(
        dataset = unname(dataset_labels[python_summary$dataset]),
        display = unname(python_names[python_summary$implementation]),
        accuracy = python_summary$accuracy,
        time_sec = python_summary$median_total_sec,
        peak_rss_mib = python_summary$median_peak_rss_mib,
        memory_lower_bound = FALSE,
        ncomp = python_summary$ncomp,
        repetitions = python_summary$repetitions,
        precision = python_summary$precision,
        stringsAsFactors = FALSE
    )
    comparison <- comparison[
        !comparison$display %in% unname(python_names), , drop = FALSE
    ]
    comparison <- rbind(comparison, python_rows)
    if (exists("python_status")) {
        failed <- python_status[python_status$status == "failed", , drop = FALSE]
        failed$dataset_label <- unname(dataset_labels[failed$dataset])
        failed$display_label <- unname(python_names[failed$implementation])
        failed <- failed[
            !is.na(failed$dataset_label) & !is.na(failed$display_label),
            , drop = FALSE
        ]
        if (nrow(failed)) {
            python_failed_keys <- paste(failed$dataset_label,
                                        failed$display_label, sep = "\r")
        }
    }
}
python_large_path <- file.path(result_root, "python_pls_large_all_runs.csv")
if (file.exists(python_large_path)) {
    write.csv(
        read_required(python_large_path),
        file.path(tabdir, "python_pls_large_all_runs.csv"),
        row.names = FALSE,
        na = ""
    )
}
write.csv(comparison,
          file.path(tabdir, "figure1_independent_implementation_data.csv"),
          row.names = FALSE, na = "")

display_order <- c(
    "fastPLS SIMPLS-rSVD / argmax", "fastPLS SIMPLS-rSVD / LDA",
    "IKPLS", "nirs4all-methods / SIMPLS",
    "nirs4all-methods / randomized-SVD PLS",
    "scikit-learn / PLSRegression", "pls / SIMPLS",
    "plsgenomics / PLS-LDA",
    "mdatools / PLS-DA", "plsdepot / SIMPLS", "pcv / SIMPLS",
    "chemometrics / PLS eigen", "mixOmics / PLS-DA", "spls / sPLS-DA"
)
dataset_order <- unname(dataset_labels)
grid <- expand.grid(dataset = dataset_order, display = display_order,
                    stringsAsFactors = FALSE)
comparison <- merge(grid, comparison, by = c("dataset", "display"), all.x = TRUE)
comparison$cell_status <- ifelse(
    paste(comparison$dataset, comparison$display, sep = "\r") %in%
        python_failed_keys,
    "failed", "not_evaluated"
)
comparison$dataset <- factor(comparison$dataset, levels = dataset_order)
comparison$display <- factor(comparison$display, levels = rev(display_order))

heat_panel <- function(data, value, title, palette, labels, trans = "identity",
                       limits = NULL) {
    data$plot_value <- data[[value]]
    data$cell_label <- ifelse(
        is.na(data$plot_value),
        ifelse(data$cell_status == "failed", "Failed", "NE"),
        labels(data)
    )
    ggplot(data, aes(dataset, display, fill = plot_value)) +
        geom_tile(colour = "white", linewidth = 0.35) +
        geom_text(aes(label = cell_label), size = 2.15) +
        scale_fill_gradientn(colours = palette, na.value = "grey88",
                             trans = trans, limits = limits, oob = squish) +
        labs(title = title, x = NULL, y = NULL, fill = NULL) +
        theme_pub(8) +
        theme(axis.text.x = element_text(angle = 25, hjust = 1, face = "bold"),
              panel.grid = element_blank())
}

p_accuracy <- heat_panel(
    comparison, "accuracy", "A  Predictive accuracy",
    c("#edf5fb", "#77b5d9", "#084c8d"),
    function(x) sprintf("%.3f", x$accuracy), limits = c(0.65, 1)
)
p_time <- heat_panel(
    comparison, "time_sec", "B  Fitting plus prediction time (s)",
    c("#fff4de", "#fdae6b", "#b30000"),
    function(x) ifelse(x$time_sec < 0.1, sprintf("%.3f", x$time_sec),
                       ifelse(x$time_sec < 10, sprintf("%.2f", x$time_sec),
                              sprintf("%.0f", x$time_sec))), trans = "log10"
)
p_memory <- heat_panel(
    comparison, "peak_rss_mib", "C  Absolute peak process RSS (MiB)",
    c("#eef8ea", "#74c476", "#005a32"),
    function(x) sprintf("%.0f", x$peak_rss_mib), trans = "log10"
)
figure1 <- (p_accuracy / p_time / p_memory) +
    plot_annotation(
        title = "Single-CPU PLS classification workflows",
        subtitle = paste(
            "fastPLS rows: SIMPLS-rSVD, centred float32 predictors,",
            "training-selected components, argmax or LDA;\n",
            "oversampling 32, five power iterations, seed 123; one CPU thread."
        )
    )
save_plot(figure1, "figure1_independent_implementations", 9.4, 13.6)

# Current-release selected-component CPU/accelerator comparisons. Each row was
# measured in a fresh process; CUDA device memory is sampled by the parent
# process, while host RSS is corrected against the worker's pre-fit baseline.
summarize_selected <- function(path) {
    data <- read_required(path)
    if (!"family" %in% names(data) && "method" %in% names(data)) {
        data$family <- data$method
    }
    if (!"backend" %in% names(data) &&
        "backend_requested" %in% names(data)) {
        data$backend <- data$backend_requested
    }
    if (!"incremental_peak_rss_mib" %in% names(data) &&
        "incremental_peak_rss_mb" %in% names(data)) {
        data$incremental_peak_rss_mib <- data$incremental_peak_rss_mb
    }
    if (!"gpu_peak_mib" %in% names(data)) data$gpu_peak_mib <- NA_real_
    if (!"effective_oversample" %in% names(data)) {
        data$effective_oversample <- data$oversample
    }
    if (!"effective_power" %in% names(data)) {
        data$effective_power <- data$power
    }
    keys <- interaction(data$dataset, data$family, data$backend,
                        data$precision, data$ncomp, drop = TRUE)
    do.call(rbind, lapply(split(data, keys), function(x) {
        data.frame(
            dataset = x$dataset[[1L]],
            method = x$family[[1L]],
            backend = x$backend[[1L]],
            precision = x$precision[[1L]],
            ncomp = x$ncomp[[1L]],
            repetitions = nrow(x),
            median_total_sec = median(x$total_sec),
            q1_total_sec = unname(quantile(x$total_sec, 0.25)),
            q3_total_sec = unname(quantile(x$total_sec, 0.75)),
            median_metric = median(x$metric_value),
            median_incremental_rss_mib = median(x$incremental_peak_rss_mib),
            median_gpu_peak_mib = median(x$gpu_peak_mib),
            effective_oversample = paste(unique(stats::na.omit(
                x$effective_oversample
            )), collapse = "/"),
            effective_power = paste(unique(stats::na.omit(
                x$effective_power
            )), collapse = "/"),
            seed = if ("seed" %in% names(x)) x$seed[[1L]] else 123L,
            execution_route = paste(unique(x$execution_route), collapse = "; "),
            stringsAsFactors = FALSE
        )
    }))
}

summarize_fixed_cuda <- function(path) {
    data <- read_required(path)
    data <- data[data$classifier %in% c("argmax", "regression") &
                 data$status == "success", ]
    keys <- interaction(data$dataset, data$family, data$backend,
                        data$precision, data$ncomp, drop = TRUE)
    do.call(rbind, lapply(split(data, keys), function(x) {
        data.frame(
            dataset = x$dataset[[1L]],
            method = x$family[[1L]],
            backend = x$backend[[1L]],
            precision = x$precision[[1L]],
            ncomp = x$ncomp[[1L]],
            repetitions = nrow(x),
            median_total_sec = median(x$total_seconds),
            q1_total_sec = unname(quantile(x$total_seconds, 0.25)),
            q3_total_sec = unname(quantile(x$total_seconds, 0.75)),
            median_metric = median(x$metric),
            effective_oversample = paste(unique(stats::na.omit(
                x$oversample
            )), collapse = "/"),
            effective_power = paste(unique(stats::na.omit(
                x$power
            )), collapse = "/"),
            seed = 123L,
            execution_route = paste(unique(x$execution_route), collapse = "; "),
            stringsAsFactors = FALSE
        )
    }))
}

replace_timing_and_metric <- function(monitored, fixed) {
    keys <- c("dataset", "method", "backend", "precision", "ncomp")
    combined <- merge(monitored, fixed, by = keys, all.x = TRUE,
                      suffixes = c("_memory", "_timing"))
    required <- c("median_total_sec_timing", "median_metric_timing")
    if (any(!is.finite(combined[[required[[1L]]]])) ||
        any(!is.finite(combined[[required[[2L]]]]))) {
        stop("Current CUDA timing panel does not cover every monitored row")
    }
    data.frame(
        dataset = combined$dataset,
        method = combined$method,
        backend = combined$backend,
        precision = combined$precision,
        ncomp = combined$ncomp,
        repetitions = combined$repetitions_timing,
        median_total_sec = combined$median_total_sec_timing,
        q1_total_sec = combined$q1_total_sec_timing,
        q3_total_sec = combined$q3_total_sec_timing,
        median_metric = combined$median_metric_timing,
        median_incremental_rss_mib =
            combined$median_incremental_rss_mib,
        median_gpu_peak_mib = combined$median_gpu_peak_mib,
        effective_oversample = combined$effective_oversample_timing,
        effective_power = combined$effective_power_timing,
        seed = combined$seed_timing,
        execution_route = combined$execution_route_timing,
        stringsAsFactors = FALSE
    )
}

pair_selected <- function(data, accelerator, platform) {
    cpu <- data[data$backend == "cpu", ]
    acc <- data[data$backend == accelerator, ]
    keys <- c("dataset", "method", "precision", "ncomp")
    paired <- merge(cpu, acc, by = keys,
                    suffixes = c("_cpu", "_accelerator"))
    data.frame(
        platform = platform,
        dataset = paired$dataset,
        method = paired$method,
        precision = paired$precision,
        ncomp = paired$ncomp,
        repetitions_cpu = paired$repetitions_cpu,
        repetitions_accelerator = paired$repetitions_accelerator,
        cpu_time_sec = paired$median_total_sec_cpu,
        accelerator_time_sec = paired$median_total_sec_accelerator,
        ratio = paired$median_total_sec_cpu /
            paired$median_total_sec_accelerator,
        cpu_incremental_rss_mib = paired$median_incremental_rss_mib_cpu,
        accelerator_incremental_rss_mib =
            paired$median_incremental_rss_mib_accelerator,
        memory_ratio = ifelse(
            paired$median_incremental_rss_mib_cpu > 0,
            paired$median_incremental_rss_mib_accelerator /
                paired$median_incremental_rss_mib_cpu,
            NA_real_
        ),
        accelerator_gpu_peak_mib = paired$median_gpu_peak_mib_accelerator,
        cpu_metric = paired$median_metric_cpu,
        accelerator_metric = paired$median_metric_accelerator,
        metric_difference = paired$median_metric_accelerator -
            paired$median_metric_cpu,
        rsvd_controls = paste0(
            "o=", paired$effective_oversample_accelerator,
            ", power=", paired$effective_power_accelerator,
            ", seed=", paired$seed_accelerator
        ),
        execution_route = paired$execution_route_accelerator,
        stringsAsFactors = FALSE
    )
}

cuda_path <- file.path(result_root, "selected_backend_cuda_final.csv")
if (!file.exists(cuda_path)) {
    cuda_path <- file.path(result_root, "selected_backend_cuda_current.csv")
}
cuda_selected <- summarize_selected(cuda_path)
cuda_fixed <- summarize_fixed_cuda(file.path(
    result_root, "fixed_panel_cuda_current", "all_results.csv"
))
cuda_selected <- replace_timing_and_metric(cuda_selected, cuda_fixed)
metal_path <- file.path(result_root, "selected_backend_metal_final.csv")
if (!file.exists(metal_path)) {
    metal_path <- file.path(result_root, "selected_backend_metal_optimized.csv")
}
if (!file.exists(metal_path)) {
    metal_path <- file.path(result_root, "selected_backend_metal_current.csv")
}
metal_selected <- summarize_selected(metal_path)
selected_summary <- rbind(
    transform(cuda_selected, computer = "CUDA workstation"),
    transform(metal_selected, computer = "Metal workstation")
)
write.csv(selected_summary,
          file.path(tabdir, "selected_backend_summary.csv"),
          row.names = FALSE)
ratios <- rbind(
    pair_selected(cuda_selected, "cuda", "CUDA"),
    pair_selected(metal_selected, "metal", "Metal")
)
write.csv(ratios,
          file.path(tabdir, "figure2_backend_runtime_ratios.csv"),
          row.names = FALSE)

warm_path <- file.path(result_root, "metal_cifar_families_warm.csv")
metal_cv_path <- file.path(result_root, "metal_cifar_cv.csv")
cpu_cv_path <- file.path(result_root, "cpu_cifar_cv.csv")
persistent <- data.frame()
if (all(file.exists(c(warm_path, metal_cv_path, cpu_cv_path)))) {
    warm <- read_required(warm_path)
    warm <- warm[!(warm$backend == "metal" & warm$replicate == 1L), ]
    warm_keys <- interaction(warm$family, warm$backend, drop = TRUE)
    warm_summary <- do.call(rbind, lapply(split(warm, warm_keys), function(x) {
        data.frame(
            workload = x$family[[1L]],
            backend = x$backend[[1L]],
            median_total_sec = median(x$total_sec),
            median_metric = median(x$accuracy),
            repetitions = nrow(x),
            stringsAsFactors = FALSE
        )
    }))
    warm_cpu <- warm_summary[warm_summary$backend == "cpu", ]
    warm_metal <- warm_summary[warm_summary$backend == "metal", ]
    persistent <- merge(warm_cpu, warm_metal, by = "workload",
                        suffixes = c("_cpu", "_metal"))
    persistent$ratio <- persistent$median_total_sec_cpu /
        persistent$median_total_sec_metal
    persistent$metric_difference <- persistent$median_metric_metal -
        persistent$median_metric_cpu
    persistent$context <- "persistent fit and prediction"

    metal_cv <- read_required(metal_cv_path)
    cpu_cv <- read_required(cpu_cv_path)
    cv_row <- data.frame(
        workload = "simpls_cv",
        backend_cpu = "cpu",
        median_total_sec_cpu = cpu_cv$elapsed_sec[[1L]],
        median_metric_cpu = cpu_cv$best_metric[[1L]],
        repetitions_cpu = 1L,
        backend_metal = "metal",
        median_total_sec_metal = metal_cv$elapsed_sec[[1L]],
        median_metric_metal = metal_cv$best_metric[[1L]],
        repetitions_metal = 1L,
        ratio = cpu_cv$elapsed_sec[[1L]] / metal_cv$elapsed_sec[[1L]],
        metric_difference = metal_cv$best_metric[[1L]] -
            cpu_cv$best_metric[[1L]],
        context = "persistent 10-fold cross-validation",
        stringsAsFactors = FALSE
    )
    persistent <- rbind(persistent, cv_row)
    write.csv(
        persistent,
        file.path(tabdir, "figure2_metal_persistent_cifar100.csv"),
        row.names = FALSE
    )
}

backend_dataset_order <- c(
    "ccle", "cifar100", "gtex_v8", "metref",
    "retina", "tabula",
    "tcga_brca", "tcga_hnsc_methylation", "tcga_pan_cancer",
    "cbmc_citeseq", "prism"
)
backend_labels <- c(
    dataset_labels, cbmc_citeseq = "CBMC CITE-seq", prism = "PRISM"
)
method_labels <- c(
    plssvd = "PLS-SVD", simpls = "SIMPLS", opls = "OPLS",
    kernelpls = "kernel PLS"
)

ratio_panel <- function(data, platform, memory = FALSE) {
    data <- data[data$platform == platform, ]
    data$dataset <- factor(
        data$dataset, levels = rev(backend_dataset_order),
        labels = rev(unname(backend_labels[backend_dataset_order]))
    )
    data$method <- factor(data$method, levels = names(method_labels),
                          labels = unname(method_labels))
    value <- if (memory) data$memory_ratio else data$ratio
    data$plot_value <- ifelse(is.finite(value) & value > 0, value, NA_real_)
    data$log_ratio <- log2(data$plot_value)
    title <- if (memory) {
        paste0(platform, " incremental host-RSS ratio")
    } else {
        paste0(platform, " runtime ratio")
    }
    subtitle <- if (memory) {
        "Accelerator/CPU; values below 1 favour the accelerator"
    } else {
        "CPU/accelerator; values above 1 favour the accelerator"
    }
    legend <- if (memory) {
        paste0("log2 ", platform, "/CPU")
    } else {
        paste0("log2 CPU/", platform)
    }
    ggplot(data, aes(method, dataset, fill = log_ratio)) +
        geom_tile(colour = "white", linewidth = 0.55) +
        geom_text(aes(label = ifelse(
            is.na(plot_value), "NA", sprintf("%.2fx", plot_value)
        )), size = 2.35) +
        scale_fill_gradient2(
            low = if (memory) "#2166ac" else "#b2182b",
            mid = "#f7f7f7",
            high = if (memory) "#b2182b" else "#2166ac",
            midpoint = 0, na.value = "grey88", name = legend
        ) +
        labs(title = title, subtitle = subtitle, x = NULL, y = NULL) +
        theme_pub(8.2) +
        theme(axis.text.x = element_text(angle = 28, hjust = 1),
              panel.grid = element_blank(), legend.position = "bottom")
}

figure2 <- (
    ratio_panel(ratios, "CUDA") +
        ratio_panel(ratios, "Metal")
) / (
    ratio_panel(ratios, "CUDA", memory = TRUE) +
        ratio_panel(ratios, "Metal", memory = TRUE)
)
figure2 <- figure2 +
    plot_layout(guides = "collect") +
    plot_annotation(
        title = "CPU and accelerator runtime across selected PLS workloads",
        subtitle = "Fresh-process results retain device and pipeline initialization costs."
    ) & theme(legend.position = "bottom")
save_plot(figure2, "figure2_backend_runtime", 10.5, 12.0)

# Paired precision evidence. Conversion to float32 was completed before timing.
precision <- read_required(file.path(result_root, "summaries", "precision_summary.csv"))
write.csv(precision, file.path(tabdir, "precision_float32_float64_summary.csv"),
          row.names = FALSE)
precision$dataset <- factor(precision$dataset,
                            levels = c("metref", "gtex_v8"),
                            labels = c("MetRef", "GTEx v8"))
precision$method <- factor(precision$method,
                           levels = c("plssvd", "simpls", "opls", "kernelpls"),
                           labels = c("PLS-SVD", "SIMPLS", "OPLS",
                                      "nonlinear kernel PLS"))
precision$backend <- factor(precision$backend,
                            levels = c("cpu", "cuda", "metal"),
                            labels = c("CPU", "CUDA", "Metal"))
precision32 <- precision[precision$precision == "float32", ]
precision64 <- precision[precision$precision == "float64", ]
paired_precision <- merge(
    precision32, precision64,
    by = c("dataset", "method", "backend", "metric_name"),
    suffixes = c("_float32", "_float64")
)
paired_precision$runtime_ratio <- paired_precision$median_total_sec_float64 /
    paired_precision$median_total_sec_float32
paired_precision$rss_ratio <-
    paired_precision$median_incremental_peak_rss_mib_float32 /
    paired_precision$median_incremental_peak_rss_mib_float64
paired_precision$metric_difference <- paired_precision$median_metric_float32 -
    paired_precision$median_metric_float64
point_position <- position_dodge(width = 0.35)
p_precision_time <- ggplot(paired_precision,
        aes(method, runtime_ratio, colour = backend, shape = dataset,
            group = interaction(backend, dataset))) +
    geom_hline(yintercept = 1, linetype = 2, colour = "grey55") +
    geom_point(size = 3, position = point_position) +
    scale_y_log10() +
    labs(title = "A  Runtime ratio", x = NULL,
         y = "float64 time / float32 time", colour = "Backend",
         shape = "Dataset") + theme_pub(9) +
    theme(axis.text.x = element_text(angle = 25, hjust = 1))
p_precision_memory <- ggplot(paired_precision,
        aes(method, rss_ratio, colour = backend, shape = dataset,
            group = interaction(backend, dataset))) +
    geom_hline(yintercept = 1, linetype = 2, colour = "grey55") +
    geom_point(size = 3, position = point_position) +
    scale_y_log10() +
    labs(title = "B  Incremental-RSS ratio", x = NULL,
         y = "float32 RSS / float64 RSS", colour = "Backend",
         shape = "Dataset") + theme_pub(9) +
    theme(axis.text.x = element_text(angle = 25, hjust = 1))
p_precision_metric <- ggplot(paired_precision,
        aes(method, metric_difference, colour = backend, shape = dataset,
            group = interaction(backend, dataset))) +
    geom_hline(yintercept = 0, linetype = 2, colour = "grey55") +
    geom_point(size = 3, position = point_position) +
    labs(title = "C  Accuracy difference", x = NULL,
         y = "float32 accuracy - float64 accuracy", colour = "Backend",
         shape = "Dataset") + theme_pub(9) +
    theme(axis.text.x = element_text(angle = 25, hjust = 1))
save_plot(p_precision_time | p_precision_memory | p_precision_metric,
          "figureS_precision_float32_float64", 10.2, 4.0)

# Solver comparison uses identical matrices, component count and predictions.
solver <- read_required(file.path(result_root, "summaries", "solver_summary.csv"))
write.csv(solver, file.path(tabdir, "rsvd_irlba_summary.csv"), row.names = FALSE)
wide <- merge(solver[solver$solver == "irlba", ],
              solver[solver$solver == "rsvd", ],
              by = c("shape", "family", "metric_name", "ncomp"),
              suffixes = c("_irlba", "_rsvd"))
wide$speedup <- wide$median_total_sec_irlba / wide$median_total_sec_rsvd
wide$metric_difference <- abs(wide$median_metric_rsvd - wide$median_metric_irlba)
wide$memory_ratio <- wide$median_incremental_peak_rss_mib_rsvd /
    wide$median_incremental_peak_rss_mib_irlba
write.csv(wide, file.path(tabdir, "rsvd_irlba_paired_summary.csv"), row.names = FALSE)
wide$shape <- factor(wide$shape,
                     levels = c("balanced", "predictor_wide", "response_wide"),
                     labels = c("Balanced", "Predictor-wide", "Response-wide"))
wide$family <- factor(wide$family, levels = c("plssvd", "simpls"),
                      labels = c("PLS-SVD", "SIMPLS"))
p_solver_time <- ggplot(wide, aes(shape, speedup, fill = family)) +
    geom_col(position = position_dodge(width = 0.75), width = 0.68) +
    geom_hline(yintercept = 1, linetype = 2) +
    labs(title = "A  rSVD runtime advantage", x = NULL,
         y = "IRLBA time / rSVD time", fill = "Family") + theme_pub(9)
p_solver_memory <- ggplot(wide, aes(shape, memory_ratio, fill = family)) +
    geom_col(position = position_dodge(width = 0.75), width = 0.68) +
    geom_hline(yintercept = 1, linetype = 2) +
    labs(title = "B  rSVD incremental-RSS ratio", x = NULL,
         y = "rSVD RSS / IRLBA RSS", fill = "Family") + theme_pub(9)
save_plot(p_solver_time | p_solver_memory, "figureS_rsvd_vs_irlba", 9.2, 3.8)

# Verified OpenBLAS thread scaling.
multicore <- read_required(file.path(result_root, "multicore_scaling",
                                     "multicore_scaling_summary.csv"))
write.csv(multicore, file.path(tabdir, "multicore_scaling_summary.csv"),
          row.names = FALSE)
multicore$workload <- factor(multicore$workload,
    levels = c("sample-rich classification", "predictor-wide regression",
               "response-wide regression"))
p_multicore <- ggplot(multicore, aes(active_openblas_threads, speedup,
                                     colour = workload, group = workload)) +
    geom_hline(yintercept = 1, linetype = 2, colour = "grey55") +
    geom_line(linewidth = 0.8) + geom_point(size = 2.5) +
    scale_x_continuous(breaks = c(1, 2, 4)) +
    labs(title = "Verified OpenBLAS thread scaling", x = "Active CPU threads",
         y = "One-thread time / observed time", colour = "Workload") +
    theme_pub(9) + theme(legend.position = "bottom")
save_plot(p_multicore, "figureS_multicore_scaling", 6.8, 4.0)

# Current ImageNet component path: one fit per classifier, evaluated at all
# requested prefixes. These remain single-run exploratory measurements.
image_dir <- file.path(dirname(result_root), "..", "fastPLS_results_local",
                      "current_candidate_20260906", "release_0.99.40")
image_dir <- normalizePath(image_dir, mustWork = FALSE)
if (!dir.exists(image_dir)) {
    image_dir <- "/Users/stefano/Documents/GPUPLS/fastPLS_results_local/current_candidate_20260906/release_0.99.40"
}
image <- rbind(
    read_required(file.path(image_dir, "imagenet_float32_argmax.csv")),
    read_required(file.path(image_dir, "imagenet_float32_lda.csv"))
)
image$host_observed_mb <- pmax(image$rss_after_fit_mb,
                               image$rss_after_top5_mb, na.rm = TRUE)
write.csv(image, file.path(tabdir, "figure4_imagenet_current.csv"), row.names = FALSE)
image$classifier <- factor(image$classifier, levels = c("argmax", "lda"),
                           labels = c("Argmax", "LDA"))
p_image_top1 <- ggplot(image, aes(ncomp_requested, top1_accuracy,
                                  colour = classifier)) +
    geom_line(linewidth = 0.8) + geom_point(size = 2) +
    labs(title = "A  Top-1 accuracy", x = "PLS components", y = "Accuracy",
         colour = "Prediction head") + theme_pub(9)
p_image_top5 <- ggplot(image, aes(ncomp_requested, top5_accuracy,
                                  colour = classifier)) +
    geom_line(linewidth = 0.8) + geom_point(size = 2) +
    labs(title = "B  Top-5 accuracy", x = "PLS components", y = "Accuracy",
         colour = "Prediction head") + theme_pub(9)
p_image_time <- ggplot(image, aes(ncomp_requested, total_time_sec,
                                  colour = classifier)) +
    geom_line(linewidth = 0.8) + geom_point(size = 2) +
    labs(title = "C  Fitting plus prediction", x = "PLS components",
         y = "Seconds", colour = "Prediction head") + theme_pub(9)
image_memory <- rbind(
    data.frame(ncomp_requested = image$ncomp_requested,
               classifier = image$classifier,
               memory = "Host process RSS",
               mib = image$host_observed_mb),
    data.frame(ncomp_requested = image$ncomp_requested,
               classifier = image$classifier,
               memory = "GPU allocation",
               mib = image$gpu_after_top5_mb)
)
p_image_memory <- ggplot(
    image_memory,
    aes(ncomp_requested, mib, colour = classifier, linetype = memory)
) +
    geom_line(linewidth = 0.8) + geom_point(size = 2) +
    labs(title = "D  Observed post-prediction memory",
         x = "PLS components", y = "MiB",
         colour = "Prediction head", linetype = "Measurement") +
    theme_pub(9)
save_plot((p_image_top1 | p_image_top5) / (p_image_time | p_image_memory),
          "figure4_imagenet_current", 9.2, 7.0)
