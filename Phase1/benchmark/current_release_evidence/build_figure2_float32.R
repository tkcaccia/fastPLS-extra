#!/usr/bin/env Rscript

options(stringsAsFactors = FALSE)
suppressPackageStartupMessages({
    library(ggplot2)
    library(patchwork)
})

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 3L) {
    stop(
        paste(
            "Usage: build_figure2_float32.R CUDA_CSV METAL_CSV",
            "OUTPUT_DIRECTORY"
        ),
        call. = FALSE
    )
}

cuda_path <- normalizePath(args[[1L]], mustWork = TRUE)
metal_path <- normalizePath(args[[2L]], mustWork = TRUE)
output_dir <- normalizePath(args[[3L]], mustWork = FALSE)
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

dataset_order <- c(
    "ccle", "cifar100", "gtex_v8", "metref", "retina", "tabula",
    "tcga_brca", "tcga_hnsc_methylation", "tcga_pan_cancer",
    "cbmc_citeseq", "prism", "nmr", "imagenet"
)
dataset_labels <- c(
    ccle = "CCLE", cifar100 = "CIFAR-100", gtex_v8 = "GTEx v8",
    metref = "MetRef", retina = "Retina", tabula = "Tabula Muris",
    tcga_brca = "TCGA-BRCA",
    tcga_hnsc_methylation = "TCGA-HNSC methylation",
    tcga_pan_cancer = "TCGA Pan-Cancer",
    cbmc_citeseq = "CBMC CITE-seq", prism = "PRISM", nmr = "NMR",
    imagenet = "ImageNet/DINOv2"
)
family_order <- c("plssvd", "simpls", "opls", "kernelpls")
family_labels <- c(
    plssvd = "PLS-SVD", simpls = "SIMPLS", opls = "OPLS",
    kernelpls = "linear kernel PLS"
)

read_results <- function(path, platform) {
    data <- read.csv(path, check.names = FALSE, na.strings = c("", "NA"))
    required <- c(
        "package_version", "source_id", "dataset", "family", "backend",
        "precision", "requested_ncomp",
        "replicate", "total_sec", "metric_value", "incremental_peak_rss_mib",
        "gpu_peak_mib", "metric_name", "effective_oversample",
        "effective_power", "seed", "status", "execution_route"
    )
    missing <- setdiff(required, names(data))
    if (length(missing)) {
        stop("Missing columns in ", path, ": ", paste(missing, collapse = ", "))
    }
    if (any(data$precision != "float32", na.rm = TRUE)) {
        stop("Figure 2 accepts float32 benchmark rows only: ", path)
    }
    data$platform <- platform
    data
}

summarize_results <- function(data) {
    key <- interaction(
        data$platform, data$dataset, data$family, data$backend,
        data$requested_ncomp, drop = TRUE
    )
    do.call(rbind, lapply(split(data, key), function(block) {
        successful <- block[block$status == "success", , drop = FALSE]
        status <- if (nrow(successful)) {
            "success"
        } else {
            paste(sort(unique(block$status)), collapse = "/")
        }
        med <- function(name) {
            if (nrow(successful)) median(successful[[name]], na.rm = TRUE) else NA_real_
        }
        spread <- function(name) {
            if (nrow(successful) > 1L) IQR(successful[[name]], na.rm = TRUE) else NA_real_
        }
        data.frame(
            package_version = block$package_version[[1L]],
            source_id = block$source_id[[1L]],
            platform = block$platform[[1L]],
            dataset = block$dataset[[1L]],
            family = block$family[[1L]],
            backend = block$backend[[1L]],
            precision = "float32",
            metric_name = paste(unique(block$metric_name), collapse = "/"),
            requested_ncomp = block$requested_ncomp[[1L]],
            attempted_repetitions = nrow(block),
            successful_repetitions = nrow(successful),
            median_total_sec = med("total_sec"),
            iqr_total_sec = spread("total_sec"),
            median_metric = med("metric_value"),
            iqr_metric = spread("metric_value"),
            median_incremental_rss_mib = med("incremental_peak_rss_mib"),
            median_gpu_peak_mib = med("gpu_peak_mib"),
            effective_oversample = if (nrow(successful)) {
                paste(unique(na.omit(successful$effective_oversample)), collapse = "/")
            } else {
                ""
            },
            effective_power = if (nrow(successful)) {
                paste(unique(na.omit(successful$effective_power)), collapse = "/")
            } else {
                ""
            },
            seed = if (nrow(successful)) {
                paste(unique(na.omit(successful$seed)), collapse = "/")
            } else {
                ""
            },
            execution_route = if (nrow(successful)) {
                paste(sort(unique(successful$execution_route)), collapse = "; ")
            } else {
                ""
            },
            status = status,
            stringsAsFactors = FALSE
        )
    }))
}

