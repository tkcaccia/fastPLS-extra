#!/usr/bin/env Rscript

# Setting-level reliability validation for OPLS and kernel PLS.
# Shared reference utilities are loaded from the independent estimator
# validation script without executing its benchmark loop.

base_script <- file.path(
  normalizePath(".", mustWork = TRUE),
  "benchmark",
  "benchmark_opls_kernel_estimator_validation.R"
)
expressions <- parse(base_script)
for (expression in expressions) {
  code <- paste(deparse(expression), collapse = " ")
  if (grepl("^cases *<- *make_cases\\(\\)", code)) break
  eval(expression, envir = .GlobalEnv)
}

args <- commandArgs(trailingOnly = TRUE)
get_setting_arg <- function(name, default) {
  key <- paste0("--", name, "=")
  hit <- args[startsWith(args, key)]
  if (!length(hit)) return(default)
  sub(key, "", hit[[1L]], fixed = TRUE)
}

root <- normalizePath(get_setting_arg("root", "."), mustWork = TRUE)
out_dir <- get_setting_arg(
  "out",
  file.path(Sys.getenv("FASTPLS_RESULTS_ROOT"),
            "opls_kernel_setting_reliability")
)
if (!nzchar(Sys.getenv("FASTPLS_RESULTS_ROOT")) &&
    !any(startsWith(args, "--out="))) {
  stop("Set --out or FASTPLS_RESULTS_ROOT.", call. = FALSE)
}
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

kernel_settings <- data.frame(
  setting = c(
    "linear",
    "rbf_gamma_0.25_over_p",
    "rbf_gamma_1_over_p",
    "rbf_gamma_4_over_p",
    "poly_degree2_offset1",
    "poly_degree3_offset1",
    "poly_degree4_offset1",
    "poly_degree3_offset0"
  ),
  kernel = c(
    "linear",
    rep("rbf", 3L),
    rep("poly", 4L)
  ),
  gamma_multiplier = c(NA, 0.25, 1, 4, 1, 1, 1, 1),
  degree = c(NA, NA, NA, NA, 2L, 3L, 4L, 3L),
  coef0 = c(NA, NA, NA, NA, 1, 1, 1, 0),
  stringsAsFactors = FALSE
)

opls_settings <- data.frame(
  setting = paste0("north_", 1:3),
  north = 1:3,
  stringsAsFactors = FALSE
)

