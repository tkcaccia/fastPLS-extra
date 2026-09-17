#!/usr/bin/env Rscript

# Build the fixed-component NMR table and Figure 3 from external evidence.
# The main figure contains only PLS-SVD and SIMPLS on CPU, CUDA, and Metal.

options(stringsAsFactors = FALSE)
suppressPackageStartupMessages({
    library(ggplot2)
    library(jsonlite)
    library(patchwork)
})

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 3L) {
    stop(
        "Usage: build_nmr_figure3.R LINUX_EVIDENCE MAC_EVIDENCE OUTPUT_ROOT"
    )
}
linux_root <- normalizePath(args[[1L]], mustWork = TRUE)
mac_root <- normalizePath(args[[2L]], mustWork = TRUE)
output_root <- normalizePath(args[[3L]], mustWork = FALSE)
figdir <- file.path(output_root, "figures")
tabdir <- file.path(output_root, "tables")
dir.create(figdir, recursive = TRUE, showWarnings = FALSE)
dir.create(tabdir, recursive = TRUE, showWarnings = FALSE)

read_one <- function(path) {
    if (!file.exists(path)) stop("Missing evidence: ", path)
    read.csv(path, check.names = FALSE)
}

read_manifest <- function(root) {
    path <- file.path(root, "run_manifest.json")
    if (!file.exists(path)) stop("Missing run manifest: ", path)
    fromJSON(path, simplifyVector = TRUE)
}

memory_one <- function(path) {
    value <- fromJSON(path)$measurements
    if (is.null(value) || !nrow(value)) {
        return(c(
            baseline_rss_mib = NA_real_, peak_rss_mib = NA_real_,
            incremental_rss_mib = NA_real_, baseline_gpu_mib = NA_real_,
            peak_gpu_mib = NA_real_, incremental_gpu_mib = NA_real_
        ))
    }
    unlist(value[1L, c(
        "baseline_rss_mib", "peak_rss_mib", "incremental_rss_mib",
        "baseline_gpu_mib", "peak_gpu_mib", "incremental_gpu_mib"
    )], use.names = TRUE)
}

collect_route <- function(root, platform, family, backend, implementation) {
    route <- file.path(root, platform, paste0(family, "_", backend))
    repetitions <- sort(list.dirs(route, recursive = FALSE, full.names = TRUE))
    repetitions <- repetitions[grepl("/replicate_[0-9]+$", repetitions)]
    results <- file.path(repetitions, "result.csv")
    monitor <- file.path(route, "memory", "monitor", "summary.json")
    if (!length(results) || any(!file.exists(results)) || !file.exists(monitor)) {
        stop("Incomplete timing or memory evidence for ", implementation)
    }
    values <- do.call(rbind, lapply(results, read_one))
    memory <- memory_one(monitor)
    data.frame(
        implementation = implementation,
        family = family,
        backend = backend,
        platform = platform,
        precision = unique(values$precision),
        ncomp = unique(values$ncomp),
        seed = unique(values$seed),
        oversample = unique(values$oversample),
        power = unique(values$power),
        direction_rule = paste(unique(values$direction_rule), collapse = "; "),
        total_time_sec = median(values$total_time_sec),
        time_q1_sec = unname(quantile(values$total_time_sec, 0.25)),
        time_q3_sec = unname(quantile(values$total_time_sec, 0.75)),
        repetitions = nrow(values),
        RMSD = median(values$RMSD),
        Q2 = median(values$Q2),
        MAE = median(values$MAE),
        baseline_rss_mib = memory[["baseline_rss_mib"]],
        peak_rss_mib = memory[["peak_rss_mib"]],
        incremental_rss_mib = memory[["incremental_rss_mib"]],
        baseline_gpu_mib = memory[["baseline_gpu_mib"]],
        peak_gpu_mib = memory[["peak_gpu_mib"]],
        incremental_gpu_mib = memory[["incremental_gpu_mib"]],
        workstation = read_manifest(root)$workstation,
        stringsAsFactors = FALSE
    )
}

