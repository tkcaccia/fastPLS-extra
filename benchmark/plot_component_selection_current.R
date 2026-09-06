#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
input_dir <- if (length(args) >= 1L) args[[1L]] else
    "publication_results/0.99.39/current_release/component_selection"
output_dir <- if (length(args) >= 2L) args[[2L]] else input_dir

if (!requireNamespace("ggplot2", quietly = TRUE)) {
    stop("The benchmark renderer requires ggplot2.", call. = FALSE)
}

paths_file <- file.path(input_dir, "component_selection_paths.csv")
selected_file <- file.path(input_dir, "selected_components.csv")
if (!file.exists(paths_file) || !file.exists(selected_file)) {
    stop("Component-selection paths or selected-component table is missing.",
         call. = FALSE)
}

dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
paths <- utils::read.csv(paths_file, stringsAsFactors = FALSE)
selected <- utils::read.csv(selected_file, stringsAsFactors = FALSE)
stopifnot(nrow(paths) > 0L, nrow(selected) > 0L)
stopifnot(length(unique(paths$package_version)) == 1L)

dataset_labels <- c(
    cbmc_citeseq = "CBMC CITE-seq",
    ccle = "CCLE",
    cifar100 = "CIFAR-100",
    gtex_v8 = "GTEx v8",
    metref = "MetRef",
    prism = "PRISM",
    retina = "Retina",
    tabula = "Tabula Muris",
    tcga_brca = "TCGA-BRCA",
    tcga_hnsc_methylation = "TCGA-HNSC methylation",
    tcga_pan_cancer = "TCGA Pan-Cancer"
)
family_labels <- c(
    plssvd = "PLS-SVD",
    simpls = "SIMPLS",
    opls = "OPLS",
    kernelpls = "Kernel PLS"
)
palette <- c(
    "PLS-SVD" = "#1B4965",
    "SIMPLS" = "#D1495B",
    "OPLS" = "#2A9D8F",
    "Kernel PLS" = "#E9A03B"
)

decorate <- function(data) {
    data$Dataset <- unname(dataset_labels[data$dataset])
    data$Family <- factor(
        unname(family_labels[data$family]),
        levels = unname(family_labels)
    )
    data
}
paths <- decorate(paths)
selected <- decorate(selected)
selected_points <- merge(
    selected,
    paths[c("dataset", "family", "ncomp", "metric_value")],
    by.x = c("dataset", "family", "selected_ncomp"),
    by.y = c("dataset", "family", "ncomp"),
    all.x = TRUE,
    sort = FALSE
)
selected_points <- decorate(selected_points)

theme_publication <- function() {
    ggplot2::theme_bw(base_size = 10) +
        ggplot2::theme(
            panel.grid.minor = ggplot2::element_blank(),
            panel.grid.major = ggplot2::element_line(
                colour = "#E5E5E5", linewidth = 0.25
            ),
            strip.background = ggplot2::element_rect(
                fill = "#F2F0EA", colour = "#B8B8B8"
            ),
            strip.text = ggplot2::element_text(face = "bold", size = 8.5),
            legend.position = "bottom",
            legend.title = ggplot2::element_blank(),
            axis.title = ggplot2::element_text(face = "bold"),
            plot.title = ggplot2::element_text(face = "bold", size = 13),
            plot.subtitle = ggplot2::element_text(size = 9)
        )
}

plot_group <- function(task_type, filename, title, y_label, columns) {
    values <- paths[paths$task_type == task_type, , drop = FALSE]
    points <- selected_points[
        selected_points$dataset %in% unique(values$dataset), , drop = FALSE
    ]
    figure <- ggplot2::ggplot(
        values,
        ggplot2::aes(x = ncomp, y = metric_value, colour = Family)
    ) +
        ggplot2::geom_line(linewidth = 0.55, alpha = 0.9) +
        ggplot2::geom_point(
            data = points,
            ggplot2::aes(x = selected_ncomp, y = metric_value, colour = Family),
            inherit.aes = FALSE,
            shape = 21,
            fill = "white",
            stroke = 0.9,
            size = 2.4
        ) +
        ggplot2::facet_wrap(~Dataset, scales = "free", ncol = columns) +
        ggplot2::scale_colour_manual(values = palette, drop = FALSE) +
        ggplot2::labs(
            title = title,
            subtitle = paste0(
                "Ten-fold training-only selection; open circles identify the best value ",
                "within each evaluated family-specific grid"
            ),
            x = "Number of components",
            y = y_label
        ) +
        theme_publication()
    ggplot2::ggsave(
        file.path(output_dir, paste0(filename, ".png")), figure,
        width = 8.0, height = if (task_type == "classification") 7.2 else 4.3,
        dpi = 320, bg = "white"
    )
    ggplot2::ggsave(
        file.path(output_dir, paste0(filename, ".pdf")), figure,
        width = 8.0, height = if (task_type == "classification") 7.2 else 4.3,
        device = grDevices::cairo_pdf, bg = "white"
    )
}

plot_group(
    "classification",
    "component_selection_classification",
    "Training-only component paths for classification",
    "Cross-validated accuracy",
    3L
)
plot_group(
    "regression",
    "component_selection_regression",
    "Training-only component paths for multivariate regression",
    "Cross-validated RMSD",
    2L
)

selected_output <- selected[c(
    "dataset", "family", "selected_ncomp", "selection_status", "grid_min",
    "grid_max", "intrinsic_limit", "selection_metric", "selected_metric"
)]
names(selected_output) <- c(
    "dataset", "family", "selected_components", "selection_status",
    "grid_min", "grid_max", "intrinsic_limit", "selection_metric",
    "cross_validated_metric"
)
utils::write.csv(
    selected_output,
    file.path(output_dir, "component_selection_publication_table.csv"),
    row.names = FALSE
)

status_counts <- as.data.frame(table(selected$selection_status),
                               stringsAsFactors = FALSE)
names(status_counts) <- c("selection_status", "count")
status_counts$package_version <- unique(paths$package_version)
status_counts$kfold <- unique(paths$kfold)
status_counts$seed <- unique(paths$seed)
utils::write.csv(
    status_counts,
    file.path(output_dir, "component_selection_status_summary.csv"),
    row.names = FALSE
)

message("Component-selection figures and tables written to ", output_dir)
