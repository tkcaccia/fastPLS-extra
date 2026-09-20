#!/usr/bin/env Rscript

# Response-wise and intensity-stratified error analysis for the fixed NMR test set.

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 3L) {
    stop(
        paste(
            "Usage: analyze_nmr_localized_error.R",
            "PREDICTION_ROOT DEPOSITED_PREDICTION OUTPUT_DIR"
        ),
        call. = FALSE
    )
}

suppressPackageStartupMessages({
    library(ggplot2)
    library(patchwork)
})

prediction_root <- normalizePath(args[[1L]], mustWork = TRUE)
deposited_path <- normalizePath(args[[2L]], mustWork = TRUE)
output_dir <- normalizePath(args[[3L]], mustWork = FALSE)
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

paths <- c(
    "Deposited PLS-SVD (165)" = deposited_path,
    "PLS-SVD CPU (100)" = file.path(
        prediction_root, "plssvd_cpu_prediction.rds"
    ),
    "PLS-SVD CUDA (100)" = file.path(
        prediction_root, "plssvd_cuda_prediction.rds"
    ),
    "SIMPLS-family CPU (50)" = file.path(
        prediction_root, "simpls_cpu_prediction.rds"
    ),
    "SIMPLS-family CUDA (50)" = file.path(
        prediction_root, "simpls_cuda_prediction.rds"
    )
)
if (any(!file.exists(paths))) {
    stop("Missing prediction files: ", paste(paths[!file.exists(paths)], collapse = ", "))
}

objects <- lapply(paths, readRDS)
reference <- objects[["SIMPLS-family CPU (50)"]]
observed <- reference$observed
if (is.null(observed) || !is.matrix(observed)) {
    stop("The reference prediction object does not contain the observed matrix.")
}
ppm <- suppressWarnings(as.numeric(colnames(observed)))
if (length(ppm) != ncol(observed) || any(!is.finite(ppm))) {
    stop("The NMR response columns do not contain a complete numeric ppm axis.")
}

deposited_observed <- objects[["Deposited PLS-SVD (165)"]]$observed
same_layout <- identical(dim(observed), dim(deposited_observed)) &&
    identical(dimnames(observed), dimnames(deposited_observed))
storage_difference <- if (same_layout) {
    max(abs(observed - deposited_observed))
} else {
    Inf
}
if (!same_layout || !is.finite(storage_difference) || storage_difference > 5e-8) {
    stop("The deposited and fastPLS prediction objects use different observations.")
}

observed_rms <- sqrt(colMeans(observed^2))
ordered <- order(observed_rms, seq_along(observed_rms))
stratum_number <- integer(length(observed_rms))
stratum_number[ordered] <- pmin(
    4L,
    ceiling(seq_along(ordered) * 4 / length(ordered))
)
stratum <- factor(
    paste0("Q", stratum_number),
    levels = paste0("Q", 1:4),
    labels = c("Q1 lowest", "Q2", "Q3", "Q4 highest")
)

response_rows <- list()
summary_rows <- list()
for (label in names(objects)) {
    object <- objects[[label]]
    response_rmsd <- object$per_response_rmsd
    if (is.null(response_rmsd)) {
        if (is.null(object$predicted) || is.null(object$observed)) {
            stop("Missing response-wise evidence for ", label)
        }
        response_rmsd <- sqrt(colMeans((object$observed - object$predicted)^2))
    }
    if (length(response_rmsd) != ncol(observed)) {
        stop("Unexpected response count for ", label)
    }
    response_rows[[label]] <- data.frame(
        implementation = label,
        response_index = seq_along(response_rmsd),
        ppm = ppm,
        observed_rms = observed_rms,
        intensity_stratum = stratum,
        response_rmsd = as.numeric(response_rmsd),
        stringsAsFactors = FALSE
    )
    for (level in levels(stratum)) {
        index <- which(stratum == level)
        values <- as.numeric(response_rmsd[index])
        summary_rows[[length(summary_rows) + 1L]] <- data.frame(
            implementation = label,
            intensity_stratum = level,
            response_bins = length(index),
            observed_rms_min = min(observed_rms[index]),
            observed_rms_max = max(observed_rms[index]),
            stratum_rmsd = sqrt(mean(values^2)),
            median_response_rmsd = median(values),
            response_rmsd_q25 = unname(quantile(values, 0.25)),
            response_rmsd_q75 = unname(quantile(values, 0.75)),
            response_rmsd_q95 = unname(quantile(values, 0.95)),
            stringsAsFactors = FALSE
        )
    }
}

