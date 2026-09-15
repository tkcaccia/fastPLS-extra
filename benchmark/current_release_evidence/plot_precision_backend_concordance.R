#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 3L) {
    stop(
        "Usage: plot_precision_backend_concordance.R COMPARISONS PNG PDF",
        call. = FALSE
    )
}

input <- read.csv(args[[1L]], stringsAsFactors = FALSE, check.names = FALSE)
png_path <- args[[2L]]
pdf_path <- args[[3L]]

routes <- c(
    "Linux CPU float32", "CUDA float64", "CUDA float32",
    "Mac CPU float64", "Mac CPU float32", "Metal float32"
)
route_labels <- c(
    "Linux CPU\nfloat32", "CUDA\nfloat64", "CUDA\nfloat32",
    "Mac CPU\nfloat64", "Mac CPU\nfloat32", "Metal\nfloat32"
)
families <- c("plssvd", "simpls", "opls", "kernelpls")
family_labels <- c(
    plssvd = "PLS-SVD", simpls = "SIMPLS", opls = "OPLS",
    kernelpls = "linear kernel PLS"
)
datasets <- c(
    "ccle", "cifar100", "gtex_v8", "metref", "retina", "tabula",
    "tcga_brca", "tcga_hnsc_methylation", "tcga_pan_cancer", "imagenet",
    "cbmc_citeseq", "prism", "nmr"
)
dataset_labels <- c(
    ccle = "CCLE", cifar100 = "CIFAR-100", gtex_v8 = "GTEx v8",
    metref = "MetRef", retina = "Retina", tabula = "Tabula Muris",
    tcga_brca = "TCGA-BRCA",
    tcga_hnsc_methylation = "TCGA-HNSC methylation",
    tcga_pan_cancer = "TCGA Pan-Cancer", imagenet = "ImageNet/DINOv2",
    cbmc_citeseq = "CBMC CITE-seq", prism = "PRISM", nmr = "NMR"
)

make_matrix <- function(task_type) {
    current <- input[input$task_type == task_type, , drop = FALSE]
    current$row_label <- paste(
        dataset_labels[current$dataset], family_labels[current$family], sep = " / "
    )
    wanted_datasets <- if (task_type == "classification") {
        datasets[seq_len(10L)]
    } else {
        datasets[11:13]
    }
    wanted_rows <- unlist(lapply(
        wanted_datasets,
        function(dataset) paste(dataset_labels[[dataset]], family_labels[families], sep = " / ")
    ), use.names = FALSE)
    result <- matrix(
        NA_real_, nrow = length(wanted_rows), ncol = length(routes),
        dimnames = list(wanted_rows, route_labels)
    )
    for (i in seq_len(nrow(current))) {
        row_index <- match(current$row_label[[i]], wanted_rows)
        column_index <- match(current$route[[i]], routes)
        if (!is.na(row_index) && !is.na(column_index)) {
            result[row_index, column_index] <- current$display_change[[i]]
        }
    }
    result
}

classification <- make_matrix("classification")
regression <- make_matrix("regression")

palette <- colorRampPalette(c("#2C7BB6", "#EAF2F8", "#FFFFFF", "#FDE0DD", "#C51B2A"))(201)

draw_heatmap <- function(values, panel, title, subtitle, limit, digits) {
    nr <- nrow(values)
    nc <- ncol(values)
    par(mar = c(6.0, 15.0, 3.7, 2.2))
    plot(
        c(0.5, nc + 0.5), c(0.5, nr + 0.5), type = "n", axes = FALSE,
        xlab = "", ylab = "", xaxs = "i", yaxs = "i"
    )
    clipped <- values
    clipped[] <- pmax(-limit, pmin(limit, values))
    for (row in seq_len(nr)) {
        for (column in seq_len(nc)) {
            value <- clipped[row, column]
            fill <- if (is.na(value)) {
                "#E5E5E5"
            } else {
                palette[[round((value + limit) / (2 * limit) * 200) + 1L]]
            }
            rect(column - 0.5, nr - row + 0.5, column + 0.5, nr - row + 1.5,
                 col = fill, border = "white", lwd = 0.7)
            label <- if (is.na(values[row, column])) {
                "NA"
            } else {
                formatC(values[row, column], format = "f", digits = digits)
            }
            text(column, nr - row + 1, label, cex = if (nr > 20) 0.52 else 0.72)
        }
    }
    axis(1, at = seq_len(nc), labels = colnames(values), las = 2,
         tick = FALSE, cex.axis = 0.78, line = -0.4)
    axis(2, at = nr:1, labels = rownames(values), las = 2,
         tick = FALSE, cex.axis = if (nr > 20) 0.60 else 0.76, line = -0.4)
    mtext(paste0(panel, "  ", title), side = 3, adj = 0, line = 1.5,
          font = 2, cex = 1.02)
    mtext(subtitle, side = 3, adj = 0, line = 0.25, cex = 0.75)
    box(col = "#BDBDBD")
}

render <- function(device) {
    device()
    layout(matrix(c(1, 2), ncol = 1), heights = c(3.0, 1.25))
    draw_heatmap(
        classification, "A", "Classification accuracy concordance",
        "Cell values are accuracy changes in percentage points relative to Linux CPU float64",
        limit = 0.5, digits = 2
    )
    draw_heatmap(
        regression, "B", "Regression RMSD concordance",
        "Cell values are relative RMSD changes (%) relative to Linux CPU float64",
        limit = 3.0, digits = 2
    )
    dev.off()
}

dir.create(dirname(png_path), recursive = TRUE, showWarnings = FALSE)
render(function() png(png_path, width = 2400, height = 3000, res = 240))
render(function() pdf(pdf_path, width = 10, height = 12.5, useDingbats = FALSE))
