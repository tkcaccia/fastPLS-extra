#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 1L) stop("Usage: summarize.R RESULTS_DIR")
results_dir <- normalizePath(args[[1L]], winslash = "/", mustWork = TRUE)
files <- list.files(file.path(results_dir, "rows"), pattern = "[.]csv$", full.names = TRUE)
if (!length(files)) stop("No benchmark rows found.")

rows <- lapply(files, utils::read.csv, check.names = FALSE)
all_names <- unique(unlist(lapply(rows, names), use.names = FALSE))
rows <- lapply(rows, function(d) {
  for (name in setdiff(all_names, names(d))) d[[name]] <- NA
  d[all_names]
})
raw <- do.call(rbind, rows)
for (name in c("process_peak_rss_mb", "prefit_process_rss_mb", "final_process_rss_mb",
               "user_cpu_sec", "system_cpu_sec")) {
  if (!name %in% names(raw)) raw[[name]] <- NA_real_
}
raw$baseline_corrected_peak_increment_mb <- pmax(
  0, raw$process_peak_rss_mb - raw$prefit_process_rss_mb
)
raw <- raw[order(raw$dataset, raw$comparison_profile, raw$implementation, raw$replicate), ]
utils::write.csv(raw, file.path(results_dir, "external_simpls_timing_raw.csv"), row.names = FALSE, na = "")

iqr <- function(x) if (sum(is.finite(x)) > 1L) stats::IQR(x, na.rm = TRUE) else NA_real_
med <- function(x) if (any(is.finite(x))) stats::median(x, na.rm = TRUE) else NA_real_

if (!"timing_mode" %in% names(raw)) raw$timing_mode <- "cold_process"
if (!"iteration" %in% names(raw)) raw$iteration <- 1L
if (!"cpu_profile" %in% names(raw)) raw$cpu_profile <- "reference_1"
if (!"measurement_scope" %in% names(raw)) raw$measurement_scope <- "primary"
if (!"requested_blas_threads" %in% names(raw)) raw$requested_blas_threads <- 1L
if (!"reported_blas_threads" %in% names(raw)) raw$reported_blas_threads <- NA_integer_
if (!"loaded_blas_library" %in% names(raw)) raw$loaded_blas_library <- NA_character_
phase_columns <- c(
  "preprocess_crosscov_sec", "estimator_sec", "coefficient_path_sec",
  "fitted_values_sec", "model_assembly_sec", "cpp_total_sec",
  "r_wrapper_fit_overhead_sec"
)
for (name in phase_columns) if (!name %in% names(raw)) raw[[name]] <- NA_real_

keys <- interaction(
  raw$dataset, raw$comparison_profile, raw$implementation, raw$timing_mode,
  raw$cpu_profile, raw$measurement_scope,
  drop = TRUE
)
summary <- do.call(rbind, lapply(split(raw, keys), function(d) {
  ok <- d[d$status == "success", ]
  data.frame(
    dataset = d$dataset[[1L]],
    comparison_profile = d$comparison_profile[[1L]],
    implementation = d$implementation[[1L]],
    timing_mode = d$timing_mode[[1L]],
    cpu_profile = d$cpu_profile[[1L]],
    measurement_scope = d$measurement_scope[[1L]],
    requested_blas_threads = d$requested_blas_threads[[1L]],
    reported_blas_threads = d$reported_blas_threads[[1L]],
    loaded_blas_library = d$loaded_blas_library[[1L]],
    function_name = d$function_name[[1L]],
    estimator = d$estimator[[1L]],
    solver = d$solver[[1L]],
    output_contract = d$output_contract[[1L]],
    repetitions_attempted = nrow(d),
    repetitions_completed = nrow(ok),
    median_fit_sec = med(ok$fit_sec),
    iqr_fit_sec = iqr(ok$fit_sec),
    median_prediction_sec = med(ok$prediction_sec),
    iqr_prediction_sec = iqr(ok$prediction_sec),
    median_total_sec = med(ok$total_sec),
    iqr_total_sec = iqr(ok$total_sec),
    median_preprocess_crosscov_sec = med(ok$preprocess_crosscov_sec),
    median_estimator_sec = med(ok$estimator_sec),
    median_coefficient_path_sec = med(ok$coefficient_path_sec),
    median_fitted_values_sec = med(ok$fitted_values_sec),
    median_model_assembly_sec = med(ok$model_assembly_sec),
    median_cpp_total_sec = med(ok$cpp_total_sec),
    median_r_wrapper_fit_overhead_sec = med(ok$r_wrapper_fit_overhead_sec),
    median_accuracy = med(ok$accuracy),
    median_fit_object_mb = med(ok$fit_object_mb),
    median_process_peak_rss_mb = med(ok$process_peak_rss_mb),
    iqr_process_peak_rss_mb = iqr(ok$process_peak_rss_mb),
    median_prefit_process_rss_mb = med(ok$prefit_process_rss_mb),
    iqr_prefit_process_rss_mb = iqr(ok$prefit_process_rss_mb),
    median_baseline_corrected_peak_increment_mb = med(ok$baseline_corrected_peak_increment_mb),
    iqr_baseline_corrected_peak_increment_mb = iqr(ok$baseline_corrected_peak_increment_mb),
    median_final_process_rss_mb = med(ok$final_process_rss_mb),
    median_coefficient_path_mb = med(ok$coefficient_path_mb),
    median_score_outputs_mb = med(ok$score_outputs_mb),
    median_loading_outputs_mb = med(ok$loading_outputs_mb),
    median_fitted_outputs_mb = med(ok$fitted_outputs_mb),
    theoretical_cross_covariance_mb = med(ok$theoretical_cross_covariance_mb),
    theoretical_final_coefficient_mb = med(ok$theoretical_final_coefficient_mb),
    theoretical_coefficient_path_mb = med(ok$theoretical_coefficient_path_mb),
    theoretical_fitted_path_mb = med(ok$theoretical_fitted_path_mb),
    theoretical_residual_path_mb = med(ok$theoretical_residual_path_mb),
    theoretical_train_scores_mb = med(ok$theoretical_train_scores_mb),
    theoretical_test_scores_mb = med(ok$theoretical_test_scores_mb),
    theoretical_largest_retained_name = d$theoretical_largest_retained_name[[1L]],
    theoretical_largest_retained_mb = med(ok$theoretical_largest_retained_mb),
    failures = sum(d$status != "success"),
    failure_messages = paste(unique(d$error_message[nzchar(d$error_message)]), collapse = " | "),
    stringsAsFactors = FALSE
  )
}))
row.names(summary) <- NULL
utils::write.csv(summary, file.path(results_dir, "external_simpls_timing_summary.csv"), row.names = FALSE, na = "")