summary <- do.call(rbind, list(
    collect_route(linux_root, "linux", "plssvd", "cpu", "PLS-SVD / CPU"),
    collect_route(linux_root, "linux", "plssvd", "cuda", "PLS-SVD / CUDA"),
    collect_route(mac_root, "mac", "plssvd", "metal", "PLS-SVD / Metal"),
    collect_route(linux_root, "linux", "simpls", "cpu", "SIMPLS / CPU"),
    collect_route(linux_root, "linux", "simpls", "cuda", "SIMPLS / CUDA"),
    collect_route(mac_root, "mac", "simpls", "metal", "SIMPLS / Metal")
))
numeric_columns <- vapply(summary, is.numeric, logical(1L))
for (column in names(summary)[numeric_columns]) {
    summary[[column]][is.nan(summary[[column]])] <- NA_real_
}
write.csv(
    summary, file.path(tabdir, "figure3_nmr_fixed165_summary.csv"),
    row.names = FALSE, na = ""
)

order <- c(
    "PLS-SVD / CPU", "PLS-SVD / CUDA", "PLS-SVD / Metal",
    "SIMPLS / CPU", "SIMPLS / CUDA", "SIMPLS / Metal"
)
summary$implementation <- factor(summary$implementation, levels = order)
colours <- c(
    "PLS-SVD / CPU" = "#3B6FB6", "PLS-SVD / CUDA" = "#188977",
    "PLS-SVD / Metal" = "#D87819", "SIMPLS / CPU" = "#6C55A3",
    "SIMPLS / CUDA" = "#20A486", "SIMPLS / Metal" = "#E5A000"
)
theme_publication <- function(size = 9) {
    theme_minimal(base_size = size, base_family = "Helvetica") +
        theme(
            plot.title = element_text(face = "bold"),
            axis.title = element_text(face = "bold"),
            axis.text = element_text(colour = "grey15"),
            panel.grid.minor = element_blank(),
            legend.position = "none"
        )
}

bar_panel <- function(value, title, ylab, digits, error = FALSE) {
    labels <- if (value == "RMSD") {
        formatC(summary[[value]], format = "e", digits = 2)
    } else {
        formatC(summary[[value]], format = "f", digits = digits)
    }
    plot <- ggplot(summary, aes(implementation, .data[[value]], fill = implementation)) +
        geom_col(width = 0.72) +
        geom_text(
            aes(label = labels), angle = 90, hjust = -0.15,
            size = 2.5, colour = "grey10"
        ) +
        scale_fill_manual(values = colours) +
        scale_y_continuous(
            limits = c(0, NA), expand = expansion(mult = c(0, 0.24))
        ) +
        labs(title = title, x = NULL, y = ylab) +
        theme_publication(8) +
        theme(axis.text.x = element_text(angle = 35, hjust = 1, size = 7)) +
        coord_cartesian(clip = "off")
    if (error) {
        plot <- plot + geom_errorbar(
            aes(ymin = time_q1_sec, ymax = time_q3_sec),
            width = 0.2, linewidth = 0.4
        )
    }
    plot
}

p3a <- bar_panel(
    "total_time_sec", "A  Fitting plus prediction", "Seconds", 2, TRUE
)
p3b <- bar_panel("RMSD", "B  Held-out prediction error", "RMSD", 6)

memory <- rbind(
    data.frame(
        implementation = summary$implementation,
        memory = summary$incremental_rss_mib,
        type = "Host RSS increment"
    ),
    data.frame(
        implementation = summary$implementation,
        memory = summary$incremental_gpu_mib,
        type = "CUDA device increment"
    )
)
memory <- memory[is.finite(memory$memory), , drop = FALSE]
p3c <- ggplot(memory, aes(implementation, memory, fill = type)) +
    geom_col(position = position_dodge(width = 0.8), width = 0.72) +
    scale_fill_manual(values = c(
        "Host RSS increment" = "#4C78A8",
        "CUDA device increment" = "#F58518"
    )) +
    scale_y_continuous(limits = c(0, NA), expand = expansion(mult = c(0, 0.1))) +
    labs(title = "C  Incremental peak memory", x = NULL, y = "MiB", fill = NULL) +
    theme_publication(8) +
    theme(
        axis.text.x = element_text(angle = 35, hjust = 1, size = 7),
        legend.position = "top"
    )