validate_kernel_setting <- function(case, setting_row) {
  kernel <- setting_row$kernel
  xy <- prepare_xy(case)
  prep <- preprocess_reference(case$x_train, case$x_test, "autoscaling")
  gamma <- if (identical(kernel, "linear")) {
    1 / ncol(case$x_train)
  } else {
    setting_row$gamma_multiplier / ncol(case$x_train)
  }
  degree <- if (is.na(setting_row$degree)) 3L else setting_row$degree
  coef0 <- if (is.na(setting_row$coef0)) 1 else setting_row$coef0

  if (identical(kernel, "linear")) {
    reference_train <- prep$train
    reference_test <- prep$test
  } else {
    ktrain <- kernel_matrix_reference(
      prep$train,
      prep$train,
      kernel,
      gamma,
      degree,
      coef0
    )
    ktest <- kernel_matrix_reference(
      prep$test,
      prep$train,
      kernel,
      gamma,
      degree,
      coef0
    )
    centered <- center_kernel_reference(ktrain, ktest)
    reference_train <- centered$train
    reference_test <- centered$test
  }

  reference <- reference_simpls(
    reference_train,
    reference_test,
    xy$y_train_matrix,
    case$ncomp
  )
  fast <- fastPLS::pls(
    case$x_train,
    case$y_train,
    case$x_test,
    case$y_test,
    ncomp = case$ncomp,
    method = "kernelpls",
    kernel = kernel,
    gamma = gamma,
    degree = degree,
    coef0 = coef0,
    scaling = "autoscaling",
    backend = "cpu",
    svd.method = "irlba",
    fit = TRUE,
    proj = TRUE,
    return_variance = FALSE,
    seed = seed
  )

  if (identical(kernel, "linear")) {
    fast_train_operator <- sweep(
      sweep(case$x_train, 2L, as.numeric(fast$mX), "-"),
      2L,
      as.numeric(fast$vX),
      "/"
    )
    fast_test_operator <- sweep(
      sweep(case$x_test, 2L, as.numeric(fast$mX), "-"),
      2L,
      as.numeric(fast$vX),
      "/"
    )
  } else {
    fast_test_preprocessed <- sweep(
      sweep(case$x_test, 2L, as.numeric(fast$mX), "-"),
      2L,
      as.numeric(fast$vX),
      "/"
    )
    train_raw <- fastPLS:::kernel_matrix_cpp(
      fast$Xref,
      fast$Xref,
      fast$kernel_id,
      fast$gamma,
      fast$degree,
      fast$coef0
    )
    fast_train_operator <- fastPLS:::center_kernel_train_cpp(train_raw)$K
    test_raw <- fastPLS:::kernel_matrix_cpp(
      fast_test_preprocessed,
      fast$Xref,
      fast$kernel_id,
      fast$gamma,
      fast$degree,
      fast$coef0
    )
    fast_test_operator <- fastPLS:::center_kernel_test_cpp(
      test_raw,
      fast$kernel_center$col_means,
      fast$kernel_center$grand_mean
    )
  }

  fast_prediction <- if (identical(kernel, "linear")) {
    sweep(
      fast_test_operator %*% matrix_from_compact(fast$B),
      2L,
      as.numeric(fast$mY),
      "+"
    )
  } else {
    raw_prediction_from_inner(fast$inner_model, fast_test_operator)
  }
  metrics <- task_metrics(
    case$task,
    fast_prediction,
    reference$prediction,
    case$y_test,
    xy$levels
  )
  fast_scores <- if (identical(kernel, "linear")) {
    fast$Ttrain
  } else {
    fast$inner_model$Ttrain
  }
  angles <- principal_angles(
    fast_scores[, seq_len(case$ncomp), drop = FALSE],
    reference$scores
  )
  fast_coefficient <- if (identical(kernel, "linear")) {
    matrix_from_compact(fast$B)
  } else {
    matrix_from_compact(fast$inner_model$B)
  }

  data.frame(
    family = "kernelPLS",
    setting = setting_row$setting,
    case = case$name,
    source = case$source,
    task = case$task,
    n_train = nrow(case$x_train),
    n_test = nrow(case$x_test),
    p = ncol(case$x_train),
    q = ncol(xy$y_train_matrix),
    ncomp = case$ncomp,
    north = NA_integer_,
    kernel = kernel,
    solver = if (min(nrow(case$x_train), ncol(xy$y_train_matrix)) < 6L) {
      "exact_small_dimension_fallback"
    } else {
      "deterministic_irlba"
    },
    gamma = gamma,
    degree = degree,
    coef0 = coef0,
    operator_relative_error = relative_error(
      fast_train_operator,
      reference_train
    ),
    prediction_relative_error = relative_error(
      fast_prediction,
      reference$prediction
    ),
    prediction_correlation = safe_cor(
      fast_prediction,
      reference$prediction
    ),
    coefficient_relative_error = relative_error(
      fast_coefficient,
      reference$coefficient
    ),
    max_predictive_score_angle_deg = max(angles, na.rm = TRUE),
    max_orthogonal_score_angle_deg = NA_real_,
    label_agreement = metrics$label_agreement,
    fast_metric = metrics$fast_metric,
    reference_metric = metrics$reference_metric,
    metric_absolute_difference = abs(
      metrics$fast_metric - metrics$reference_metric
    ),
    status = "success",
    error = NA_character_
  )
}

validate_opls_setting <- function(case, setting_row) {
  setting_case <- case
  setting_case$north <- setting_row$north
  result <- validate_opls(setting_case)$row
  result$setting <- setting_row$setting
  result$gamma <- NA_real_
  result$degree <- NA_integer_
  result$coef0 <- NA_real_
  result
}

