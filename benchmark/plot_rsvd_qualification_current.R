args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 4L) {
    stop("usage: plot_rsvd_qualification_current.R CPU_CSV CUDA_CSV METAL_CSV OUT_PNG")
}

read_backend <- function(path, label) {
    x <- read.csv(path, stringsAsFactors = FALSE)
    expected_backend <- tolower(label)
    x <- x[
        grepl("rsvd", x$route) & x$backend == expected_backend,
        ,
        drop = FALSE
    ]
    if (!nrow(x)) {
        stop("No ", label, " rSVD rows were found in ", path)
    }
    x$backend_label <- label
    x
}

dat <- rbind(
    read_backend(args[[1L]], "CPU"),
    read_backend(args[[2L]], "CUDA"),
    read_backend(args[[3L]], "Metal")
)
dat$backend_label <- factor(dat$backend_label, levels = c("CPU", "CUDA", "Metal"))
cols <- c(CPU = "#0072B2", CUDA = "#D55E00", Metal = "#009E73")
positive_floor <- function(x) {
    minimum <- min(x[is.finite(x) & x > 0], na.rm = TRUE)
    x[is.finite(x) & x <= 0] <- minimum / 10
    x
}
dat$prediction_relative_error <- positive_floor(dat$prediction_relative_error)
dat$metric_absolute_difference <- positive_floor(dat$metric_absolute_difference)
dat$prediction_tolerance_ratio <- dat$prediction_relative_error / 0.01
dat$metric_tolerance_ratio <- dat$metric_absolute_difference / 0.005

png(args[[4L]], width = 2200, height = 1050, res = 220)
par(mfrow = c(1, 2), mar = c(5, 5, 2.5, 1), oma = c(0, 0, 1, 0))
boxplot(
    prediction_tolerance_ratio ~ backend_label,
    data = dat,
    log = "y",
    col = cols,
    border = "grey25",
    ylab = "Prediction error / tolerance (log scale)",
    xlab = "Backend",
    main = "A  Prediction agreement",
    outline = TRUE
)
abline(h = 1, lty = 2, lwd = 2, col = "#7F0000")
mtext("Dashed line = tolerance", side = 3, line = 0.2, cex = 0.75)

boxplot(
    metric_tolerance_ratio ~ backend_label,
    data = dat,
    log = "y",
    col = cols,
    border = "grey25",
    ylab = "Metric difference / tolerance (log scale)",
    xlab = "Backend",
    main = "B  Endpoint agreement",
    outline = TRUE
)
abline(h = 1, lty = 2, lwd = 2, col = "#7F0000")
mtext("Dashed line = tolerance", side = 3, line = 0.2, cex = 0.75)
mtext(
    paste(
        "fastPLS 0.99.39 rSVD qualification:",
        "shape-specific automatic controls and forced 32/5 routes; three seeds"
    ),
    outer = TRUE,
    side = 3,
    line = -0.2,
    font = 2,
    cex = 0.95
)
dev.off()

summary_rows <- do.call(rbind, lapply(
    split(dat, dat$backend_label),
    function(x) {
        data.frame(
            backend = as.character(x$backend_label[[1L]]),
            control_profiles = paste(
                sort(unique(x$rsvd_control_profile)), collapse = ";"
            ),
            effective_controls = paste(
                sort(unique(paste0(
                    x$rsvd_effective_oversample,
                    "/",
                    x$rsvd_effective_power
                ))),
                collapse = ";"
            ),
            comparisons = nrow(x),
            comparisons_within_tolerance = sum(
                x$numerical_status == "within_tolerance", na.rm = TRUE
            ),
            max_prediction_relative_error = max(
                x$prediction_relative_error, na.rm = TRUE
            ),
            min_prediction_correlation = min(
                x$prediction_correlation, na.rm = TRUE
            ),
            max_score_relative_error = max(
                x$score_relative_error, na.rm = TRUE
            ),
            min_label_agreement = min(x$label_agreement, na.rm = TRUE),
            max_metric_absolute_difference = max(
                x$metric_absolute_difference, na.rm = TRUE
            ),
            stringsAsFactors = FALSE
        )
    }
))
summary_path <- sub("[.]png$", "_summary.csv", args[[4L]])
write.csv(summary_rows, summary_path, row.names = FALSE)