memory_summary <- summary[, c(
  "dataset", "comparison_profile", "implementation", "repetitions_completed",
  "median_process_peak_rss_mb", "iqr_process_peak_rss_mb",
  "median_prefit_process_rss_mb", "iqr_prefit_process_rss_mb",
  "median_baseline_corrected_peak_increment_mb",
  "iqr_baseline_corrected_peak_increment_mb", "median_final_process_rss_mb",
  "median_fit_object_mb", "median_coefficient_path_mb", "median_score_outputs_mb",
  "median_loading_outputs_mb", "median_fitted_outputs_mb",
  "theoretical_cross_covariance_mb", "theoretical_final_coefficient_mb",
  "theoretical_coefficient_path_mb", "theoretical_fitted_path_mb",
  "theoretical_residual_path_mb", "theoretical_train_scores_mb",
  "theoretical_test_scores_mb", "theoretical_largest_retained_name",
  "theoretical_largest_retained_mb"
)]
utils::write.csv(
  memory_summary,
  file.path(results_dir, "external_simpls_memory_summary.csv"),
  row.names = FALSE, na = ""
)

pairs <- merge(
  summary[summary$implementation == "fastpls", ],
  summary[summary$implementation == "pls", ],
  by = c("dataset", "comparison_profile", "timing_mode", "cpu_profile", "measurement_scope"),
  suffixes = c("_fastpls", "_pls"), all = TRUE
)
pairs$speedup_pls_over_fastpls <- pairs$median_total_sec_pls / pairs$median_total_sec_fastpls
pairs$accuracy_difference <- pairs$median_accuracy_fastpls - pairs$median_accuracy_pls
pairs$absolute_peak_rss_ratio_pls_over_fastpls <-
  pairs$median_process_peak_rss_mb_pls / pairs$median_process_peak_rss_mb_fastpls
pairs$baseline_corrected_peak_increment_ratio_pls_over_fastpls <-
  pairs$median_baseline_corrected_peak_increment_mb_pls /
  pairs$median_baseline_corrected_peak_increment_mb_fastpls
utils::write.csv(pairs, file.path(results_dir, "external_simpls_timing_pairs.csv"), row.names = FALSE, na = "")

status <- raw[, c(
  "dataset", "comparison_profile", "implementation", "timing_mode",
  "replicate", "iteration", "status", "error_message"
)]
utils::write.csv(status, file.path(results_dir, "external_simpls_timing_status.csv"), row.names = FALSE, na = "")

phase_summary <- summary[
  summary$implementation == "fastpls" & summary$measurement_scope == "phase_decomposition",
  c(
  "dataset", "comparison_profile", "timing_mode", "cpu_profile",
  "requested_blas_threads", "reported_blas_threads", "loaded_blas_library",
  "repetitions_completed",
  "median_preprocess_crosscov_sec", "median_estimator_sec",
  "median_coefficient_path_sec", "median_fitted_values_sec",
  "median_model_assembly_sec", "median_cpp_total_sec",
  "median_r_wrapper_fit_overhead_sec", "median_prediction_sec", "median_total_sec"
)]
utils::write.csv(
  phase_summary,
  file.path(results_dir, "fastpls_simpls_phase_timing_summary.csv"),
  row.names = FALSE, na = ""
)

writeLines(capture.output(sessionInfo()), file.path(results_dir, "session_info.txt"))
cat(
  "Wrote summaries for", nrow(raw), "measured iterations from",
  length(unique(paste(raw$dataset, raw$comparison_profile, raw$implementation,
                      raw$cpu_profile, raw$measurement_scope, raw$timing_mode,
                      raw$replicate, sep = "::"))),
  "worker processes.\n"
)