setting_error_row <- function(case, family, setting_row, error) {
  xy <- prepare_xy(case)
  is_opls <- identical(family, "OPLS")
  data.frame(
    family = family,
    setting = setting_row$setting,
    case = case$name,
    source = case$source,
    task = case$task,
    n_train = nrow(case$x_train),
    n_test = nrow(case$x_test),
    p = ncol(case$x_train),
    q = ncol(xy$y_train_matrix),
    ncomp = case$ncomp,
    north = if (is_opls) setting_row$north else NA_integer_,
    kernel = if (is_opls) NA_character_ else setting_row$kernel,
    solver = NA_character_,
    gamma = NA_real_,
    degree = NA_integer_,
    coef0 = NA_real_,
    operator_relative_error = NA_real_,
    prediction_relative_error = NA_real_,
    prediction_correlation = NA_real_,
    coefficient_relative_error = NA_real_,
    max_predictive_score_angle_deg = NA_real_,
    max_orthogonal_score_angle_deg = NA_real_,
    label_agreement = NA_real_,
    fast_metric = NA_real_,
    reference_metric = NA_real_,
    metric_absolute_difference = NA_real_,
    status = "failed",
    error = conditionMessage(error)
  )
}

validate_setting <- function(case, family, setting_row) {
  tryCatch(
    if (identical(family, "OPLS")) {
      validate_opls_setting(case, setting_row)
    } else {
      validate_kernel_setting(case, setting_row)
    },
    error = function(error) {
      setting_error_row(case, family, setting_row, error)
    }
  )
}

setting_component_selection <- function(case, family, setting_row) {
  folds <- make_folds(case)
  grid <- seq_len(case$ncomp)
  rows <- list()
  index <- 0L
  for (component in grid) {
    for (fold in sort(unique(folds))) {
      test_index <- which(folds == fold)
      train_index <- which(folds != fold)
      fold_case <- subset_case(case, train_index, test_index, component)
      if (identical(family, "OPLS")) {
        fold_case$north <- setting_row$north
      }
      result <- validate_setting(fold_case, family, setting_row)
      index <- index + 1L
      rows[[index]] <- data.frame(
        family = family,
        setting = setting_row$setting,
        case = case$name,
        task = case$task,
        component = component,
        fold = fold,
        fast_metric = result$fast_metric,
        reference_metric = result$reference_metric,
        status = result$status,
        error = result$error
      )
    }
  }
  raw <- do.call(rbind, rows)
  successful <- raw[raw$status == "success", , drop = FALSE]
  if (!nrow(successful)) {
    stop(
      sprintf(
        "No successful fold fits for %s/%s/%s: %s",
        family,
        setting_row$setting,
        case$name,
        paste(unique(raw$error), collapse = " | ")
      ),
      call. = FALSE
    )
  }
  path <- aggregate(
    cbind(fast_metric, reference_metric) ~ component,
    successful,
    mean
  )
  select_component <- if (identical(case$task, "classification")) {
    function(metric) path$component[which.max(metric)]
  } else {
    function(metric) path$component[which.min(metric)]
  }
  fast_selected <- select_component(path$fast_metric)
  reference_selected <- select_component(path$reference_metric)
  list(
    raw = raw,
    path = transform(
      path,
      family = family,
      setting = setting_row$setting,
      case = case$name
    ),
    summary = data.frame(
      family = family,
      setting = setting_row$setting,
      case = case$name,
      task = case$task,
      grid = paste(grid, collapse = ";"),
      fast_selected_ncomp = fast_selected,
      reference_selected_ncomp = reference_selected,
      selected_component_agreement = fast_selected == reference_selected,
      failed_folds = sum(raw$status != "success")
    )
  )
}

cases <- make_cases()
endpoint_rows <- list()
selection_rows <- list()
selection_paths <- list()
selection_folds <- list()
endpoint_index <- 0L
selection_index <- 0L

