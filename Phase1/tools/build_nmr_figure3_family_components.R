#!/usr/bin/env Rscript

# Build Figure 3 from the current-release NMR component-path evidence.
# PLS-SVD is evaluated at 100 components and the SIMPLS-family estimator at 50.

options(stringsAsFactors = FALSE)
suppressPackageStartupMessages({
    library(ggplot2)
    library(patchwork)
})

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 4L) {
    stop(
        paste(
            "Usage: build_nmr_figure3_family_components.R RESULTS_CSV",
            "PREDICTION_ROOT DEPOSITED_ROOT OUTPUT_ROOT"
        ),
        call. = FALSE
    )
}
results_path <- normalizePath(args[[1L]], mustWork = TRUE)
prediction_root <- normalizePath(args[[2L]], mustWork = TRUE)
deposited_root <- normalizePath(args[[3L]], mustWork = TRUE)
output_root <- normalizePath(args[[4L]], mustWork = FALSE)
figure_dir <- file.path(output_root, "figures")
table_dir <- file.path(output_root, "tables")
dir.create(figure_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(table_dir, recursive = TRUE, showWarnings = FALSE)

results <- read.csv(results_path, check.names = FALSE)
required <- c(
    "package_version", "source_id", "dataset", "family", "backend",
    "precision", "requested_ncomp", "replicate", "total_sec", "metric_value",
    "incremental_peak_rss_mib", "gpu_peak_mib", "platform", "status"
)
if (!all(required %in% names(results))) {
    stop("The component-path evidence is missing required columns.", call. = FALSE)
}

route_specification <- data.frame(
    implementation = c(
        "PLS-SVD\nCPU (100)", "PLS-SVD\nCUDA (100)",
        "SIMPLS-family\nCPU (50)", "SIMPLS-family\nCUDA (50)"
    ),
    family = c(rep("plssvd", 2L), rep("simpls", 2L)),
    backend = rep(c("cpu", "cuda"), 2L),
    platform = rep("linux_nvidia", 4L),
    ncomp = c(rep(100L, 2L), rep(50L, 2L)),
    stringsAsFactors = FALSE
)

collect_route <- function(specification) {
    selected <- results[
        results$dataset == "nmr" &
            results$family == specification$family &
            results$backend == specification$backend &
            results$platform == specification$platform &
            results$precision == "float32" &
            results$requested_ncomp == specification$ncomp &
            results$status == "success",
        , drop = FALSE
    ]
    if (nrow(selected) != 3L) {
        stop(
            "Expected three successful repetitions for ",
            specification$implementation, "; found ", nrow(selected), ".",
            call. = FALSE
        )
    }
    data.frame(
        implementation = specification$implementation,
        family = specification$family,
        backend = specification$backend,
        platform = specification$platform,
        precision = "float32",
        ncomp = specification$ncomp,
        package_version = paste(unique(selected$package_version), collapse = ";"),
        source_id = paste(unique(selected$source_id), collapse = ";"),
        repetitions = nrow(selected),
        total_time_sec = median(selected$total_sec),
        time_q1_sec = unname(quantile(selected$total_sec, 0.25)),
        time_q3_sec = unname(quantile(selected$total_sec, 0.75)),
        RMSD = median(selected$metric_value),
        incremental_rss_mib = median(selected$incremental_peak_rss_mib),
        gpu_peak_mib = if (any(selected$gpu_peak_mib > 0)) {
            median(selected$gpu_peak_mib[selected$gpu_peak_mib > 0])
        } else {
            NA_real_
        },
        stringsAsFactors = FALSE
    )
}

summary <- do.call(rbind, lapply(
    seq_len(nrow(route_specification)),
    function(index) collect_route(route_specification[index, , drop = FALSE])
))

deposited_files <- sort(list.files(
    deposited_root,
    pattern = "^deposited_plssvd_cpu_irlba_k165_rep[0-9]+[.]csv$",
    full.names = TRUE
))
if (length(deposited_files) != 3L) {
    stop("Expected three deposited PLS-SVD/IRLBA repetitions.", call. = FALSE)
}
deposited <- do.call(rbind, lapply(deposited_files, function(path) {
    read.csv(path, check.names = FALSE)
}))
if (any(deposited$status != "success") ||
        any(deposited$ncomp != 165L) ||
        any(deposited$solver != "irlba") ||
        any(deposited$precision != "float64")) {
    stop("The deposited PLS-SVD/IRLBA evidence has an unexpected contract.")
}
deposited_summary <- data.frame(
    implementation = "Deposited PLS-SVD\nIRLBA (165)",
    family = "plssvd",
    backend = "cpu",
    platform = "linux_nvidia",
    precision = "float64",
    ncomp = 165L,
    package_version = paste(unique(deposited$analysis_package_version), collapse = ";"),
    source_id = "deposited fastsimpls implementation",
    repetitions = nrow(deposited),
    total_time_sec = median(deposited$total_time_sec),
    time_q1_sec = unname(quantile(deposited$total_time_sec, 0.25)),
    time_q3_sec = unname(quantile(deposited$total_time_sec, 0.75)),
    RMSD = median(deposited$RMSD),
    incremental_rss_mib = median(
        deposited$process_peak_rss_mb - deposited$baseline_rss_mb
    ),
    gpu_peak_mib = NA_real_,
    stringsAsFactors = FALSE
)
summary <- rbind(deposited_summary, summary)
write.csv(
    summary,
    file.path(table_dir, "figure3_nmr_family_components_summary.csv"),
    row.names = FALSE,
    na = ""
)

route_order <- c(
    "Deposited PLS-SVD\nIRLBA (165)", route_specification$implementation
)
summary$implementation <- factor(summary$implementation, levels = route_order)
colours <- c(
    "Deposited PLS-SVD\nIRLBA (165)" = "#555555",
    "PLS-SVD\nCPU (100)" = "#3B6FB6",
    "PLS-SVD\nCUDA (100)" = "#188977",
    "SIMPLS-family\nCPU (50)" = "#6C55A3",
    "SIMPLS-family\nCUDA (50)" = "#20A486"
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

bar_panel <- function(
        value, title, y_label, digits, error = FALSE, pseudo_log = FALSE) {
    labels <- if (value == "RMSD") {
        formatC(summary[[value]], format = "e", digits = 2)
    } else {
        formatC(summary[[value]], format = "f", digits = digits)
    }
    plot <- ggplot(
        summary,
        aes(implementation, .data[[value]], fill = implementation)
    ) +
        geom_col(width = 0.72) +
        geom_text(
            aes(label = labels), angle = 90, hjust = -0.15,
            size = 2.5, colour = "grey10"
        ) +
        scale_fill_manual(values = colours) +
        labs(title = title, x = NULL, y = y_label) +
        theme_publication(8) +
        theme(axis.text.x = element_text(angle = 28, hjust = 1, size = 7)) +
        coord_cartesian(clip = "off")
    if (error) {
        plot <- plot + geom_errorbar(
            aes(ymin = time_q1_sec, ymax = time_q3_sec),
            width = 0.2, linewidth = 0.4
        )
    }
    if (pseudo_log) {
        plot <- plot + scale_y_continuous(
            trans = scales::pseudo_log_trans(sigma = 0.25),
            breaks = c(0, 0.5, 1, 2, 5, 10, 50, 100, 500),
            labels = scales::label_number(accuracy = 0.1),
            limits = c(0, NA),
            expand = expansion(mult = c(0, 0.16))
        )
    } else {
        plot <- plot + scale_y_continuous(
            limits = c(0, NA), expand = expansion(mult = c(0, 0.24))
        )
    }
    plot
}

panel_a <- bar_panel(
    "total_time_sec", "A  Fitting plus prediction", "Seconds (pseudo-log)",
    3, TRUE, TRUE
)
panel_b <- bar_panel("RMSD", "B  Held-out prediction error", "RMSD", 6)

memory <- rbind(
    data.frame(
        implementation = summary$implementation,
        memory = summary$incremental_rss_mib,
        type = "Host RSS increment"
    ),
    data.frame(
        implementation = summary$implementation,
        memory = summary$gpu_peak_mib,
        type = "CUDA device peak"
    )
)
memory <- memory[is.finite(memory$memory), , drop = FALSE]
panel_c <- ggplot(memory, aes(implementation, memory, fill = type)) +
    geom_col(position = position_dodge(width = 0.8), width = 0.72) +
    scale_fill_manual(values = c(
        "Host RSS increment" = "#4C78A8",
        "CUDA device peak" = "#F58518"
    )) +
    scale_y_continuous(
        limits = c(0, NA), expand = expansion(mult = c(0, 0.1))
    ) +
    labs(title = "C  Peak memory", x = NULL, y = "MiB", fill = NULL) +
    theme_publication(8) +
    theme(
        axis.text.x = element_text(angle = 28, hjust = 1, size = 7),
        legend.position = "top"
    )

prediction_file <- function(family, backend, ncomp) {
    path <- file.path(
        prediction_root,
        paste0(family, "_", backend, "_prediction.rds")
    )
    if (!file.exists(path)) stop("Missing prediction evidence: ", path)
    path
}
prediction_paths <- c(
    "Deposited PLS-SVD\nIRLBA (165)" = file.path(
        deposited_root,
        "deposited_plssvd_cpu_irlba_k165_rep1_prediction.rds"
    ),
    "PLS-SVD\nCPU (100)" = prediction_file("plssvd", "cpu", 100L),
    "PLS-SVD\nCUDA (100)" = prediction_file("plssvd", "cuda", 100L),
    "SIMPLS-family\nCPU (50)" = prediction_file("simpls", "cpu", 50L),
    "SIMPLS-family\nCUDA (50)" = prediction_file("simpls", "cuda", 50L)
)
predictions <- lapply(prediction_paths, readRDS)
for (name in names(predictions)) {
    if (name == "Deposited PLS-SVD\nIRLBA (165)") next
    expected <- summary$ncomp[as.character(summary$implementation) == name]
    if (!identical(as.integer(predictions[[name]]$ncomp), as.integer(expected))) {
        stop("Prediction evidence has the wrong component count for ", name)
    }
}

per_sample <- do.call(rbind, lapply(names(predictions), function(name) {
    values <- predictions[[name]]$per_sample_rmsd
    if (is.null(values)) values <- predictions[[name]]$per_sample_RMSD
    if (is.null(values)) stop("Missing per-spectrum RMSD for ", name)
    data.frame(
        implementation = factor(name, levels = route_order),
        RMSD = as.numeric(values)
    )
}))
panel_d <- ggplot(per_sample, aes(implementation, RMSD, fill = implementation)) +
    geom_violin(scale = "width", trim = TRUE, alpha = 0.75, colour = "grey25") +
    geom_boxplot(width = 0.15, outlier.size = 0.35, fill = "white") +
    scale_fill_manual(values = colours) +
    labs(title = "D  Per-spectrum prediction error", x = NULL, y = "RMSD") +
    theme_publication(8) +
    theme(axis.text.x = element_text(angle = 28, hjust = 1, size = 7))

representative <- predictions[["SIMPLS-family\nCPU (50)"]]
sample_index <- which.min(abs(
    representative$per_sample_rmsd - median(representative$per_sample_rmsd)
))
ppm <- suppressWarnings(as.numeric(colnames(representative$observed)))
if (any(!is.finite(ppm))) ppm <- seq_len(ncol(representative$observed))
spectrum <- rbind(
    data.frame(
        ppm = ppm,
        intensity = representative$observed[sample_index, ],
        series = "Observed"
    ),
    data.frame(
        ppm = ppm,
        intensity = representative$predicted[sample_index, ],
        series = "Predicted"
    )
)
spectrum_panel <- function(limits, title) {
    ggplot(spectrum, aes(ppm, intensity, colour = series)) +
        geom_line(linewidth = 0.35, alpha = 0.9) +
        scale_colour_manual(values = c(
            "Observed" = "#202020", "Predicted" = "#D55E00"
        )) +
        scale_x_reverse() +
        coord_cartesian(xlim = sort(limits)) +
        labs(
            title = title, x = "Chemical shift (ppm)",
            y = "Intensity", colour = NULL
        ) +
        theme_publication(8) +
        theme(legend.position = "top")
}
panel_e <- spectrum_panel(
    c(12, 0), "E  Representative SIMPLS-family held-out spectrum"
)
panel_f <- spectrum_panel(c(1.7, 0.5), "F  Expanded spectral region")

figure <- ((panel_a | panel_b) / (panel_c | panel_d) / (panel_e | panel_f)) +
    plot_annotation(
        title = "NMR prediction and deposited PLS-SVD/IRLBA reference",
        subtitle = paste0(
            "PLS-SVD: 100 components; SIMPLS-family: 50 components; ",
            "deposited reference: 165 components; three isolated processes per route"
        ),
        theme = theme(
            plot.title = element_text(face = "bold", size = 13),
            plot.subtitle = element_text(size = 8.7)
        )
    )

png_path <- file.path(figure_dir, "figure3_nmr_family_components.png")
pdf_path <- file.path(figure_dir, "figure3_nmr_family_components.pdf")
ggsave(
    png_path, figure, width = 10.5, height = 12,
    units = "in", dpi = 320, bg = "white"
)
ggsave(
    pdf_path, figure, width = 10.5, height = 12,
    units = "in", device = cairo_pdf, bg = "white"
)

cat("Representative held-out sample index:", sample_index, "\n")
cat("Wrote:", png_path, "\n")
cat("Wrote:", pdf_path, "\n")
