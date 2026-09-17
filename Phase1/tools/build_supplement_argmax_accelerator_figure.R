#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 3L) {
    stop(
        paste(
            "Usage: build_supplement_argmax_accelerator_figure.R",
            "CUDA_RAW_CSV METAL_RAW_CSV OUTPUT_DIRECTORY"
        ),
        call. = FALSE
    )
}

suppressPackageStartupMessages({
    library(ggplot2)
    library(patchwork)
})

dataset_order <- c(
    "ccle", "cifar100", "gtex_v8", "metref", "retina", "tabula",
    "tcga_brca", "tcga_hnsc_methylation", "tcga_pan_cancer", "imagenet"
)
dataset_labels <- c(
    ccle = "CCLE", cifar100 = "CIFAR-100", gtex_v8 = "GTEx v8",
    metref = "MetRef", retina = "Retina", tabula = "Tabula Muris",
    tcga_brca = "TCGA-BRCA",
    tcga_hnsc_methylation = "TCGA-HNSC methylation",
    tcga_pan_cancer = "TCGA Pan-Cancer",
    imagenet = "ImageNet/DINOv2"
)
family_order <- c("plssvd", "simpls", "opls", "kernelpls")
family_labels <- c(
    plssvd = "PLS-SVD", simpls = "SIMPLS", opls = "OPLS",
    kernelpls = "linear kernel PLS"
)

read_argmax <- function(path, platform, accelerator) {
    data <- read.csv(path, check.names = FALSE, na.strings = c("", "NA"))
    required <- c(
        "dataset", "family", "backend", "precision", "classifier",
        "requested_ncomp", "replicate", "total_sec", "metric_name",
        "metric_value", "incremental_peak_rss_mib", "status"
    )
    missing <- setdiff(required, names(data))
    if (length(missing)) {
        stop("Missing columns in ", path, ": ", paste(missing, collapse = ", "))
    }
    data <- data[
        data$precision == "float32" & data$classifier == "argmax" &
            data$metric_name == "accuracy" & data$dataset %in% dataset_order &
            data$backend %in% c("cpu", tolower(accelerator)),
        , drop = FALSE
    ]
    if (!nrow(data)) {
        stop("No float32 argmax classification rows in ", path)
    }
    data$platform <- platform
    data$accelerator <- accelerator
    data
}

summarize_rows <- function(data) {
    key <- interaction(
        data$platform, data$accelerator, data$dataset, data$family,
        data$backend, data$requested_ncomp, drop = TRUE
    )
    do.call(rbind, lapply(split(data, key), function(block) {
        successful <- block[block$status == "success", , drop = FALSE]
        median_or_na <- function(name) {
            if (nrow(successful)) median(successful[[name]], na.rm = TRUE) else NA_real_
        }
        data.frame(
            platform = block$platform[[1L]],
            accelerator = block$accelerator[[1L]],
            dataset = block$dataset[[1L]],
            family = block$family[[1L]],
            backend = block$backend[[1L]],
            precision = "float32",
            classifier = "argmax",
            requested_ncomp = block$requested_ncomp[[1L]],
            attempted_repetitions = nrow(block),
            successful_repetitions = nrow(successful),
            median_total_sec = median_or_na("total_sec"),
            median_accuracy = median_or_na("metric_value"),
            median_incremental_rss_mib = median_or_na("incremental_peak_rss_mib"),
            status = if (nrow(successful)) {
                "success"
            } else {
                paste(sort(unique(block$status)), collapse = "/")
            },
            stringsAsFactors = FALSE
        )
    }))
}

pair_rows <- function(summary) {
    cpu <- summary[summary$backend == "cpu", , drop = FALSE]
    accelerator <- summary[summary$backend != "cpu", , drop = FALSE]
    paired <- merge(
        cpu, accelerator,
        by = c(
            "platform", "accelerator", "dataset", "family", "precision",
            "classifier", "requested_ncomp"
        ),
        suffixes = c("_cpu", "_accelerator"), all = TRUE
    )
    valid <- paired$status_cpu == "success" &
        paired$status_accelerator == "success"
    paired$runtime_ratio <- ifelse(
        valid,
        paired$median_total_sec_cpu / paired$median_total_sec_accelerator,
        NA_real_
    )
    paired$host_memory_ratio <- ifelse(
        valid & paired$median_incremental_rss_mib_cpu > 0,
        paired$median_incremental_rss_mib_accelerator /
            paired$median_incremental_rss_mib_cpu,
        NA_real_
    )
    paired$accuracy_difference <- ifelse(
        valid,
        paired$median_accuracy_accelerator - paired$median_accuracy_cpu,
        NA_real_
    )
    paired
}

cuda <- read_argmax(args[[1L]], "Intel/NVIDIA workstation", "CUDA")
metal <- read_argmax(args[[2L]], "Apple M3 workstation", "Metal")
summary <- summarize_rows(rbind(cuda, metal))
paired <- pair_rows(summary)

output_dir <- args[[3L]]
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
write.csv(
    summary, file.path(output_dir, "figure_s18_argmax_backend_summary.csv"),
    row.names = FALSE, na = ""
)
write.csv(
    paired, file.path(output_dir, "figure_s18_argmax_backend_ratios.csv"),
    row.names = FALSE, na = ""
)