for (case in cases) {
  for (index in seq_len(nrow(opls_settings))) {
    setting <- opls_settings[index, , drop = FALSE]
    message(sprintf(
      "[%s] OPLS %s: %s",
      format(Sys.time()),
      setting$setting,
      case$name
    ))
    endpoint_index <- endpoint_index + 1L
    endpoint_rows[[endpoint_index]] <- validate_setting(
      case,
      "OPLS",
      setting
    )
    selected <- setting_component_selection(case, "OPLS", setting)
    selection_index <- selection_index + 1L
    selection_rows[[selection_index]] <- selected$summary
    selection_paths[[selection_index]] <- selected$path
    selection_folds[[selection_index]] <- selected$raw
  }

  for (index in seq_len(nrow(kernel_settings))) {
    setting <- kernel_settings[index, , drop = FALSE]
    message(sprintf(
      "[%s] kernel PLS %s: %s",
      format(Sys.time()),
      setting$setting,
      case$name
    ))
    endpoint_index <- endpoint_index + 1L
    endpoint_rows[[endpoint_index]] <- validate_setting(
      case,
      "kernelPLS",
      setting
    )
    selected <- setting_component_selection(case, "kernelPLS", setting)
    selection_index <- selection_index + 1L
    selection_rows[[selection_index]] <- selected$summary
    selection_paths[[selection_index]] <- selected$path
    selection_folds[[selection_index]] <- selected$raw
  }
}

raw <- do.call(rbind, endpoint_rows)
selection_summary <- do.call(rbind, selection_rows)
selection_path <- do.call(rbind, selection_paths)
selection_fold_raw <- do.call(rbind, selection_folds)
rownames(raw) <- NULL
rownames(selection_summary) <- NULL
rownames(selection_path) <- NULL
rownames(selection_fold_raw) <- NULL

raw$passes_operator <- raw$operator_relative_error <= 1e-10
raw$passes_prediction <- raw$prediction_relative_error <= 1e-4
raw$passes_coefficient <- raw$coefficient_relative_error <= 1e-3
raw$passes_predictive_subspace <-
  raw$max_predictive_score_angle_deg <= 0.1
raw$passes_orthogonal_subspace <-
  is.na(raw$max_orthogonal_score_angle_deg) |
  raw$max_orthogonal_score_angle_deg <= 0.1
raw$passes_labels <-
  is.na(raw$label_agreement) | raw$label_agreement >= 0.995
raw$passes_metric <- raw$metric_absolute_difference <= 0.005
raw$passes_all <- with(
  raw,
  status == "success" &
    passes_operator &
    passes_prediction &
    passes_coefficient &
    passes_predictive_subspace &
    passes_orthogonal_subspace &
    passes_labels &
    passes_metric
)

setting_summary <- do.call(
  rbind,
  lapply(split(raw, interaction(raw$family, raw$setting, drop = TRUE)),
         function(rows) {
    ok <- rows$status == "success"
    data.frame(
      family = rows$family[1L],
      setting = rows$setting[1L],
      runs = nrow(rows),
      successes = sum(ok),
      failures = sum(!ok),
      passes_all = sum(rows$passes_all, na.rm = TRUE),
      max_operator_relative_error = max(
        rows$operator_relative_error[ok],
        na.rm = TRUE
      ),
      max_prediction_relative_error = max(
        rows$prediction_relative_error[ok],
        na.rm = TRUE
      ),
      min_prediction_correlation = min(
        rows$prediction_correlation[ok],
        na.rm = TRUE
      ),
      max_coefficient_relative_error = max(
        rows$coefficient_relative_error[ok],
        na.rm = TRUE
      ),
      max_predictive_score_angle_deg = max(
        rows$max_predictive_score_angle_deg[ok],
        na.rm = TRUE
      ),
      max_orthogonal_score_angle_deg = if (
        all(is.na(rows$max_orthogonal_score_angle_deg))
      ) {
        NA_real_
      } else {
        max(rows$max_orthogonal_score_angle_deg[ok], na.rm = TRUE)
      },
      min_label_agreement = if (all(is.na(rows$label_agreement))) {
        NA_real_
      } else {
        min(rows$label_agreement[ok], na.rm = TRUE)
      },
      max_metric_absolute_difference = max(
        rows$metric_absolute_difference[ok],
        na.rm = TRUE
      )
    )
  })
)
rownames(setting_summary) <- NULL