pair_platform <- function(summary, accelerator) {
    cpu <- summary[summary$backend == "cpu", , drop = FALSE]
    acc <- summary[summary$backend == tolower(accelerator), , drop = FALSE]
    paired <- merge(
        cpu, acc,
        by = c(
            "platform", "dataset", "family", "precision",
            "metric_name", "requested_ncomp"
        ),
        suffixes = c("_cpu", "_accelerator"), all = TRUE
    )
    paired$accelerator <- accelerator
    both <- paired$status_cpu == "success" &
        paired$status_accelerator == "success"
    paired$runtime_ratio <- ifelse(
        both,
        paired$median_total_sec_cpu / paired$median_total_sec_accelerator,
        NA_real_
    )
    paired$host_memory_ratio <- ifelse(
        both & paired$median_incremental_rss_mib_cpu > 0,
        paired$median_incremental_rss_mib_accelerator /
            paired$median_incremental_rss_mib_cpu,
        NA_real_
    )
    paired$metric_difference <- ifelse(
        both,
        paired$median_metric_accelerator - paired$median_metric_cpu,
        NA_real_
    )
    paired
}

cuda <- read_results(cuda_path, "Intel/NVIDIA workstation")
metal <- read_results(metal_path, "Apple M3 workstation")
versions <- unique(c(cuda$package_version, metal$package_version))
sources <- unique(c(cuda$source_id, metal$source_id))
if (length(versions) != 1L || length(sources) != 1L) {
    stop(
        "Figure 2 inputs must use one package version and one source ID.",
        call. = FALSE
    )
}
summary <- rbind(summarize_results(cuda), summarize_results(metal))
paired <- rbind(
    pair_platform(
        summary[summary$platform == "Intel/NVIDIA workstation", ], "CUDA"
    ),
    pair_platform(
        summary[summary$platform == "Apple M3 workstation", ], "Metal"
    )
)

write.csv(
    summary, file.path(output_dir, "figure2_float32_backend_summary.csv"),
    row.names = FALSE, na = ""
)
write.csv(
    paired, file.path(output_dir, "figure2_float32_backend_ratios.csv"),
    row.names = FALSE, na = ""
)

theme_publication <- function() {
    theme_minimal(base_size = 8.5, base_family = "Helvetica") +
        theme(
            plot.title = element_text(face = "bold", size = 10),
            plot.subtitle = element_text(size = 8),
            axis.text = element_text(colour = "grey15"),
            axis.text.x = element_text(angle = 28, hjust = 1),
            panel.grid = element_blank(),
            legend.position = "bottom",
            legend.title = element_text(face = "bold")
        )
}

status_label <- function(data) {
    ifelse(
        data$status_accelerator == "success" & data$status_cpu == "success",
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
        "Values below 1 indicate lower host-memory growth for the accelerator route"
    } else {
        "Values above 1 indicate faster accelerator execution"
    }
    ggplot(data, aes(family_label, dataset_label, fill = log_value)) +
        geom_tile(colour = "white", linewidth = 0.55) +
        geom_text(aes(label = label), size = 2.25) +
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

cuda_figure <- (
    ratio_panel(paired, "CUDA") /
        ratio_panel(paired, "CUDA", memory = TRUE)
) +
    plot_layout(guides = "collect") +
    plot_annotation(
        title = "Float32 CPU and CUDA execution across PLS workloads",
        subtitle = paste(
            paste0(
                "fastPLS ", versions[[1L]], ". CPU/CUDA pairs: Intel Core ",
                "i7-13700 and NVIDIA RTX 5060 Ti.\n"
            ),
            "Fresh-process totals include accelerator initialization, transfer,",
            "synchronization and prediction."
        ),
        tag_levels = "A"
    ) &
    theme(legend.position = "bottom")

ggsave(
    file.path(output_dir, "figure2_backend_runtime.png"), cuda_figure,
    width = 7.2, height = 10.2, units = "in", dpi = 320, bg = "white"
)
ggsave(
    file.path(output_dir, "figure2_backend_runtime.pdf"), cuda_figure,
    width = 7.2, height = 10.2, units = "in", device = cairo_pdf,
    bg = "white"
)

metal_figure <- (
    ratio_panel(paired, "Metal") /
        ratio_panel(paired, "Metal", memory = TRUE)
) +
    plot_layout(guides = "collect") +
    plot_annotation(
        title = "Float32 CPU and Metal execution across PLS workloads",
        subtitle = paste(
            paste0(
                "fastPLS ", versions[[1L]],
                ". CPU/Metal pairs were measured on an Apple M3.\n"
            ),
            "Fresh-process totals include Metal initialization,",
            "synchronization and prediction."
        ),
        tag_levels = "A"
    ) &
    theme(legend.position = "bottom")

ggsave(
    file.path(output_dir, "figureS19_metal_backend_runtime.png"), metal_figure,
    width = 7.2, height = 10.2, units = "in", dpi = 320, bg = "white"
)
ggsave(
    file.path(output_dir, "figureS19_metal_backend_runtime.pdf"), metal_figure,
    width = 7.2, height = 10.2, units = "in", device = cairo_pdf,
    bg = "white"
)