theme_publication <- function() {
    theme_minimal(base_size = 8.6, base_family = "Helvetica") +
        theme(
            plot.title = element_text(face = "bold", size = 10),
            plot.subtitle = element_text(size = 7.5),
            axis.text = element_text(colour = "grey15"),
            axis.text.x = element_text(angle = 25, hjust = 1),
            panel.grid = element_blank(),
            legend.position = "bottom",
            legend.title = element_text(face = "bold")
        )
}

status_label <- function(data) {
    ifelse(
        data$status_cpu == "success" & data$status_accelerator == "success",
        "",
        toupper(ifelse(
            is.na(data$status_accelerator), data$status_cpu,
            data$status_accelerator
        ))
    )
}

ratio_panel <- function(data, accelerator, memory = FALSE) {
    data <- data[data$accelerator == accelerator, , drop = FALSE]
    data$dataset_label <- factor(
        data$dataset, levels = rev(dataset_order),
        labels = rev(unname(dataset_labels[dataset_order]))
    )
    data$family_label <- factor(
        data$family, levels = family_order,
        labels = unname(family_labels[family_order])
    )
    value <- if (memory) data$host_memory_ratio else data$runtime_ratio
    data$value <- ifelse(is.finite(value) & value > 0, value, NA_real_)
    data$log_value <- log2(data$value)
    data$label <- ifelse(
        is.na(data$value), status_label(data), sprintf("%.2fx", data$value)
    )
    title <- if (memory) {
        paste0(accelerator, "/CPU incremental host-RSS ratio")
    } else {
        paste0("CPU/", accelerator, " runtime ratio")
    }
    subtitle <- if (memory) {
        "Values below 1 indicate lower host-memory growth for the accelerator"
    } else {
        "Values above 1 indicate faster accelerator execution"
    }
    ggplot(data, aes(family_label, dataset_label, fill = log_value)) +
        geom_tile(colour = "white", linewidth = 0.5) +
        geom_text(aes(label = label), size = 2.2) +
        scale_fill_gradient2(
            low = if (memory) "#2166ac" else "#b2182b",
            mid = "#f7f7f7",
            high = if (memory) "#b2182b" else "#2166ac",
            midpoint = 0, na.value = "grey88",
            name = if (memory) {
                paste0("log2 ", accelerator, "/CPU")
            } else {
                paste0("log2 CPU/", accelerator)
            }
        ) +
        labs(title = title, subtitle = subtitle, x = NULL, y = NULL) +
        theme_publication()
}

figure <- (
    ratio_panel(paired, "CUDA") + ratio_panel(paired, "Metal")
) / (
    ratio_panel(paired, "CUDA", memory = TRUE) +
        ratio_panel(paired, "Metal", memory = TRUE)
) +
    plot_layout(guides = "collect") +
    plot_annotation(
        title = "Float32 argmax classification across accelerator backends",
        subtitle = paste(
            "PLS-SVD, SIMPLS, OPLS and linear kernel PLS; matched CPU/accelerator",
            "pairs on each computer."
        )
    ) &
    theme(legend.position = "bottom")

ggsave(
    file.path(output_dir, "figure_s18_argmax_accelerator.png"), figure,
    width = 10.5, height = 9.2, units = "in", dpi = 320, bg = "white"
)
ggsave(
    file.path(output_dir, "figure_s18_argmax_accelerator.pdf"), figure,
    width = 10.5, height = 9.2, units = "in", device = cairo_pdf,
    bg = "white"
)

cuda_figure <- ratio_panel(paired, "CUDA") /
    ratio_panel(paired, "CUDA", memory = TRUE) +
    plot_layout(guides = "collect") +
    plot_annotation(
        title = "Float32 argmax classification on Linux CPU and CUDA",
        subtitle = paste(
            "PLS-SVD, SIMPLS, OPLS and linear kernel PLS; matched",
            "CPU/CUDA pairs on the Intel/NVIDIA workstation."
        )
    ) & theme(legend.position = "bottom")
ggsave(
    file.path(output_dir, "figure_s14_argmax_cuda_cmpb.png"), cuda_figure,
    width = 7.4, height = 9.2, units = "in", dpi = 320, bg = "white"
)
ggsave(
    file.path(output_dir, "figure_s14_argmax_cuda_cmpb.pdf"), cuda_figure,
    width = 7.4, height = 9.2, units = "in", device = cairo_pdf,
    bg = "white"
)

metal_figure <- ratio_panel(paired, "Metal") /
    ratio_panel(paired, "Metal", memory = TRUE) +
    plot_layout(guides = "collect") +
    plot_annotation(
        title = "Float32 argmax classification on Mac CPU and Metal",
        subtitle = paste(
            "PLS-SVD, SIMPLS, OPLS and linear kernel PLS; matched",
            "CPU/Metal pairs on the Apple M3 workstation."
        )
    ) & theme(legend.position = "bottom")
ggsave(
    file.path(output_dir, "figure_jss_argmax_metal.png"), metal_figure,
    width = 7.4, height = 9.2, units = "in", dpi = 320, bg = "white"
)
ggsave(
    file.path(output_dir, "figure_jss_argmax_metal.pdf"), metal_figure,
    width = 7.4, height = 9.2, units = "in", device = cairo_pdf,
    bg = "white"
)
