#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 2L) {
  stop("Usage: generate_grid.R OUT_DIR PROFILE [BACKENDS] [REPS]", call. = FALSE)
}

out_dir <- normalizePath(args[[1L]], winslash = "/", mustWork = FALSE)
profile <- match.arg(args[[2L]], c("smoke", "qualification", "publication"))
backends <- if (length(args) >= 3L) {
  trimws(strsplit(args[[3L]], ",", fixed = TRUE)[[1L]])
} else {
  "cpu"
}
backends <- intersect(backends[nzchar(backends)], c("cpu", "cuda", "metal"))
if (!length(backends)) stop("No supported backend requested.", call. = FALSE)
reps <- if (length(args) >= 4L) as.integer(args[[4L]]) else 3L
if (!is.finite(reps) || reps < 1L) reps <- 3L

dir.create(file.path(out_dir, "configs"), recursive = TRUE, showWarnings = FALSE)
dir.create(file.path(out_dir, "references"), recursive = TRUE, showWarnings = FALSE)
dir.create(file.path(out_dir, "rows"), recursive = TRUE, showWarnings = FALSE)
dir.create(file.path(out_dir, "logs"), recursive = TRUE, showWarnings = FALSE)

base <- list(
  design_partition = "one_factor",
  task_type = "regression",
  n_train = 2000L,
  n_test = 400L,
  p = 400L,
  q = 100L,
  latent_rank = 30L,
  class_count = NA_integer_,
  ncomp = 20L,
  requested_prefixes = 20L,
  noise = 0.10
)

levels <- if (identical(profile, "smoke")) {
  list(
    n = c(500L, 2000L),
    p = c(100L, 1000L),
    q = c(25L, 500L),
    ncomp = c(5L, 40L),
    prefix_count = c(1L, 10L),
    rank = c(5L, 40L),
    class_count = c(5L, 50L),
    crosscov_mb = c(4L, 40L)
  )
} else {
  list(
    n = c(500L, 1000L, 2000L, 5000L, 10000L),
    p = c(50L, 100L, 250L, 500L, 1000L, 2000L),
    q = c(10L, 25L, 50L, 100L, 250L, 500L, 1000L),
    ncomp = c(2L, 5L, 10L, 20L, 40L, 80L),
    prefix_count = c(1L, 2L, 5L, 10L, 20L),
    rank = c(5L, 10L, 20L, 40L, 80L),
    class_count = c(5L, 10L, 25L, 50L, 100L, 200L),
    crosscov_mb = c(2L, 4L, 8L, 16L, 32L, 64L)
  )
}

prefix_grid <- function(A, count) {
  A <- as.integer(A)
  count <- min(as.integer(count), A)
  unique(as.integer(round(seq(1, A, length.out = count))))
}

scenario <- function(factor_name, factor_value, index) {
  x <- base
  x$factor_name <- factor_name
  x$factor_value <- as.numeric(factor_value)
  x$factor_label <- as.character(factor_value)
  x$data_seed <- 10000L + index

  if (factor_name == "n") {
    x$n_train <- as.integer(factor_value)
    x$n_test <- max(100L, as.integer(round(factor_value / 5)))
  } else if (factor_name == "p") {
    x$p <- as.integer(factor_value)
  } else if (factor_name == "q") {
    x$q <- as.integer(factor_value)
  } else if (factor_name == "ncomp") {
    x$ncomp <- as.integer(factor_value)
    x$requested_prefixes <- as.integer(factor_value)
    x$p <- 500L
    x$q <- 100L
    x$latent_rank <- 100L
  } else if (factor_name == "prefix_count") {
    x$ncomp <- prefix_grid(20L, factor_value)
    x$requested_prefixes <- length(x$ncomp)
  } else if (factor_name == "rank") {
    x$latent_rank <- as.integer(factor_value)
    x$ncomp <- 5L
    x$requested_prefixes <- 1L
    # Keep X'Y rank-controlled; response noise would make it numerically full rank.
    x$noise <- 0
  } else if (factor_name == "class_count") {
    x$task_type <- "classification"
    x$class_count <- as.integer(factor_value)
    x$q <- as.integer(factor_value)
    x$ncomp <- 4L
    x$requested_prefixes <- 1L
    x$n_train <- max(2000L, 20L * x$class_count)
    x$n_test <- max(400L, 4L * x$class_count)
    x$latent_rank <- 20L
  } else if (factor_name == "crosscov_mb") {
    x$n_train <- 1500L
    x$n_test <- 300L
    x$p <- 1000L
    x$q <- max(2L, as.integer(round(factor_value * 1024^2 / (8 * x$p))))
    x$ncomp <- 10L
    x$requested_prefixes <- 1L
    x$latent_rank <- 20L
    x$factor_value <- x$p * x$q * 8 / 1024^2
    x$factor_label <- sprintf("%.1f", x$factor_value)
  }

  max_comp <- min(x$n_train - 1L, x$p)
  x$ncomp <- sort(unique(pmin(as.integer(x$ncomp), max_comp)))
  x$requested_prefixes <- length(x$ncomp)
  x$scenario_id <- sprintf(
    "%02d_%s_%s", index, factor_name,
    gsub("[^A-Za-z0-9]+", "_", x$factor_label)
  )
  x
}

