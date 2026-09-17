#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 3L) stop("Usage: failure_row.R CONFIG_RDS RESULT_CSV ERROR")
cfg <- readRDS(args[[1L]])

row <- data.frame(
  run_id = cfg$run_id, scenario_id = cfg$scenario_id,
  factor_name = cfg$factor_name, factor_value = cfg$factor_value,
  factor_label = cfg$factor_label, task_type = cfg$task_type,
  method = "simpls", route = cfg$route, backend = cfg$backend,
  svd_method = cfg$svd_method, xprod_requested = cfg$xprod,
  xprod_used = NA_character_, precision = "float64",
  n_train = cfg$n_train, n_test = cfg$n_test, p = cfg$p, q = cfg$q,
  class_count = cfg$class_count, latent_rank = cfg$latent_rank,
  max_ncomp = max(cfg$ncomp), requested_prefixes = cfg$requested_prefixes,
  crosscov_mb = cfg$p * cfg$q * 8 / 1024^2,
  replicate = cfg$replicate, data_seed = cfg$data_seed,
  fit_seed = cfg$fit_seed, oversample = cfg$oversample, power = cfg$power,
  rsvd_control_profile = NA_character_,
  rsvd_case_audit_available = NA, rsvd_case_audit_certified = NA,
  rsvd_deterministic_fallbacks = NA_integer_,
  rsvd_audit_max_attempts = NA_integer_,
  rsvd_effective_oversample = NA_integer_,
  rsvd_effective_power = NA_integer_,
  rsvd_max_triplet_residual = NA_real_,
  rsvd_max_omitted_direction_ratio = NA_real_,
  baseline_rss_mb = NA_real_, rss_after_fit_mb = NA_real_,
  rss_after_prediction_mb = NA_real_, process_peak_rss_mb = NA_real_,
  incremental_peak_rss_mb = NA_real_, gpu_process_peak_mb = NA_real_,
  gpu_total_baseline_mb = NA_real_, gpu_total_peak_mb = NA_real_,
  gpu_total_incremental_mb = NA_real_, fit_sec = NA_real_,
  prediction_sec = NA_real_, total_sec = NA_real_, model_size_mb = NA_real_,
  input_size_mb = NA_real_, rmsd = NA_real_, q2 = NA_real_, accuracy = NA_real_,
  prediction_relative_error = NA_real_, prediction_correlation = NA_real_,
  label_agreement = NA_real_, score_relative_error = NA_real_,
  score_correlation = NA_real_, metric_absolute_difference = NA_real_,
  numerical_status = "not_evaluated", status = "process_failed_or_timeout",
  warnings = "", error = args[[3L]], stringsAsFactors = FALSE
)
write.csv(row, args[[2L]], row.names = FALSE)