prediction_path <- function(root, platform, family, backend) {
    path <- file.path(
        root, platform, paste0(family, "_", backend),
        "replicate_01", "prediction.rds"
    )
    if (!file.exists(path)) stop("Missing prediction evidence: ", path)
    path
}
predictions <- c(
    "PLS-SVD / CPU" = prediction_path(linux_root, "linux", "plssvd", "cpu"),
    "PLS-SVD / CUDA" = prediction_path(linux_root, "linux", "plssvd", "cuda"),
    "PLS-SVD / Metal" = prediction_path(mac_root, "mac", "plssvd", "metal"),
    "SIMPLS / CPU" = prediction_path(linux_root, "linux", "simpls", "cpu"),
    "SIMPLS / CUDA" = prediction_path(linux_root, "linux", "simpls", "cuda"),
    "SIMPLS / Metal" = prediction_path(mac_root, "mac", "simpls", "metal")
)
objects <- lapply(predictions, readRDS)
per_sample <- do.call(rbind, lapply(names(objects), function(name) {
    data.frame(
        implementation = factor(name, levels = order),
        RMSD = as.numeric(objects[[name]]$per_sample_rmsd)
    )
}))
p3d <- ggplot(per_sample, aes(implementation, RMSD, fill = implementation)) +
    geom_violin(scale = "width", trim = TRUE, alpha = 0.75, colour = "grey25") +
    geom_boxplot(width = 0.15, outlier.size = 0.35, fill = "white") +
    scale_fill_manual(values = colours) +
    labs(title = "D  Per-spectrum prediction error", x = NULL, y = "RMSD") +
    theme_publication(8) +
    theme(axis.text.x = element_text(angle = 35, hjust = 1, size = 7))

representative <- objects[["SIMPLS / CPU"]]
sample_index <- which.min(abs(
    representative$per_sample_rmsd - median(representative$per_sample_rmsd)
))
ppm <- suppressWarnings(as.numeric(colnames(representative$observed)))
if (any(!is.finite(ppm))) ppm <- seq_len(ncol(representative$observed))
spectrum <- rbind(
    data.frame(
        ppm = ppm, intensity = representative$observed[sample_index, ],
        series = "Observed"
    ),
    data.frame(
        ppm = ppm, intensity = representative$predicted[sample_index, ],
        series = "Predicted"
    )
)
spectrum_panel <- function(limits, title) {
    ggplot(spectrum, aes(ppm, intensity, colour = series)) +
        geom_line(linewidth = 0.35, alpha = 0.9) +
        scale_colour_manual(values = c(Observed = "#202020", Predicted = "#D55E00")) +
        scale_x_reverse() +
        coord_cartesian(xlim = sort(limits)) +
        labs(title = title, x = "Chemical shift (ppm)", y = "Intensity", colour = NULL) +
        theme_publication(8) +
        theme(legend.position = "top")
}
p3e <- spectrum_panel(c(12, 0), "E  Representative held-out spectrum")
p3f <- spectrum_panel(c(1.7, 0.5), "F  Expanded spectral region")

figure <- ((p3a | p3b) / (p3c | p3d) / (p3e | p3f)) +
    plot_annotation(
        title = "NMR prediction at a common 165-component workload",
        subtitle = paste0(
            "Three isolated processes per route; float32 rSVD; ",
            "conversion excluded and accelerator overhead included"
        ),
        theme = theme(
            plot.title = element_text(face = "bold", size = 13),
            plot.subtitle = element_text(size = 8.7)
        )
    )
ggsave(
    file.path(figdir, "figure3_nmr_fixed165.png"), figure,
    width = 10.5, height = 12, units = "in", dpi = 320, bg = "white"
)
ggsave(
    file.path(figdir, "figure3_nmr_fixed165.pdf"), figure,
    width = 10.5, height = 12, units = "in", device = cairo_pdf, bg = "white"
)