scenarios <- list()
index <- 0L
for (factor_name in names(levels)) {
  for (value in levels[[factor_name]]) {
    index <- index + 1L
    scenarios[[length(scenarios) + 1L]] <- scenario(factor_name, value, index)
  }
}

# Add an interaction panel independently of the one-factor crossover grid.
# A deterministic Latin-hypercube construction covers combinations of n, p,
# q, rank, component count, prefix count, and class count. The held-out cases
# are reserved for evaluating the automatic route rule after it is fixed.
lhs_values <- function(count, lower, upper, seed, logarithmic = FALSE) {
  set.seed(seed)
  u <- ((seq_len(count) - 1) + stats::runif(count)) / count
  u <- sample(u)
  if (logarithmic) exp(log(lower) + u * (log(upper) - log(lower))) else lower + u * (upper - lower)
}

interaction_scenarios <- function(count, partition, seed_offset) {
  n_values <- lhs_values(count, 500, 6000, 7000L + seed_offset, TRUE)
  p_values <- lhs_values(count, 64, 4000, 7100L + seed_offset, TRUE)
  q_values <- lhs_values(count, 8, 2000, 7200L + seed_offset, TRUE)
  comp_values <- lhs_values(count, 2, 80, 7300L + seed_offset, TRUE)
  prefix_values <- lhs_values(count, 1, 20, 7400L + seed_offset, TRUE)
  rank_values <- lhs_values(count, 3, 120, 7500L + seed_offset, TRUE)
  out <- vector("list", count)
  for (i in seq_len(count)) {
    p_i <- as.integer(round(p_values[[i]]))
    q_i <- as.integer(round(q_values[[i]]))
    n_i <- as.integer(round(n_values[[i]]))
    # Keep isolated runs feasible while preserving broad shape interactions.
    n_i <- min(n_i, max(300L, as.integer(floor(8e6 / p_i))))
    n_i <- min(n_i, max(300L, as.integer(floor(5e6 / q_i))))
    task_type <- if (i %% 4L == 0L) "classification" else "regression"
    class_count <- if (task_type == "classification") max(3L, min(q_i, 200L)) else NA_integer_
    q_effective <- if (task_type == "classification") class_count else q_i
    max_component <- max(1L, min(n_i - 1L, p_i, q_effective))
    ncomp_i <- max(1L, min(as.integer(round(comp_values[[i]])), max_component))
    rank_i <- max(ncomp_i, min(as.integer(round(rank_values[[i]])), p_i, q_effective))
    prefixes_i <- min(ncomp_i, max(1L, as.integer(round(prefix_values[[i]]))))
    index <<- index + 1L
    out[[i]] <- list(
      design_partition = partition,
      task_type = task_type,
      n_train = n_i,
      n_test = max(100L, as.integer(round(n_i / 5))),
      p = p_i,
      q = q_effective,
      latent_rank = rank_i,
      class_count = class_count,
      ncomp = prefix_grid(ncomp_i, prefixes_i),
      requested_prefixes = prefixes_i,
      noise = 0.10,
      factor_name = paste0("interaction_", partition),
      factor_value = i,
      factor_label = paste0(partition, "_", i),
      data_seed = 20000L + seed_offset + i,
      scenario_id = sprintf("%02d_interaction_%s_%02d", index, partition, i)
    )
  }
  out
}

if (identical(profile, "publication")) {
  scenarios <- c(
    scenarios,
    interaction_scenarios(24L, "development", 0L),
    interaction_scenarios(16L, "holdout", 1000L)
  )
}

