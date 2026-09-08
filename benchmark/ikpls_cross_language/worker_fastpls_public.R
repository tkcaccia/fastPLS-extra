#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 5L) {
  stop("Usage: worker_fastpls_public.R TASK_RDS LIBRARY BACKEND REPLICATE OUTPUT_CSV")
}

task_path <- args[[1L]]
library_path <- args[[2L]]
backend <- match.arg(args[[3L]], c("cpu", "cuda", "metal"))
replicate_id <- as.integer(args[[4L]])
output_csv <- args[[5L]]
.libPaths(unique(c(library_path, .libPaths())))

seed <- as.integer(Sys.getenv("FASTPLS_BENCH_SEED", "123"))
oversample <- as.integer(Sys.getenv("FASTPLS_BENCH_OVERSAMPLE", "32"))
power <- as.integer(Sys.getenv("FASTPLS_BENCH_POWER", "5"))
ncomp <- as.integer(Sys.getenv("FASTPLS_BENCH_NCOMP", "50"))
if (anyNA(c(seed, oversample, power, ncomp))) {
  stop("Benchmark controls must be integers")
}

task <- readRDS(task_path)
library(fastPLS)
`%||%` <- function(left, right) if (is.null(left)) right else left
runtime <- Sys.info()
external <- extSoftVersion()
load_average_1m <- tryCatch(Sys.getloadavg()[[1L]], error = function(...) NA_real_)
logical_cpus <- parallel::detectCores(logical = TRUE)
source_commit <- Sys.getenv("FASTPLS_BENCH_SOURCE_COMMIT", NA_character_)
source_dirty <- Sys.getenv("FASTPLS_BENCH_SOURCE_DIRTY", NA_character_)
first_system_value <- function(command, arguments) {
  value <- tryCatch(
    suppressWarnings(system2(command, arguments, stdout = TRUE, stderr = FALSE)),
    error = function(...) character()
  )
  if (length(value) == 0L || !nzchar(value[[1L]])) NA_character_ else value[[1L]]
}
if (identical(runtime[["sysname"]], "Darwin")) {
  cpu_model <- first_system_value("sysctl", c("-n", "machdep.cpu.brand_string"))
  physical_memory_bytes <- first_system_value("sysctl", c("-n", "hw.memsize"))
} else if (identical(runtime[["sysname"]], "Linux")) {
  cpu_lines <- tryCatch(readLines("/proc/cpuinfo", warn = FALSE),
                        error = function(...) character())
  cpu_line <- grep("^model name[[:space:]]*:", cpu_lines, value = TRUE)
  cpu_model <- if (length(cpu_line)) {
    sub("^[^:]+:[[:space:]]*", "", cpu_line[[1L]])
  } else {
    NA_character_
  }
  memory_lines <- tryCatch(readLines("/proc/meminfo", warn = FALSE),
                           error = function(...) character())
  memory_line <- grep("^MemTotal:", memory_lines, value = TRUE)
  physical_memory_bytes <- if (length(memory_line)) {
    as.character(as.numeric(gsub("[^0-9]", "", memory_line[[1L]])) * 1024)
  } else {
    NA_character_
  }
} else {
  cpu_model <- NA_character_
  physical_memory_bytes <- NA_character_
}
precision <- match.arg(
  Sys.getenv("FASTPLS_BENCH_PRECISION", "float64"),
  c("float32", "float64")
)
if (identical(precision, "float32")) {
  task$Xtrain <- float::fl(as.matrix(task$Xtrain))
  task$Xtest <- float::fl(as.matrix(task$Xtest))
} else {
  task$Xtrain <- as.matrix(task$Xtrain)
  task$Xtest <- as.matrix(task$Xtest)
  storage.mode(task$Xtrain) <- "double"
  storage.mode(task$Xtest) <- "double"
}
gc(FALSE)

fit_start <- proc.time()[[3L]]
fit <- pls(
  task$Xtrain,
  task$Ytrain,
  ncomp = ncomp,
  scaling = "none",
  method = "simpls",
  svd.method = "rsvd",
  backend = backend,
  classifier = "argmax",
  fit = FALSE,
  return_variance = FALSE,
  return_loadings = FALSE,
  proj = FALSE,
  seed = seed,
  oversample = oversample,
  power = power
)
fit_sec <- unname(proc.time()[[3L]] - fit_start)

prediction_start <- proc.time()[[3L]]
prediction <- predict(fit, task$Xtest, backend = backend)$Ypred
if (is.list(prediction)) prediction <- prediction[[length(prediction)]]
prediction_sec <- unname(proc.time()[[3L]] - prediction_start)

predicted <- factor(prediction, levels = levels(task$Ytest))
utils::write.csv(data.frame(
  dataset = task$dataset,
  backend = backend,
  precision = precision,
  protocol_id = "cifar100_public_simpls_rsvd_v1",
  package_version = as.character(utils::packageVersion("fastPLS")),
  source_commit = source_commit,
  source_dirty = source_dirty,
  host = unname(runtime[["nodename"]]),
  os = unname(runtime[["sysname"]]),
  machine = unname(runtime[["machine"]]),
  cpu_model = cpu_model,
  physical_memory_bytes = physical_memory_bytes,
  logical_cpus = logical_cpus,
  load_average_1m = load_average_1m,
  r_version = paste(R.version$major, R.version$minor, sep = "."),
  r_platform = R.version$platform,
  r_blas = unname(external[["BLAS"]] %||% NA_character_),
  fastpls_cpu_backend = fastPLS:::cpu_backend_description_cpp(),
  replicate = replicate_id,
  ncomp = ncomp,
  oversample = oversample,
  power = power,
  seed = seed,
  fit_sec = fit_sec,
  prediction_sec = prediction_sec,
  total_sec = fit_sec + prediction_sec,
  accuracy = mean(predicted == task$Ytest),
  execution_route = fit$diagnostics$residency$route %||%
    fit$diagnostics$execution_route %||% "compiled CPU",
  algorithm_variant = fit$diagnostics$algorithm_variant %||% NA_character_,
  refresh_block = fit$diagnostics$resident_controls$refresh_block %||%
    fit$diagnostics$simpls_direction$directions_per_solve %||% NA_integer_,
  effective_oversample = fit$diagnostics$rsvd$oversample %||% NA_integer_,
  effective_power = fit$diagnostics$rsvd$power %||% NA_integer_,
  prediction_checksum = sum(as.integer(predicted) * seq_along(predicted))
), output_csv, row.names = FALSE)
