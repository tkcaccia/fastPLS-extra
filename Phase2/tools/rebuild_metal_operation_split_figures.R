#!/usr/bin/env Rscript

suppressPackageStartupMessages({
    library(ggplot2)
    library(patchwork)
})

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 7L) {
    stop(paste(
        "Usage: rebuild_metal_operation_split_figures.R",
        "CUDA_SUMMARY METAL_PAIRED NMR_CURRENT_SUMMARY",
        "NMR_OLD_SUMMARY NMR_PREDICTION_DIR OLD_FIGURE_ROOT OUTPUT_ROOT"
    ), call. = FALSE)
}

read_required <- function(path) {
    read.csv(normalizePath(path, mustWork = TRUE), check.names = FALSE)
}
cuda <- read_required(args[[1L]])
metal <- read_required(args[[2L]])
nmr_current <- read_required(args[[3L]])
nmr_old <- read_required(args[[4L]])
nmr_prediction_dir <- normalizePath(args[[5L]], mustWork = TRUE)
old_root <- normalizePath(args[[6L]], mustWork = TRUE)
output_root <- normalizePath(args[[7L]], mustWork = FALSE)
figure_dir <- file.path(output_root, "figures")
table_dir <- file.path(output_root, "tables")
dir.create(figure_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(table_dir, recursive = TRUE, showWarnings = FALSE)

theme_publication <- function(base_size = 9) {
    theme_minimal(base_size = base_size, base_family = "Helvetica") +
        theme(
            plot.title = element_text(face = "bold", size = rel(1.12)),
            plot.subtitle = element_text(size = rel(0.88), colour = "grey25"),
            axis.title = element_text(face = "bold"),
            axis.text = element_text(colour = "grey15"),
            panel.grid.minor = element_blank(),
            legend.title = element_text(face = "bold"),
            plot.margin = margin(6, 8, 6, 8)
        )
}

save_plot <- function(plot, stem, width, height) {
    ggsave(file.path(figure_dir, paste0(stem, ".png")), plot,
        width = width, height = height, units = "in", dpi = 320,
        bg = "white")
    ggsave(file.path(figure_dir, paste0(stem, ".pdf")), plot,
        width = width, height = height, units = "in", device = cairo_pdf,
        bg = "white")
}

paired_cuda <- function(value) {
    cpu <- value[value$backend == "cpu", ]
    gpu <- value[value$backend == "cuda", ]
    paired <- merge(cpu, gpu, by = c("dataset", "method", "ncomp"),
        suffixes = c("_cpu", "_accelerator"))
    data.frame(
        platform = "CUDA", dataset = paired$dataset,
        method = paired$method, ncomp = paired$ncomp,
        cpu_time_sec = paired$median_total_sec_cpu,
        accelerator_time_sec = paired$median_total_sec_accelerator,
        ratio = paired$median_total_sec_cpu /
            paired$median_total_sec_accelerator,
        cpu_incremental_rss_mib = paired$median_incremental_rss_mb_cpu,
        accelerator_incremental_rss_mib =
            paired$median_incremental_rss_mb_accelerator,
        memory_ratio = paired$median_incremental_rss_mb_accelerator /
            paired$median_incremental_rss_mb_cpu,
        cpu_metric = paired$median_metric_cpu,
        accelerator_metric = paired$median_metric_accelerator,
        metric_difference = paired$median_metric_accelerator -
            paired$median_metric_cpu,
        rsvd_controls = "recorded in the CUDA source run",
        execution_route = paired$execution_route_accelerator,
        stringsAsFactors = FALSE
    )
}

paired_metal <- function(value) {
    data.frame(
        platform = "Metal", dataset = value$dataset,
        method = value$family, ncomp = value$ncomp,
        cpu_time_sec = value$median_total_sec_cpu,
        accelerator_time_sec = value$median_total_sec_metal,
        ratio = value$runtime_ratio_cpu_over_metal,
        cpu_incremental_rss_mib =
            value$median_incremental_peak_rss_mib_cpu,
        accelerator_incremental_rss_mib =
            value$median_incremental_peak_rss_mib_metal,
        memory_ratio = value$memory_ratio_metal_over_cpu,
        cpu_metric = value$median_metric_cpu,
        accelerator_metric = value$median_metric_metal,
        metric_difference = value$metric_difference_metal_minus_cpu,
        rsvd_controls = paste0(
            "oversampling ", value$effective_oversample_metal,
            "; power ", value$effective_power_metal,
            "; seed ", value$seed_metal
        ),
        execution_route = value$execution_route_metal,
        stringsAsFactors = FALSE
    )
}

ratios <- rbind(paired_cuda(cuda), paired_metal(metal))
write.csv(ratios, file.path(table_dir, "figure2_backend_runtime_ratios.csv"),
    row.names = FALSE)

dataset_order <- c(
    "ccle", "cifar100", "gtex_v8", "metref", "retina", "tabula",
    "tcga_brca", "tcga_hnsc_methylation", "tcga_pan_cancer",
    "cbmc_citeseq", "prism"
)
dataset_labels <- c(
    ccle = "CCLE", cifar100 = "CIFAR-100", gtex_v8 = "GTEx v8",
    metref = "MetRef", retina = "Retina", tabula = "Tabula Muris",
    tcga_brca = "TCGA-BRCA",
    tcga_hnsc_methylation = "TCGA-HNSC methylation",
    tcga_pan_cancer = "TCGA Pan-Cancer",
    cbmc_citeseq = "CBMC CITE-seq", prism = "PRISM"
)
method_labels <- c(
    plssvd = "PLS-SVD", simpls = "SIMPLS", opls = "OPLS",
    kernelpls = "kernel PLS"
)

ratio_panel <- function(value, platform, memory = FALSE) {
    value <- value[value$platform == platform, ]
    value$dataset <- factor(value$dataset, levels = rev(dataset_order),
        labels = rev(unname(dataset_labels[dataset_order])))
    value$method <- factor(value$method, levels = names(method_labels),
        labels = unname(method_labels))
    value$plot_ratio <- value[[if (memory) "memory_ratio" else "ratio"]]
    value$log_ratio <- log2(value$plot_ratio)
    low <- if (memory) "#2166AC" else "#B2182B"
    high <- if (memory) "#B2182B" else "#2166AC"
    ggplot(value, aes(method, dataset, fill = log_ratio)) +
        geom_tile(colour = "white", linewidth = 0.55) +
        geom_text(aes(label = sprintf("%.2fx", plot_ratio)), size = 2.45) +
        scale_fill_gradient2(
            low = low, mid = "#F7F7F7", high = high, midpoint = 0,
            name = if (memory) paste0("log2 ", platform, "/CPU") else
                paste0("log2 CPU/", platform)
        ) +
        labs(
            title = paste0(platform,
                if (memory) " incremental host-memory ratio" else
                    " runtime ratio"),
            subtitle = if (memory) {
                "Accelerator/CPU; values below 1 favour the accelerator"
            } else {
                "CPU/accelerator; values above 1 favour the accelerator"
            },
            x = NULL, y = NULL
        ) +
        theme_publication(8.3) +
        theme(
            axis.text.x = element_text(angle = 28, hjust = 1),
            panel.grid = element_blank(), legend.position = "bottom"
        )
}

figure2 <-
    (ratio_panel(ratios, "CUDA") + ratio_panel(ratios, "Metal")) /
    (ratio_panel(ratios, "CUDA", TRUE) + ratio_panel(ratios, "Metal", TRUE)) +
    plot_layout(guides = "collect") +
    plot_annotation(
        title = "CPU and accelerator execution across the benchmark panel",
        subtitle = paste(
            "Metal denotes the fixed CPU/Metal operation split; every completed",
            "paired result is shown and comparisons are within workstation."
        ),
        theme = theme(
            plot.title = element_text(face = "bold", size = 13),
            plot.subtitle = element_text(size = 9)
        )
    ) & theme(legend.position = "bottom")
save_plot(figure2, "figure2_backend_runtime", 10.5, 12)

# Retain CUDA/deposited rows and replace every Mac row with version 0.99.42.
keep_old <- nmr_old[grepl("CUDA|Linux|Deposited", nmr_old$implementation), ]
current_rows <- transform(
    nmr_current,
    implementation = paste0(
        ifelse(family == "plssvd", "PLS-SVD",
            ifelse(family == "kernelpls", "kernel PLS", toupper(family))),
        " / ", ifelse(backend == "cpu", "CPU (Mac)", "Metal")
    ),
    total_time_sec = median_total_sec,
    time_q1_sec = q1_total_sec,
    time_q3_sec = q3_total_sec,
    RMSD = median_metric,
    Q2 = NA_real_, MAE = NA_real_, workstation = "Apple M3",
    peak_rss_mib = NA_real_,
    incremental_rss_mib = median_incremental_peak_rss_mib,
    peak_gpu_mib = NA_real_, incremental_gpu_mib = NA_real_
)
current_rows <- current_rows[, names(nmr_old), drop = FALSE]
nmr_summary <- rbind(keep_old, current_rows)
write.csv(nmr_summary, file.path(table_dir, "figure3_nmr_fixed165_summary.csv"),
    row.names = FALSE)

short_label <- function(value) {
    value <- sub(" / CPU \\(Linux\\)", " CPU", value)
    value <- sub(" / CPU \\(Mac\\)", " CPU", value)
    sub(" / ", " ", value)
}
nmr_summary$display <- short_label(nmr_summary$implementation)
nmr_summary$display <- factor(nmr_summary$display,
    levels = unique(nmr_summary$display))
palette <- setNames(
    grDevices::hcl.colors(nlevels(nmr_summary$display), "Dark 3"),
    levels(nmr_summary$display)
)

bar_panel <- function(column, title, ylabel, log_scale = FALSE) {
    value <- nmr_summary[is.finite(nmr_summary[[column]]), ]
    figure <- ggplot(value, aes(display, .data[[column]], fill = display)) +
        geom_col(width = 0.72) +
        scale_fill_manual(values = palette, guide = "none") +
        labs(title = title, x = NULL, y = ylabel) +
        theme_publication(8) +
        theme(axis.text.x = element_text(angle = 50, hjust = 1, size = 6.3))
    if (log_scale) figure <- figure + scale_y_log10()
    figure
}

prediction_names <- c(
    "PLS-SVD CPU" = "nmr_plssvd_cpu_k165_prediction.rds",
    "PLS-SVD Metal" = "nmr_plssvd_metal_k165_prediction.rds",
    "SIMPLS CPU" = "nmr_simpls_cpu_k165_prediction.rds",
    "SIMPLS Metal" = "nmr_simpls_metal_k165_prediction.rds"
)
prediction_objects <- lapply(
    file.path(nmr_prediction_dir, unname(prediction_names)), readRDS
)
names(prediction_objects) <- names(prediction_names)
per_sample <- do.call(rbind, lapply(names(prediction_objects), function(name) {
    data.frame(
        implementation = name,
        rmsd = prediction_objects[[name]]$per_sample_rmsd
    )
}))
p3d <- ggplot(per_sample, aes(implementation, rmsd, fill = implementation)) +
    geom_violin(scale = "width", trim = TRUE, alpha = 0.75,
        colour = "grey25") +
    geom_boxplot(width = 0.15, outlier.size = 0.35, fill = "white") +
    guides(fill = "none") +
    labs(title = "D  Per-spectrum prediction error", x = NULL, y = "RMSD") +
    theme_publication(8) +
    theme(axis.text.x = element_text(angle = 35, hjust = 1, size = 7))

representative <- prediction_objects[["SIMPLS CPU"]]
sample_index <- which.min(abs(
    representative$per_sample_rmsd - median(representative$per_sample_rmsd)
))
ppm <- suppressWarnings(as.numeric(colnames(representative$observed)))
if (any(!is.finite(ppm))) ppm <- seq_len(ncol(representative$observed))
spectrum <- rbind(
    data.frame(ppm = ppm,
        intensity = representative$observed[sample_index, ],
        series = "Observed"),
    data.frame(ppm = ppm,
        intensity = representative$predicted[sample_index, ],
        series = "Predicted")
)
spectrum_panel <- function(limits, title) {
    ggplot(spectrum, aes(ppm, intensity, colour = series)) +
        geom_line(linewidth = 0.35, alpha = 0.9) +
        scale_colour_manual(values = c(
            Observed = "#202020", Predicted = "#D55E00"
        )) +
        scale_x_reverse() +
        coord_cartesian(xlim = sort(limits)) +
        labs(title = title, x = "Chemical shift (ppm)", y = "Intensity",
            colour = NULL) +
        theme_publication(8) + theme(legend.position = "top")
}

figure3 <-
    (bar_panel("total_time_sec", "A  Fitting plus prediction", "Seconds", TRUE) |
        bar_panel("RMSD", "B  Held-out prediction error", "RMSD")) /
    (bar_panel("incremental_rss_mib", "C  Incremental process memory", "MiB") |
        p3d) /
    (spectrum_panel(c(12, 0), "E  Representative held-out spectrum") |
        spectrum_panel(c(1.7, 0.5), "F  Expanded spectral region")) +
    plot_annotation(
        title = "NMR prediction at a common 165-component workload",
        subtitle = paste(
            "Metal denotes the fixed CPU/Metal operation split; CPU/accelerator",
            "timing comparisons are made only within workstation."
        ),
        theme = theme(
            plot.title = element_text(face = "bold", size = 13),
            plot.subtitle = element_text(size = 8.7)
        )
    )
save_plot(figure3, "figure3_nmr_fixed165", 10.5, 12)

# Populate a complete evidence tree without overwriting new files.
old_figures <- list.files(file.path(old_root, "figures"), full.names = TRUE)
file.copy(old_figures, figure_dir, overwrite = FALSE)
old_tables <- list.files(file.path(old_root, "tables"), full.names = TRUE)
old_tables <- old_tables[
    basename(old_tables) != "figure2_metal_persistent_cifar100.csv"
]
file.copy(old_tables, table_dir, overwrite = FALSE)