response_data <- do.call(rbind, response_rows)
summary_data <- do.call(rbind, summary_rows)
summary_data$intensity_stratum <- factor(
    summary_data$intensity_stratum,
    levels = levels(stratum)
)

write.csv(
    response_data,
    file.path(output_dir, "nmr_response_wise_error.csv"),
    row.names = FALSE
)
write.csv(
    summary_data,
    file.path(output_dir, "nmr_intensity_stratified_error.csv"),
    row.names = FALSE
)

top_rows <- do.call(rbind, lapply(split(response_data, response_data$implementation), function(data) {
    data[order(data$response_rmsd, decreasing = TRUE)[seq_len(20L)], ]
}))
write.csv(
    top_rows,
    file.path(output_dir, "nmr_largest_response_errors.csv"),
    row.names = FALSE
)

route_order <- names(paths)
response_data$implementation <- factor(
    response_data$implementation,
    levels = route_order
)
summary_data$implementation <- factor(
    summary_data$implementation,
    levels = route_order
)
colours <- c(
    "Deposited PLS-SVD (165)" = "#555555",
    "PLS-SVD CPU (100)" = "#3B6FB6",
    "PLS-SVD CUDA (100)" = "#188977",
    "SIMPLS-family CPU (50)" = "#6C55A3",
    "SIMPLS-family CUDA (50)" = "#D55E00"
)
line_types <- c(
    "Deposited PLS-SVD (165)" = "solid",
    "PLS-SVD CPU (100)" = "solid",
    "PLS-SVD CUDA (100)" = "dashed",
    "SIMPLS-family CPU (50)" = "solid",
    "SIMPLS-family CUDA (50)" = "dashed"
)

theme_publication <- function() {
    theme_bw(base_size = 10, base_family = "Helvetica") +
        theme(
            plot.title = element_text(face = "bold"),
            panel.grid.minor = element_blank(),
            legend.position = "bottom",
            legend.title = element_blank()
        )
}

panel_a <- ggplot(
    response_data,
    aes(ppm, response_rmsd, colour = implementation, linetype = implementation)
) +
    geom_line(linewidth = 0.32, alpha = 0.78) +
    scale_x_reverse() +
    scale_y_log10() +
    scale_colour_manual(values = colours) +
    scale_linetype_manual(values = line_types) +
    labs(
        title = "A  Response-wise prediction error",
        x = "Chemical shift (ppm)",
        y = "Response-wise RMSD (log scale)"
    ) +
    theme_publication()

panel_b <- ggplot(
    summary_data,
    aes(
        intensity_stratum, stratum_rmsd,
        colour = implementation, group = implementation,
        shape = implementation
    )
) +
    geom_line(linewidth = 0.55, position = position_dodge(width = 0.20)) +
    geom_point(size = 2.1, position = position_dodge(width = 0.20)) +
    scale_y_log10() +
    scale_colour_manual(values = colours) +
    labs(
        title = "B  Error by observed-intensity quartile",
        subtitle = "Quartiles contain equal numbers of response bins",
        x = "Observed response RMS intensity",
        y = "RMSD across samples and response bins (log scale)"
    ) +
    theme_publication()

figure <- panel_a / panel_b +
    plot_annotation(
        title = "Localized NMR prediction error on the fixed test partition",
        subtitle = paste(
            "321 held-out spectra and 28,355 response bins; intensity strata",
            "defined from observed test-response RMS amplitude"
        ),
        theme = theme(
            plot.title = element_text(face = "bold", size = 13),
            plot.subtitle = element_text(size = 9)
        )
    )

ggsave(
    file.path(output_dir, "figureS14_nmr_localized_error.png"),
    figure, width = 10.5, height = 8.2, units = "in", dpi = 320, bg = "white"
)
ggsave(
    file.path(output_dir, "figureS14_nmr_localized_error.pdf"),
    figure, width = 10.5, height = 8.2, units = "in", device = cairo_pdf,
    bg = "white"
)

cat(normalizePath(output_dir, winslash = "/", mustWork = TRUE), "\n")
