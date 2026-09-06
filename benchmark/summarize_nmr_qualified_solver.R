#!/usr/bin/env Rscript

# Summarize the current NMR solver/backend campaign without copying its full
# prediction matrices. Run this on the machine that holds the prediction RDS
# files, then copy the compact CSV outputs into the manuscript evidence archive.

options(stringsAsFactors = FALSE)
`%||%` <- function(x, y) if (is.null(x)) y else x

parse_args <- function(x = commandArgs(trailingOnly = TRUE)) {
  out <- list()
  for (item in x) {
    if (!startsWith(item, "--")) next
    fields <- strsplit(substring(item, 3L), "=", fixed = TRUE)[[1L]]
    out[[gsub("-", "_", fields[[1L]])]] <-
      if (length(fields) > 1L) paste(fields[-1L], collapse = "=") else "TRUE"
  }
  out
}
args <- parse_args()
arg <- function(name, default = NULL) {
  value <- args[[name]]
  if (is.null(value) || !nzchar(value)) default else value
}

input_dir <- normalizePath(arg(
  "input_dir",
  "publication_results/0.99.39/current_release/nmr"
), mustWork = TRUE)
output_dir <- arg("output_dir", file.path(input_dir, "summary"))
deposited_prediction <- arg("deposited_prediction", "")
plssvd_ncomp <- as.integer(arg("plssvd_ncomp", "5"))
simpls_ncomp <- as.integer(arg("simpls_ncomp", "50"))
analysis_prefix <- arg("analysis_prefix", "selected")
representative_ncomp <- if (identical(analysis_prefix, "fixed165")) {
  165L
} else {
  simpls_ncomp
}
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

routes <- data.frame(
  family = rep(c("plssvd", "simpls"), each = 3L),
  backend = rep(c("cpu", "cpu", "cuda"), 2L),
  solver = rep(c("irlba", "rsvd", "rsvd"), 2L),
  ncomp = rep(c(plssvd_ncomp, simpls_ncomp), each = 3L),
  stringsAsFactors = FALSE
)
routes$stem <- sprintf(
  "%s_%s_%s_%s_k%d",
  analysis_prefix, routes$family, routes$backend, routes$solver, routes$ncomp
)
routes$label <- c(
  "PLS-SVD CPU IRLBA", "PLS-SVD CPU rSVD", "PLS-SVD CUDA rSVD",
  "SIMPLS CPU IRLBA", "SIMPLS CPU rSVD", "SIMPLS CUDA rSVD"
)

required <- unlist(lapply(routes$stem, function(stem) {
  file.path(input_dir, c(
    paste0(stem, ".csv"),
    paste0(stem, "_prediction.rds")
  ))
}))
missing <- required[!file.exists(required)]
if (length(missing)) {
  stop("Missing current NMR files: ", paste(missing, collapse = ", "),
       call. = FALSE)
}

read_peak_rss <- function(path) {
  if (!file.exists(path)) return(NA_real_)
  lines <- readLines(path, warn = FALSE)
  hit <- grep("Maximum resident set size", lines, value = TRUE)
  if (!length(hit)) return(NA_real_)
  as.numeric(sub("^.*:\\s*", "", hit[[length(hit)]])) / 1024
}

resource_rows <- list()
prediction_objects <- list()
for (i in seq_len(nrow(routes))) {
  route <- routes[i, ]
  timing <- read.csv(file.path(input_dir, paste0(route$stem, ".csv")))
  timing$label <- route$label
  timing$process_peak_rss_mb <- read_peak_rss(
    file.path(input_dir, paste0(route$stem, ".time"))
  )
  timing$incremental_after_fit_rss_mb <- pmax(
    0, timing$after_fit_rss_mb - timing$baseline_rss_mb
  )
  resource_rows[[i]] <- timing
  prediction_objects[[route$label]] <- readRDS(
    file.path(input_dir, paste0(route$stem, "_prediction.rds"))
  )
}
resource <- do.call(rbind, resource_rows)
write.csv(resource, file.path(output_dir, "nmr_current_raw.csv"),
          row.names = FALSE, na = "")