selection_setting_summary <- do.call(
  rbind,
  lapply(
    split(
      selection_summary,
      interaction(
        selection_summary$family,
        selection_summary$setting,
        drop = TRUE
      )
    ),
    function(rows) {
      data.frame(
        family = rows$family[1L],
        setting = rows$setting[1L],
        comparisons = nrow(rows),
        selected_component_agreements = sum(
          rows$selected_component_agreement
        ),
        failed_fold_component_fits = sum(rows$failed_folds)
      )
    }
  )
)
rownames(selection_setting_summary) <- NULL

write.csv(
  raw,
  file.path(out_dir, "opls_kernel_setting_reliability_raw.csv"),
  row.names = FALSE
)
write.csv(
  setting_summary,
  file.path(out_dir, "opls_kernel_setting_reliability_summary.csv"),
  row.names = FALSE
)
write.csv(
  selection_summary,
  file.path(out_dir, "opls_kernel_setting_selection_summary.csv"),
  row.names = FALSE
)
write.csv(
  selection_setting_summary,
  file.path(out_dir, "opls_kernel_setting_selection_setting_summary.csv"),
  row.names = FALSE
)
write.csv(
  selection_path,
  file.path(out_dir, "opls_kernel_setting_selection_paths.csv"),
  row.names = FALSE
)
write.csv(
  selection_fold_raw,
  file.path(out_dir, "opls_kernel_setting_selection_fold_raw.csv"),
  row.names = FALSE
)
write.csv(
  raw[raw$status != "success" | !raw$passes_all, , drop = FALSE],
  file.path(out_dir, "opls_kernel_setting_reliability_failures.csv"),
  row.names = FALSE
)

plot_data <- rbind(
  data.frame(
    family = raw$family,
    setting = raw$setting,
    case = raw$case,
    diagnostic = "Prediction relative error",
    value = raw$prediction_relative_error,
    threshold = 1e-4
  ),
  data.frame(
    family = raw$family,
    setting = raw$setting,
    case = raw$case,
    diagnostic = "Coefficient relative error",
    value = raw$coefficient_relative_error,
    threshold = 1e-3
  ),
  data.frame(
    family = raw$family,
    setting = raw$setting,
    case = raw$case,
    diagnostic = "Predictive subspace angle (degrees)",
    value = raw$max_predictive_score_angle_deg,
    threshold = 0.1
  ),
  data.frame(
    family = raw$family,
    setting = raw$setting,
    case = raw$case,
    diagnostic = "Predictive metric difference",
    value = raw$metric_absolute_difference,
    threshold = 0.005
  )
)
plot_data$value_for_plot <- pmax(plot_data$value, 1e-16)
plot_data$threshold_for_plot <- pmax(plot_data$threshold, 1e-16)
setting_labels <- c(
  north_1 = "OPLS\nnorth = 1",
  north_2 = "OPLS\nnorth = 2",
  north_3 = "OPLS\nnorth = 3",
  linear = "Linear",
  rbf_gamma_0.25_over_p = "RBF\n0.25/p",
  rbf_gamma_1_over_p = "RBF\n1/p",
  rbf_gamma_4_over_p = "RBF\n4/p",
  poly_degree2_offset1 = "Poly\nd = 2, c = 1",
  poly_degree3_offset1 = "Poly\nd = 3, c = 1",
  poly_degree4_offset1 = "Poly\nd = 4, c = 1",
  poly_degree3_offset0 = "Poly\nd = 3, c = 0"
)
setting_order <- c(
  "north_1",
  "north_2",
  "north_3",
  "linear",
  "rbf_gamma_0.25_over_p",
  "rbf_gamma_1_over_p",
  "rbf_gamma_4_over_p",
  "poly_degree2_offset1",
  "poly_degree3_offset1",
  "poly_degree4_offset1",
  "poly_degree3_offset0"
)
plot_data$setting_label <- factor(
  unname(setting_labels[plot_data$setting]),
  levels = unname(setting_labels[setting_order])
)