route <- function(name, backend, svd_method, xprod, reference = FALSE) {
  list(
    route = name,
    backend = backend,
    svd_method = svd_method,
    xprod = xprod,
    reference = reference
  )
}

routes_for <- function(s) {
  out <- list(route("cpu_irlba_explicit", "cpu", "irlba", "explicit", TRUE))
  if ("cpu" %in% backends) {
    out <- c(out, list(route("cpu_rsvd_auto", "cpu", "rsvd", "auto")))
    if (s$factor_name == "crosscov_mb" || startsWith(s$factor_name, "interaction_")) {
      out <- c(out, list(
        route("cpu_rsvd_explicit", "cpu", "rsvd", "explicit"),
        route("cpu_rsvd_implicit", "cpu", "rsvd", "implicit")
      ))
    }
  }
  for (backend in intersect(backends, c("cuda", "metal"))) {
    out <- c(out, list(route(paste0(backend, "_rsvd_auto"), backend, "rsvd", "auto")))
    if (s$factor_name == "crosscov_mb") {
      out <- c(out, list(
        route(paste0(backend, "_rsvd_explicit"), backend, "rsvd", "explicit"),
        route(paste0(backend, "_rsvd_implicit"), backend, "rsvd", "implicit")
      ))
    }
  }
  out
}

configs <- list()
for (s in scenarios) {
  for (replicate in seq_len(reps)) {
    reference_file <- file.path(
      out_dir, "references",
      paste0(s$scenario_id, "__rep", replicate, ".rds")
    )
    for (r in routes_for(s)) {
      cfg <- c(s, r)
      cfg$replicate <- as.integer(replicate)
      cfg$fit_seed <- 123L + replicate
      automatic_controls <- grepl("_rsvd_auto$", r$route)
      cfg$oversample <- if (automatic_controls) NA_integer_ else 32L
      cfg$power <- if (automatic_controls) NA_integer_ else 5L
      cfg$reference_file <- reference_file
      cfg$run_id <- paste(s$scenario_id, r$route, paste0("rep", replicate), sep = "__")
      configs[[length(configs) + 1L]] <- cfg
    }
  }
}

config_paths <- character(length(configs))
manifest_rows <- vector("list", length(configs))
for (i in seq_along(configs)) {
  cfg <- configs[[i]]
  path <- file.path(out_dir, "configs", paste0(cfg$run_id, ".rds"))
  saveRDS(cfg, path)
  config_paths[[i]] <- normalizePath(path, winslash = "/", mustWork = FALSE)
  manifest_rows[[i]] <- data.frame(
    run_id = cfg$run_id,
    scenario_id = cfg$scenario_id,
    factor_name = cfg$factor_name,
    design_partition = cfg$design_partition,
    factor_value = cfg$factor_value,
    task_type = cfg$task_type,
    n_train = cfg$n_train,
    n_test = cfg$n_test,
    p = cfg$p,
    q = cfg$q,
    latent_rank = cfg$latent_rank,
    class_count = cfg$class_count,
    max_ncomp = max(cfg$ncomp),
    requested_prefixes = cfg$requested_prefixes,
    route = cfg$route,
    backend = cfg$backend,
    svd_method = cfg$svd_method,
    xprod = cfg$xprod,
    requested_oversample = cfg$oversample,
    requested_power = cfg$power,
    replicate = cfg$replicate,
    reference = cfg$reference,
    stringsAsFactors = FALSE
  )
}
writeLines(config_paths, file.path(out_dir, "config_paths.txt"))
write.csv(do.call(rbind, manifest_rows), file.path(out_dir, "configuration_manifest.csv"), row.names = FALSE)
saveRDS(configs, file.path(out_dir, "configurations.rds"))

writeLines(c(
  paste0("profile=", profile),
  paste0("backends=", paste(backends, collapse = ",")),
  paste0("replicates=", reps),
  paste0("scenario_count=", length(scenarios)),
  "interaction_design=24 deterministic Latin-hypercube development cases plus 16 independent held-out cases",
  paste0("run_count=", length(configs)),
  "precision=float64",
  "method=simpls",
  "reference=cpu_irlba_explicit",
  paste0(
    "rsvd_controls=public automatic controls for *_rsvd_auto routes; ",
    "oversample32/power5 for explicit and implicit qualification routes"
  ),
  "seed_rule=data_seed fixed by scenario; fit_seed=123+replicate"
), file.path(out_dir, "grid_parameters.txt"))

cat(length(configs), "configurations written to", out_dir, "\n")