median_summary <- do.call(rbind, lapply(split(resource, resource$label), function(x) {
  first_value <- function(name, default = NA) {
    if (!name %in% names(x)) return(default)
    value <- x[[name]]
    value <- value[!is.na(value)]
    if (length(value)) value[[1L]] else default
  }
  data.frame(
    label = x$label[[1L]],
    family = x$family[[1L]],
    backend = x$backend[[1L]],
    solver = x$solver[[1L]],
    precision = x$precision[[1L]],
    ncomp = x$ncomp[[1L]],
    protocol_version = first_value("protocol_version", NA_character_),
    canonical_input_verified =
      first_value("canonical_input_verified", FALSE),
    water_columns_masked = first_value("water_columns_masked", NA_integer_),
    response_columns_scored =
      first_value("response_columns_scored", NA_integer_),
    control_profile = first_value("control_profile", NA_character_),
    oversample = x$oversample[[1L]],
    power = x$power[[1L]],
    direction_rule = first_value("direction_rule", NA_character_),
    directions_per_solve =
      first_value("directions_per_solve", NA_integer_),
    refresh_width = first_value("refresh_width", NA_integer_),
    refresh_iterations = first_value("refresh_iterations", NA_integer_),
    seed = x$seed[[1L]],
    replicates = nrow(x),
    total_time_sec_median = median(x$total_time_sec),
    total_time_sec_iqr = IQR(x$total_time_sec),
    RMSD = x$RMSD[[1L]],
    Q2 = x$Q2[[1L]],
    MAE = x$MAE[[1L]],
    median_sample_RMSD = x$median_sample_RMSD[[1L]],
    p95_sample_RMSD = x$p95_sample_RMSD[[1L]],
    process_peak_rss_mb = unique(x$process_peak_rss_mb)[[1L]],
    baseline_rss_mb_median = median(x$baseline_rss_mb),
    incremental_process_peak_rss_mb = max(
      0,
      unique(x$process_peak_rss_mb)[[1L]] - median(x$baseline_rss_mb)
    ),
    incremental_after_fit_rss_mb_median =
      median(x$incremental_after_fit_rss_mb),
    stringsAsFactors = FALSE
  )
}))
write.csv(median_summary,
          file.path(output_dir, "nmr_current_summary.csv"),
          row.names = FALSE, na = "")

agreement_rows <- list()
agreement_index <- 0L
for (family in c("plssvd", "simpls")) {
  reference_label <- if (family == "plssvd") {
    "PLS-SVD CPU IRLBA"
  } else {
    "SIMPLS CPU IRLBA"
  }
  reference <- prediction_objects[[reference_label]]$predicted
  for (candidate_label in routes$label[
    routes$family == family & routes$solver == "rsvd"
  ]) {
    candidate <- prediction_objects[[candidate_label]]$predicted
    difference <- candidate - reference
    agreement_index <- agreement_index + 1L
    agreement_rows[[agreement_index]] <- data.frame(
      family = family,
      reference = reference_label,
      candidate = candidate_label,
      relative_frobenius_error =
        sqrt(sum(difference^2)) / max(sqrt(sum(reference^2)), .Machine$double.eps),
      maximum_absolute_error = max(abs(difference)),
      prediction_correlation = cor(
        as.numeric(reference), as.numeric(candidate)
      ),
      prediction_RMSD = sqrt(mean(difference^2)),
      stringsAsFactors = FALSE
    )
    rm(candidate, difference)
  }
  rm(reference)
  gc(full = TRUE)
}
agreement <- do.call(rbind, agreement_rows)
write.csv(agreement, file.path(output_dir, "nmr_current_agreement.csv"),
          row.names = FALSE, na = "")

if (nzchar(deposited_prediction) && file.exists(deposited_prediction)) {
  deposited_object <- readRDS(deposited_prediction)
  deposited_matrix <- if (is.list(deposited_object)) {
    deposited_object$predicted
  } else {
    deposited_object
  }
  reference_dimensions <- dim(prediction_objects[[1L]]$observed)
  if (identical(dim(deposited_matrix), reference_dimensions)) {
    prediction_objects[["Deposited PLS-SVD/IRLBA (165 components)"]] <- list(
      observed = prediction_objects[[1L]]$observed,
      predicted = deposited_matrix
    )
  }
}