suppressPackageStartupMessages(library(ggplot2))
reliability_plot <- ggplot(
  plot_data,
  aes(setting_label, value_for_plot, colour = family)
) +
  geom_hline(
    aes(yintercept = threshold_for_plot),
    linetype = "dashed",
    colour = "#777777",
    linewidth = 0.35
  ) +
  geom_point(
    position = position_jitter(width = 0.12, height = 0),
    alpha = 0.75,
    size = 1.8
  ) +
  facet_wrap(~diagnostic, scales = "free_y", ncol = 1) +
  scale_x_discrete(guide = guide_axis(n.dodge = 2)) +
  scale_y_log10() +
  scale_colour_manual(
    values = c(OPLS = "#0072B2", kernelPLS = "#D55E00")
  ) +
  labs(
    title = "OPLS and kernel-PLS setting-level reliability",
    subtitle = paste(
      "Six synthetic/real tasks per setting;",
      "dashed lines are prespecified pass thresholds"
    ),
    x = NULL,
    y = "Diagnostic value (log scale)",
    colour = "Family"
  ) +
  theme_bw(base_size = 10) +
  theme(
    axis.text.x = element_text(size = 8),
    panel.grid.minor = element_blank(),
    legend.position = "bottom",
    plot.title = element_text(face = "bold")
  )

ggsave(
  file.path(out_dir, "opls_kernel_setting_reliability.png"),
  reliability_plot,
  width = 8,
  height = 10.5,
  units = "in",
  dpi = 320,
  bg = "white"
)
ggsave(
  file.path(out_dir, "opls_kernel_setting_reliability.pdf"),
  reliability_plot,
  width = 8,
  height = 10.5,
  units = "in"
)

report <- c(
  "# OPLS and kernel-PLS setting-level reliability",
  "",
  sprintf("- fastPLS version: %s", packageVersion("fastPLS")),
  sprintf("- pls version: %s", packageVersion("pls")),
  sprintf("- seed: %d", seed),
  sprintf("- endpoint comparisons: %d", nrow(raw)),
  sprintf("- endpoint passes: %d", sum(raw$passes_all, na.rm = TRUE)),
  sprintf("- failed endpoints: %d", sum(raw$status != "success")),
  sprintf(
    "- component-selection agreements: %d/%d",
    sum(selection_summary$selected_component_agreement),
    nrow(selection_summary)
  ),
  sprintf(
    "- failed fold-component fits: %d/%d",
    sum(selection_fold_raw$status != "success"),
    nrow(selection_fold_raw)
  ),
  "",
  "## Settings",
  "",
  "OPLS: north = 1, 2, and 3 orthogonal components.",
  paste(
    "Kernel PLS: linear; RBF gamma = 0.25/p, 1/p, and 4/p;",
    "polynomial degree = 2, 3, or 4 with offset 1;",
    "and homogeneous degree-3 polynomial with offset 0."
  ),
  "",
  "## Reliability summary",
  "",
  paste(capture.output(print(setting_summary, row.names = FALSE)), collapse = "\n"),
  "",
  "## Component selection",
  "",
  paste(
    capture.output(print(selection_setting_summary, row.names = FALSE)),
    collapse = "\n"
  )
)
writeLines(
  report,
  file.path(out_dir, "OPLS_KERNEL_SETTING_RELIABILITY_REPORT.md")
)
writeLines(
  capture.output(sessionInfo()),
  file.path(out_dir, "session_info.txt")
)

print(setting_summary)
print(selection_setting_summary)
cat(sprintf("\nResults written to %s\n", normalizePath(out_dir)))

if (
  any(raw$status != "success") ||
  any(!raw$passes_all) ||
  any(!selection_summary$selected_component_agreement) ||
  any(selection_fold_raw$status != "success")
) {
  quit(status = 2L)
}