error_rows <- list()
response_rows <- list()
for (label in names(prediction_objects)) {
  object <- prediction_objects[[label]]
  observed <- object$observed
  predicted <- object$predicted
  error_rows[[label]] <- data.frame(
    label = label,
    sample_id = rownames(observed) %||% seq_len(nrow(observed)),
    sample_index = seq_len(nrow(observed)),
    RMSD = sqrt(rowMeans((observed - predicted)^2)),
    stringsAsFactors = FALSE
  )
  response_rows[[label]] <- data.frame(
    label = label,
    ppm = suppressWarnings(as.numeric(colnames(observed))),
    response_index = seq_len(ncol(observed)),
    RMSD = sqrt(colMeans((observed - predicted)^2)),
    MAE = colMeans(abs(observed - predicted)),
    stringsAsFactors = FALSE
  )
}
per_sample <- do.call(rbind, error_rows)
per_response <- do.call(rbind, response_rows)
write.csv(per_sample, file.path(output_dir, "nmr_current_per_sample.csv"),
          row.names = FALSE)
write.csv(per_response, file.path(output_dir, "nmr_current_per_response.csv"),
          row.names = FALSE)

selection_label <- "SIMPLS CUDA rSVD"
selection_error <- subset(per_sample, label == selection_label)
representative_index <- selection_error$sample_index[which.min(
  abs(selection_error$RMSD - median(selection_error$RMSD))
)]
observed <- prediction_objects[[selection_label]]$observed
ppm <- suppressWarnings(as.numeric(colnames(observed)))
curve <- data.frame(
  ppm = ppm,
  sample_index = representative_index,
  sample_id = rownames(observed)[representative_index] %||%
    as.character(representative_index),
  series = "Observed",
  intensity = observed[representative_index, ],
  stringsAsFactors = FALSE
)
for (label in names(prediction_objects)) {
  curve <- rbind(
    curve,
    data.frame(
      ppm = ppm,
      sample_index = representative_index,
      sample_id = curve$sample_id[[1L]],
      series = label,
      intensity = prediction_objects[[label]]$predicted[representative_index, ],
      stringsAsFactors = FALSE
    )
  )
}

write.csv(curve, file.path(output_dir, "nmr_representative_spectrum.csv"),
          row.names = FALSE)
write.csv(
  data.frame(
    selection_rule = paste(
      "Spectrum nearest the median held-out RMSD for",
      selection_label, "at", representative_ncomp, "components"
    ),
    sample_index = representative_index,
    sample_id = curve$sample_id[[1L]],
    sample_RMSD = selection_error$RMSD[
      selection_error$sample_index == representative_index
    ],
    stringsAsFactors = FALSE
  ),
  file.path(output_dir, "nmr_representative_spectrum_selection.csv"),
  row.names = FALSE
)

writeLines(
  c(
    paste0("input_dir=", input_dir),
    paste0("generated=", format(Sys.time(), tz = "UTC", usetz = TRUE)),
    "comparison_scope=family, component count, split, preprocessing, precision, and prediction target held fixed",
    paste0(
      "rsvd_controls=",
      paste(unique(with(
        subset(median_summary, solver == "rsvd"),
        sprintf(
          paste0(
            "%s/%s: profile=%s, oversample=%s, power=%s, seed=%s, ",
            "direction=%s, directions_per_solve=%s, refresh_width=%s, ",
            "refresh_iterations=%s"
          ),
          family, backend, control_profile, oversample, power, seed,
          direction_rule, directions_per_solve, refresh_width,
          refresh_iterations
        )
      )), collapse = "; ")
    ),
    paste0(
      "representative_spectrum=nearest median held-out RMSD for SIMPLS CUDA ",
      "rSVD at ", representative_ncomp, " components"
    )
  ),
  file.path(output_dir, "nmr_current_manifest.txt")
)

cat(normalizePath(output_dir, winslash = "/", mustWork = TRUE), "\n")
