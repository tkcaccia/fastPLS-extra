parse_kv_args <- function(args = commandArgs(trailingOnly = TRUE)) {
  out <- list()
  if (!length(args)) return(out)
  for (arg in args) {
    if (!startsWith(arg, "--")) next
    keyval <- substring(arg, 3L)
    if (grepl("=", keyval, fixed = TRUE)) {
      bits <- strsplit(keyval, "=", fixed = TRUE)[[1L]]
      key <- gsub("-", "_", bits[[1L]], fixed = TRUE)
      val <- paste(bits[-1L], collapse = "=")
    } else {
      key <- gsub("-", "_", keyval, fixed = TRUE)
      val <- "true"
    }
    out[[key]] <- val
  }
  out
}

arg_value <- function(args, key, default = NULL, required = FALSE) {
  val <- args[[key]]
  if (is.null(val) || identical(val, "")) {
    if (isTRUE(required)) stop("Missing required argument --", gsub("_", "-", key))
    return(default)
  }
  val
}

`%||%` <- function(x, y) {
  if (is.null(x) || !length(x)) y else x
}

normalize_path_if_exists <- function(path) {
  path <- trimws(path)
  if (!nzchar(path)) return(path)
  path <- path.expand(path)
  if (file.exists(path)) normalizePath(path, winslash = "/", mustWork = TRUE) else path
}

is_float32_matrix <- function(x) {
  inherits(x, "float32")
}

as_benchmark_matrix <- function(x) {
  if (is_float32_matrix(x)) x else as.matrix(x)
}

as_double_matrix <- function(x) {
  if (is_float32_matrix(x)) float::dbl(x) else as.matrix(x)
}

benchmark_matrix_precision <- function(x) {
  if (is_float32_matrix(x)) "float32" else "float64"
}

benchmark_inner_model <- function(fit) {
  if (inherits(fit, "fastPLSOpls") || inherits(fit, "fastPLSKernel")) {
    if (!is.null(fit$inner_model)) return(fit$inner_model)
  }
  fit
}

benchmark_executed_method <- function(fit, fallback) {
  # OPLS and kernel-PLS deliberately use SIMPLS as their inner predictive
  # engine; that implementation detail must not relabel the outer estimator.
  if (fallback %in% c("opls", "kernelpls")) return(fallback)
  if (inherits(fit, "fastPLSOpls")) return("opls")
  if (inherits(fit, "fastPLSKernel")) return("kernelpls")
  internal <- attr(fit, "fastPLS_internal", exact = TRUE)
  as.character(internal$pls_method %||% fallback)[[1L]]
}

benchmark_execution_precision <- function(fit, fallback = "float64") {
  internal <- attr(fit, "fastPLS_internal", exact = TRUE)
  inner <- benchmark_inner_model(fit)
  inner_internal <- attr(inner, "fastPLS_internal", exact = TRUE)
  as.character(internal$precision %||% inner_internal$precision %||% fallback)[[1L]]
}

benchmark_classifier_backend <- function(fit, classifier) {
  inner <- benchmark_inner_model(fit)
  internal <- attr(inner, "fastPLS_internal", exact = TRUE)
  if (identical(classifier, "lda")) {
    return(as.character(inner$lda$train_backend %||% internal$classification_rule %||% "lda")[[1L]])
  }
  as.character(internal$classification_rule %||% "argmax")[[1L]]
}

benchmark_classifier_numeric_path <- function(fit, classifier, fallback = "float64") {
  precision <- benchmark_execution_precision(fit, fallback)
  precision
}

coerce_benchmark_matrix <- function(x, precision = c("native", "float32", "float64")) {
  precision <- match.arg(precision)
  if (identical(precision, "native")) return(as_benchmark_matrix(x))
  if (!requireNamespace("float", quietly = TRUE)) {
    stop("The float package is required for precision-controlled benchmarks.")
  }
  if (identical(precision, "float32")) {
    if (is_float32_matrix(x)) x else float::fl(as.matrix(x))
  } else {
    if (is_float32_matrix(x)) float::dbl(x) else as.matrix(x)
  }
}

coerce_task_precision <- function(task, precision = c("native", "float32", "float64")) {
  precision <- match.arg(tolower(precision), c("native", "float32", "float64"))
  task$Xtrain <- coerce_benchmark_matrix(task$Xtrain, precision)
  task$Xtest <- coerce_benchmark_matrix(task$Xtest, precision)
  if (!identical(task$task_type, "classification")) {
    task$Ytrain <- coerce_benchmark_matrix(task$Ytrain, precision)
    task$Ytest <- coerce_benchmark_matrix(task$Ytest, precision)
  }
  task$precision <- benchmark_matrix_precision(task$Xtrain)
  task$input_storage_mb <- as.numeric(
    object.size(task$Xtrain) + object.size(task$Xtest) +
      object.size(task$Ytrain) + object.size(task$Ytest)
  ) / (1024^2)
  task
}

current_process_rss_mb <- function() {
  if (requireNamespace("ps", quietly = TRUE)) {
    info <- tryCatch(ps::ps_memory_info(ps::ps_handle()), error = function(e) NULL)
    if (!is.null(info) && is.finite(info[["rss"]])) {
      return(as.numeric(info[["rss"]]) / (1024^2))
    }
  }
  status <- "/proc/self/status"
  if (file.exists(status)) {
    line <- grep("^VmRSS:", readLines(status, warn = FALSE), value = TRUE)
    if (length(line)) {
      kb <- suppressWarnings(as.numeric(gsub("[^0-9.]", "", line[[1L]])))
      if (is.finite(kb)) return(kb / 1024)
    }
  }
  NA_real_
}

current_process_gpu_memory_mb <- function() {
  nvidia_smi <- Sys.which("nvidia-smi")
  if (!nzchar(nvidia_smi)) return(NA_real_)
  output <- tryCatch(
    suppressWarnings(system2(
      nvidia_smi,
      c(
        "--query-compute-apps=pid,used_gpu_memory",
        "--format=csv,noheader,nounits"
      ),
      stdout = TRUE,
      stderr = FALSE
    )),
    error = function(e) character()
  )
  if (!length(output)) return(0)
  fields <- strsplit(output, ",", fixed = TRUE)
  used <- vapply(fields, function(x) {
    if (length(x) < 2L) return(NA_real_)
    pid <- suppressWarnings(as.integer(trimws(x[[1L]])))
    memory <- suppressWarnings(as.numeric(trimws(x[[2L]])))
    if (isTRUE(pid == Sys.getpid()) && is.finite(memory)) memory else NA_real_
  }, numeric(1))
  if (!any(is.finite(used))) 0 else sum(used[is.finite(used)])
}

signal_memory_sampler <- function(fit_ready_file, sampler_ready_file) {
  if (!nzchar(fit_ready_file)) return(invisible(NULL))
  dir.create(dirname(fit_ready_file), recursive = TRUE, showWarnings = FALSE)
  writeLines("ready", fit_ready_file)
  if (!nzchar(sampler_ready_file)) return(invisible(NULL))
  deadline <- Sys.time() + 30
  while (!file.exists(sampler_ready_file) && Sys.time() < deadline) {
    Sys.sleep(0.01)
  }
  if (!file.exists(sampler_ready_file)) {
    warning("Memory sampler did not acknowledge the fit boundary")
  }
  invisible(NULL)
}

dataset_filename <- function(dataset_id) {
  switch(
    tolower(dataset_id),
    metref = "metref.RData",
    cbmc_citeseq = "cbmc_citeseq.RData",
    cifar100 = "CIFAR100.RData",
    ccle = "ccle.RData",
    gtex_v8 = "gtex_v8.RData",
    imagenet = "imagenet.RData",
    nmr = "nmr.RData",
    prism = "prism.RData",
    retina = "Macosko2015_retina_float32.RData",
    singlecell = "singlecell.RData",
    tabula = "TabulaMuris_float32.RData",
    tcga_brca = "tcga_brca.RData",
    tcga_hnsc_methylation = "tcga_hnsc_methylation.RData",
    tcga_pan_cancer = "tcga_pan_cancer.RData",
    stop("Unsupported dataset_id: ", dataset_id)
  )
}

find_dataset_rdata <- function(dataset_id) {
  dataset_id <- tolower(dataset_id)
  home_dir <- path.expand("~")
  env_name <- sprintf("FASTPLS_%s_RDATA", toupper(dataset_id))
  fname <- dataset_filename(dataset_id)
  fnames <- switch(
    dataset_id,
    metref = c(fname, "metref_remote_task.RData"),
    gtex_v8 = c(fname, "gtex.RData"),
    nmr = c(fname, "NMR.RData"),
    retina = c(fname, "Macosko2015_retina.RData", "retina.RData"),
    tabula = c(fname, "TabulaMuris.RData", "tabula.RData"),
    fname
  )
  candidates <- c(
    Sys.getenv(env_name, ""),
    unlist(lapply(fnames, function(one_fname) {
      c(
        file.path(home_dir, "Documents", "Rdatasets", one_fname),
        file.path(home_dir, "Documents", "fastpls", "data", one_fname),
        file.path(home_dir, "Documents", "fastPLS", "data", one_fname),
        file.path(home_dir, "Documents", "fastPLS", "Data", one_fname),
        file.path(home_dir, "Documents", "GPUPLS", "Data", one_fname),
        file.path(home_dir, "GPUPLS", "Data", one_fname)
      )
    }), use.names = FALSE)
  )
  candidates <- unique(Filter(nzchar, vapply(candidates, normalize_path_if_exists, character(1))))
  for (cand in candidates) {
    if (file.exists(cand)) return(cand)
  }
  found <- list.files(
    home_dir,
    pattern = sprintf("^(%s)$", paste(gsub(".", "\\\\.", fnames, fixed = TRUE), collapse = "|")),
    full.names = TRUE,
    recursive = TRUE,
    ignore.case = TRUE
  )
  if (length(found)) {
    found <- normalizePath(found, winslash = "/", mustWork = TRUE)
    return(found[[1L]])
  }
  stop("Dataset RData not found for ", dataset_id, " (checked ", env_name, " and common remote paths).")
}

make_stratified_split <- function(y, train_frac = 0.9) {
  y <- droplevels(as.factor(y))
  idx <- seq_along(y)
  by_class <- split(idx, y)
  train_idx <- unlist(lapply(by_class, function(ii) {
    n_train <- max(1L, floor(length(ii) * train_frac))
    sample(ii, n_train)
  }), use.names = FALSE)
  test_idx <- setdiff(idx, train_idx)
  list(train = sort(train_idx), test = sort(test_idx))
}

half_split_idx <- function(n) {
  idx <- seq_len(n)
  train_idx <- sample(idx, size = floor(n / 2))
  test_idx <- setdiff(idx, train_idx)
  list(train = sort(train_idx), test = sort(test_idx))
}

fixed_train_split <- function(n, train_n) {
  if (n < 2L) stop("Need at least 2 rows to split train/test")
  train_n_eff <- min(max(1L, as.integer(train_n)), n - 1L)
  train_idx <- sample.int(n, size = train_n_eff)
  test_idx <- setdiff(seq_len(n), train_idx)
  list(train = sort(train_idx), test = sort(test_idx))
}

env_positive_int <- function(name, default) {
  val <- suppressWarnings(as.integer(Sys.getenv(name, as.character(default))))
  if (!is.finite(val) || is.na(val) || val < 1L) default else val
}

sample_stratified_n <- function(y, n_target) {
  y <- safe_factor(y)
  n <- length(y)
  n_target <- min(max(1L, as.integer(n_target)), n)
  idx <- seq_len(n)
  by_class <- split(idx, y)
  non_empty <- by_class[vapply(by_class, length, integer(1)) > 0L]
  if (n_target <= length(non_empty)) {
    return(sort(sample(vapply(non_empty, function(ii) sample(ii, 1L), integer(1)), n_target)))
  }
  base <- vapply(non_empty, function(ii) sample(ii, 1L), integer(1))
  remaining <- setdiff(idx, base)
  extra_n <- n_target - length(base)
  extra <- if (extra_n > 0L) sample(remaining, extra_n) else integer(0)
  sort(c(base, extra))
}

sample_rows_n <- function(n, n_target) {
  n_target <- min(max(1L, as.integer(n_target)), n)
  sort(sample.int(n, size = n_target))
}

numeric_frame_to_matrix <- function(x) {
  is_plain_numeric <- vapply(
    x,
    function(v) is.numeric(v) || is.integer(v) || is.logical(v),
    logical(1)
  )
  if (all(is_plain_numeric)) {
    return(as.matrix(x))
  }
  x <- as.data.frame(lapply(x, function(v) {
    if (is.numeric(v) || is.integer(v) || is.logical(v)) {
      as.numeric(v)
    } else {
      suppressWarnings(as.numeric(as.character(v)))
    }
  }))
  as.matrix(x)
}

safe_factor <- function(y) {
  if (is.factor(y)) return(droplevels(y))
  droplevels(factor(y))
}

load_embedded_list_task <- function(e, objs, dataset_id, split_seed) {
  candidates <- intersect(c("dataset_float32", "dataset"), objs)
  for (nm in candidates) {
    obj <- get(nm, envir = e)
    if (!is.list(obj) || !all(c("data", "labels") %in% names(obj))) next
    X <- as_benchmark_matrix(obj$data)
    y <- safe_factor(obj$labels)
    set.seed(as.integer(split_seed))
    sp <- make_stratified_split(y, train_frac = 0.5)
    return(list(
      dataset = dataset_id,
      task_type = "classification",
      dataset_path = NA_character_,
      split_seed = as.integer(split_seed),
      Xtrain = X[sp$train, , drop = FALSE],
      Ytrain = droplevels(y[sp$train]),
      Xtest = X[sp$test, , drop = FALSE],
      Ytest = factor(y[sp$test], levels = levels(y[sp$train])),
      n_train = length(sp$train),
      n_test = length(sp$test),
      p = ncol(X),
      n_classes = nlevels(y[sp$train]),
      source_metadata = if (!is.null(obj$metadata)) obj$metadata else NULL
    ))
  }
  NULL
}

load_standard_task <- function(path, dataset_id, split_seed) {
  e <- new.env(parent = emptyenv())
  objs <- load(path, envir = e)
  set.seed(as.integer(split_seed))

  embedded <- load_embedded_list_task(e, objs, dataset_id, split_seed)
  if (!is.null(embedded)) {
    embedded$dataset_path <- normalizePath(path, winslash = "/", mustWork = TRUE)
    return(embedded)
  }

  if (all(c("Xtrain", "Ytrain", "Xtest", "Ytest") %in% objs)) {
    y_train <- get("Ytrain", envir = e)
    y_test <- get("Ytest", envir = e)
    if (is.factor(y_train)) {
      y_train <- safe_factor(y_train)
      y_test <- factor(y_test, levels = levels(y_train))
      n_classes <- nlevels(y_train)
      task_type <- "classification"
    } else {
      n_classes <- ncol(as.matrix(y_train))
      task_type <- "regression"
    }
    return(list(
      dataset = dataset_id,
      task_type = task_type,
      dataset_path = normalizePath(path, winslash = "/", mustWork = TRUE),
      split_seed = as.integer(split_seed),
      Xtrain = as_benchmark_matrix(get("Xtrain", envir = e)),
      Ytrain = y_train,
      Xtest = as_benchmark_matrix(get("Xtest", envir = e)),
      Ytest = y_test,
      n_train = nrow(get("Xtrain", envir = e)),
      n_test = nrow(get("Xtest", envir = e)),
      p = ncol(get("Xtrain", envir = e)),
      n_classes = n_classes
    ))
  }

  if ("out" %in% objs && is.list(get("out", envir = e)) &&
      all(c("Xtrain", "Ytrain", "Xtest", "Ytest") %in% names(get("out", envir = e)))) {
    obj <- get("out", envir = e)
    y_train <- obj$Ytrain
    y_test <- obj$Ytest
    if (is.factor(y_train)) {
      y_train <- safe_factor(y_train)
      y_test <- factor(y_test, levels = levels(y_train))
      n_classes <- nlevels(y_train)
      task_type <- "classification"
    } else {
      n_classes <- ncol(as.matrix(y_train))
      task_type <- "regression"
    }
    return(list(
      dataset = dataset_id,
      task_type = task_type,
      dataset_path = normalizePath(path, winslash = "/", mustWork = TRUE),
      split_seed = as.integer(split_seed),
      Xtrain = as_benchmark_matrix(obj$Xtrain),
      Ytrain = y_train,
      Xtest = as_benchmark_matrix(obj$Xtest),
      Ytest = y_test,
      n_train = nrow(obj$Xtrain),
      n_test = nrow(obj$Xtest),
      p = ncol(obj$Xtrain),
      n_classes = n_classes
    ))
  }

  if ("r" %in% objs && is.data.frame(e$r) && "label_idx" %in% colnames(e$r)) {
    dt <- data.table::as.data.table(get("r", envir = e))
    feat_cols <- grep("^feat_", names(dt), value = TRUE)
    if (!length(feat_cols)) {
      feat_cols <- setdiff(names(dt), c("image_path", "split", "label_idx", "label_name"))
    }
    split_col <- if ("split" %in% names(dt)) trimws(tolower(as.character(dt$split))) else rep("train", nrow(dt))
    train_idx <- which(split_col == "train")
    test_idx <- which(split_col == "test")
    if (!length(train_idx) || !length(test_idx)) {
      sp <- half_split_idx(nrow(dt))
      train_idx <- sp$train
      test_idx <- sp$test
    }
    y_all <- safe_factor(dt$label_idx)
    return(list(
      dataset = dataset_id,
      task_type = "classification",
      dataset_path = normalizePath(path, winslash = "/", mustWork = TRUE),
      split_seed = as.integer(split_seed),
      Xtrain = as.matrix(dt[train_idx, ..feat_cols]),
      Ytrain = droplevels(y_all[train_idx]),
      Xtest = as.matrix(dt[test_idx, ..feat_cols]),
      Ytest = factor(y_all[test_idx], levels = levels(y_all[train_idx])),
      n_train = length(train_idx),
      n_test = length(test_idx),
      p = length(feat_cols),
      n_classes = nlevels(y_all[train_idx])
    ))
  }

  if (all(c("data", "labels") %in% objs)) {
    X <- as_benchmark_matrix(get("data", envir = e))
    y <- safe_factor(get("labels", envir = e))
    sp <- make_stratified_split(y, train_frac = 0.5)
    return(list(
      dataset = dataset_id,
      task_type = "classification",
      dataset_path = normalizePath(path, winslash = "/", mustWork = TRUE),
      split_seed = as.integer(split_seed),
      Xtrain = X[sp$train, , drop = FALSE],
      Ytrain = droplevels(y[sp$train]),
      Xtest = X[sp$test, , drop = FALSE],
      Ytest = factor(y[sp$test], levels = levels(y[sp$train])),
      n_train = length(sp$train),
      n_test = length(sp$test),
      p = ncol(X),
      n_classes = nlevels(y[sp$train])
    ))
  }

  stop("Unsupported standard task format: ", path)
}

as_task <- function(path, dataset_id, split_seed = 123L) {
  dataset_id <- tolower(dataset_id)
  if (dataset_id %in% c("cifar100", "ccle", "gtex_v8", "prism", "cbmc_citeseq", "retina", "tabula", "tcga_brca", "tcga_hnsc_methylation", "tcga_pan_cancer")) {
    return(load_standard_task(path, dataset_id = dataset_id, split_seed = split_seed))
  }

  if (dataset_id == "imagenet") {
    e <- new.env(parent = emptyenv())
    objs <- load(path, envir = e)
    train_n <- env_positive_int("FASTPLS_IMAGENET_TRAIN_N", 50000L)
    test_n <- env_positive_int("FASTPLS_IMAGENET_TEST_N", 10000L)
    set.seed(as.integer(split_seed))

    if (all(c("Xtrain", "Ytrain", "Xtest", "Ytest") %in% objs)) {
      y_train_all <- safe_factor(e$Ytrain)
      train_idx <- sample_stratified_n(y_train_all, min(train_n, nrow(e$Xtrain)))
      test_idx <- sample_rows_n(nrow(e$Xtest), min(test_n, nrow(e$Xtest)))
      y_train <- droplevels(y_train_all[train_idx])
      y_test <- factor(e$Ytest[test_idx], levels = levels(y_train))
      task <- list(
        dataset = dataset_id,
        task_type = "classification",
        dataset_path = normalizePath(path, winslash = "/", mustWork = TRUE),
        split_seed = as.integer(split_seed),
        Xtrain = as.matrix(e$Xtrain[train_idx, , drop = FALSE]),
        Ytrain = y_train,
        Xtest = as.matrix(e$Xtest[test_idx, , drop = FALSE]),
        Ytest = y_test,
        n_train = length(train_idx),
        n_test = length(test_idx),
        p = ncol(e$Xtrain),
        n_classes = nlevels(y_train)
      )
      rm(e)
      gc()
      return(task)
    }

    if ("r" %in% objs && is.data.frame(e$r) && "label_idx" %in% colnames(e$r)) {
      y <- safe_factor(e$r[, "label_idx"])
      sp <- fixed_train_split(nrow(e$r), min(train_n, nrow(e$r) - 1L))
      if (length(sp$test) > test_n) {
        sp$test <- sort(sample(sp$test, test_n))
      }
      rows <- c(sp$train, sp$test)
      feat_cols <- grep("^feat_", names(e$r), value = TRUE)
      if (!length(feat_cols)) {
        feat_cols <- setdiff(names(e$r), names(e$r)[seq_len(min(3L, ncol(e$r)))])
      }
      Xsub <- e$r[rows, feat_cols, drop = FALSE]
      X <- numeric_frame_to_matrix(Xsub)
      keep <- colSums(is.finite(X)) > 0
      X <- as.matrix(X[, keep, drop = FALSE])
      train_rows <- seq_along(sp$train)
      test_rows <- length(sp$train) + seq_along(sp$test)
      y_train <- droplevels(y[sp$train])
      task <- list(
        dataset = dataset_id,
        task_type = "classification",
        dataset_path = normalizePath(path, winslash = "/", mustWork = TRUE),
        split_seed = as.integer(split_seed),
        Xtrain = X[train_rows, , drop = FALSE],
        Ytrain = y_train,
        Xtest = X[test_rows, , drop = FALSE],
        Ytest = factor(y[sp$test], levels = levels(y_train)),
        n_train = length(sp$train),
        n_test = length(sp$test),
        p = ncol(X),
        n_classes = nlevels(y_train)
      )
      rm(e, Xsub, X)
      gc()
      return(task)
    }

    if (all(c("data", "labels") %in% objs)) {
      y <- safe_factor(e$labels)
      sp <- fixed_train_split(nrow(e$data), min(train_n, nrow(e$data) - 1L))
      if (length(sp$test) > test_n) {
        sp$test <- sort(sample(sp$test, test_n))
      }
      y_train <- droplevels(y[sp$train])
      task <- list(
        dataset = dataset_id,
        task_type = "classification",
        dataset_path = normalizePath(path, winslash = "/", mustWork = TRUE),
        split_seed = as.integer(split_seed),
        Xtrain = as.matrix(e$data[sp$train, , drop = FALSE]),
        Ytrain = y_train,
        Xtest = as.matrix(e$data[sp$test, , drop = FALSE]),
        Ytest = factor(y[sp$test], levels = levels(y_train)),
        n_train = length(sp$train),
        n_test = length(sp$test),
        p = ncol(e$data),
        n_classes = nlevels(y_train)
      )
      rm(e)
      gc()
      return(task)
    }

    stop("Unsupported imagenet.RData format: ", path)
  }

  if (dataset_id == "nmr") {
    e <- new.env(parent = emptyenv())
    load(path, envir = e)
    Xtrain <- as_benchmark_matrix(e$Xtrain)
    Xtest <- as_benchmark_matrix(e$Xtest)
    x_axis <- suppressWarnings(as.numeric(colnames(e$Xtrain)))
    water_columns <- which(is.finite(x_axis) & x_axis > 4.6 & x_axis < 4.8)
    if (length(water_columns)) {
      Xtrain[, water_columns] <- 0
      Xtest[, water_columns] <- 0
    }
    return(list(
      dataset = dataset_id,
      task_type = "regression",
      dataset_path = normalizePath(path, winslash = "/", mustWork = TRUE),
      split_seed = as.integer(split_seed),
      Xtrain = Xtrain,
      Ytrain = as_benchmark_matrix(e$Ytrain),
      Xtest = Xtest,
      Ytest = as_benchmark_matrix(e$Ytest),
      n_train = nrow(e$Xtrain),
      n_test = nrow(e$Xtest),
      p = ncol(e$Xtrain),
      n_classes = ncol(e$Ytrain),
      preprocessing = list(
        protocol = "fixed stored split; predictor-only water masking; full-response metrics",
        residual_water_region_ppm = c(4.6, 4.8),
        predictor_water_columns_zeroed = length(water_columns),
        response_columns_evaluated = ncol(e$Ytrain)
      )
    ))
  }

  if (dataset_id == "singlecell") {
    e <- new.env(parent = emptyenv())
    load(path, envir = e)
    X <- as_benchmark_matrix(e$data)
    y <- safe_factor(e$labels)
    set.seed(as.integer(split_seed))
    sp <- make_stratified_split(y, train_frac = 0.5)
    return(list(
      dataset = dataset_id,
      task_type = "classification",
      dataset_path = normalizePath(path, winslash = "/", mustWork = TRUE),
      split_seed = as.integer(split_seed),
      Xtrain = X[sp$train, , drop = FALSE],
      Ytrain = droplevels(y[sp$train]),
      Xtest = X[sp$test, , drop = FALSE],
      Ytest = factor(y[sp$test], levels = levels(y[sp$train])),
      n_train = length(sp$train),
      n_test = length(sp$test),
      p = ncol(X),
      n_classes = nlevels(y[sp$train])
    ))
  }

  if (dataset_id == "metref") {
    if (file.exists(path)) {
      try({
        task <- load_standard_task(path, dataset_id = dataset_id, split_seed = split_seed)
        return(task)
      }, silent = TRUE)
    }
    if (!requireNamespace("KODAMA", quietly = TRUE)) {
      stop("KODAMA package is required to load metref")
    }
    suppressPackageStartupMessages(library(KODAMA))
    data("MetRef", package = "KODAMA")
    X <- MetRef$data
    X <- X[, colSums(X) != 0, drop = FALSE]
    X <- normalization(X)$newXtrain
    y <- safe_factor(MetRef$donor)
    set.seed(as.integer(split_seed))
    ss <- sample(seq_len(nrow(X)), min(100L, floor(nrow(X) / 5L)))
    tr <- setdiff(seq_len(nrow(X)), ss)
    return(list(
      dataset = dataset_id,
      task_type = "classification",
      dataset_path = "KODAMA::MetRef",
      split_seed = as.integer(split_seed),
      Xtrain = as.matrix(X[tr, , drop = FALSE]),
      Ytrain = y[tr],
      Xtest = as.matrix(X[ss, , drop = FALSE]),
      Ytest = y[ss],
      n_train = length(tr),
      n_test = length(ss),
      p = ncol(X),
      n_classes = nlevels(y)
    ))
  }

  stop("Unsupported dataset format for ", dataset_id)
}

benchmark_gpu_backend <- function() {
  backend <- tolower(trimws(Sys.getenv("FASTPLS_GPU_BACKEND", "")))
  if (backend %in% c("cuda", "metal")) {
    return(backend)
  }
  sysname <- tolower(as.character(Sys.info()[["sysname"]]))
  if (identical(sysname, "darwin")) "metal" else "cuda"
}

benchmark_gpu_backend_label <- function(backend = benchmark_gpu_backend()) {
  if (identical(backend, "metal")) "Metal" else "CUDA"
}

benchmark_gpu_backend_code <- function(backend = benchmark_gpu_backend()) {
  if (identical(backend, "metal")) "metal_native" else "gpu_native"
}

variant_specs <- function() {
  gpu_backend <- benchmark_gpu_backend()
  gpu_label <- benchmark_gpu_backend_label(gpu_backend)
  gpu_code <- benchmark_gpu_backend_code(gpu_backend)
  rows <- list(
    c("cpp_plssvd_cpu_rsvd", "plssvd", "CPU", "cpu_rsvd", "Cpp", "argmax", ""),
    c("cpp_plssvd_irlba", "plssvd", "CPU", "irlba", "Cpp", "argmax", ""),
    c("gpu_plssvd_rsvd", "plssvd", "GPU", gpu_code, gpu_label, "argmax", gpu_backend),
    c("cpp_simpls_cpu_rsvd", "simpls", "CPU", "cpu_rsvd", "Cpp", "argmax", ""),
    c("cpp_simpls_irlba", "simpls", "CPU", "irlba", "Cpp", "argmax", ""),
    c("gpu_simpls_rsvd", "simpls", "GPU", gpu_code, gpu_label, "argmax", gpu_backend),
    c("pls_pkg_simpls", "simpls", "CPU", "pls_pkg", "pls_pkg", "argmax", ""),
    c("cpp_kernelpls_cpu_rsvd", "kernelpls", "CPU", "cpu_rsvd", "Cpp", "argmax", ""),
    c("cpp_kernelpls_irlba", "kernelpls", "CPU", "irlba", "Cpp", "argmax", ""),
    c("gpu_kernelpls_rsvd", "kernelpls", "GPU", gpu_code, gpu_label, "argmax", gpu_backend),
    c("pls_pkg_kernelpls", "kernelpls", "CPU", "pls_pkg", "pls_pkg", "argmax", ""),
    c("cpp_opls_cpu_rsvd", "opls", "CPU", "cpu_rsvd", "Cpp", "argmax", ""),
    c("cpp_opls_irlba", "opls", "CPU", "irlba", "Cpp", "argmax", ""),
    c("gpu_opls_rsvd", "opls", "GPU", gpu_code, gpu_label, "argmax", gpu_backend),
    c("pls_pkg_opls", "opls", "CPU", "pls_pkg", "pls_pkg", "argmax", "")
  )
  out <- as.data.frame(do.call(rbind, rows), stringsAsFactors = FALSE)
  names(out) <- c("variant_name", "method_family", "engine", "backend", "implementation_label", "classifier", "native_backend")
  lda_rows <- out[out$implementation_label %in% c("Cpp", gpu_label), , drop = FALSE]
  lda_rows$variant_name <- paste0(lda_rows$variant_name, "_lda")
  lda_rows$classifier <- "lda"
  out <- rbind(out, lda_rows)
  out
}

variant_spec <- function(variant_name) {
  specs <- variant_specs()
  hit <- specs[specs$variant_name == variant_name, , drop = FALSE]
  if (!nrow(hit)) stop("Unknown variant_name: ", variant_name)
  hit[1L, , drop = FALSE]
}

method_panel_label <- function(method_family) {
  switch(
    method_family,
    plssvd = "plssvd",
    simpls = "simpls",
    opls = "opls",
    kernelpls = "kernelpls",
    method_family
  )
}

safe_effective_ncomp <- function(task, requested_ncomp, method_family = NULL) {
  base_cap <- min(
    as.integer(requested_ncomp),
    as.integer(task$n_train) - 1L,
    as.integer(task$p)
  )

  if (identical(method_family, "plssvd")) {
    response_cap <- as.integer(task$n_classes)
    if (identical(task$task_type, "classification")) {
      response_cap <- response_cap - 1L
    }
    base_cap <- min(base_cap, response_cap)
  }

  max(1L, base_cap)
}

extract_pred_labels <- function(pred_res, levels_y = NULL) {
  if (is.null(pred_res$Ypred)) stop("Prediction result is missing `Ypred`")
  yp <- pred_res$Ypred
  if (is.data.frame(yp)) return(as.character(yp[[1L]]))
  if (is.factor(yp)) return(as.character(yp))
  if (is.array(yp) && length(dim(yp)) == 3L) {
    yp <- yp[, , 1L, drop = FALSE]
    yp <- matrix(yp, nrow = dim(pred_res$Ypred)[1L], ncol = dim(pred_res$Ypred)[2L])
    pred_names <- colnames(pred_res$Ypred)
    if (is.null(pred_names)) pred_names <- colnames(yp)
    if (is.null(pred_names) && !is.null(levels_y) && ncol(yp) == length(levels_y)) pred_names <- levels_y
    if (is.null(pred_names)) pred_names <- as.character(seq_len(ncol(yp)))
    return(as.character(pred_names[max.col(yp, ties.method = "first")]))
  }
  if (is.matrix(yp) && ncol(yp) >= 1L) {
    if (!is.null(levels_y) && ncol(yp) > 1L) {
      pred_names <- colnames(yp)
      if (is.null(pred_names) && ncol(yp) == length(levels_y)) pred_names <- levels_y
      if (!is.null(pred_names)) {
        return(as.character(pred_names[max.col(yp, ties.method = "first")]))
      }
    }
    return(as.character(yp[, 1L]))
  }
  if (is.list(yp) && length(yp) >= 1L) return(as.character(yp[[1L]]))
  stop("Unsupported prediction structure in `Ypred`")
}

classification_secondary_metrics <- function(truth, predicted) {
  lev <- union(levels(safe_factor(truth)), levels(safe_factor(predicted)))
  truth <- factor(as.character(truth), levels = lev)
  predicted <- factor(as.character(predicted), levels = lev)
  cm <- table(truth, predicted)
  support <- rowSums(cm)
  predicted_n <- colSums(cm)
  tp <- diag(cm)
  recall <- ifelse(support > 0, tp / support, NA_real_)
  precision <- ifelse(predicted_n > 0, tp / predicted_n, NA_real_)
  f1 <- ifelse(
    is.finite(precision + recall) & (precision + recall) > 0,
    2 * precision * recall / (precision + recall),
    0
  )
  list(
    balanced_accuracy = mean(recall, na.rm = TRUE),
    macro_f1 = mean(f1[is.finite(f1)], na.rm = TRUE)
  )
}

classification_topk_accuracy <- function(pred_obj, truth, k = 5L) {
  top <- pred_obj$Ypred_top
  if (is.null(top)) return(NA_real_)
  if (is.list(top) && !is.data.frame(top)) top <- top[[length(top)]]
  if (is.data.frame(top)) top <- as.matrix(top)
  if (length(dim(top)) == 3L) top <- top[, , dim(top)[3L], drop = TRUE]
  if (is.null(dim(top))) top <- matrix(top, ncol = 1L)
  top <- as.matrix(top)
  use_k <- min(as.integer(k)[1L], ncol(top))
  truth <- as.character(truth)
  mean(vapply(seq_along(truth), function(i) {
    truth[[i]] %in% as.character(top[i, seq_len(use_k), drop = TRUE])
  }, logical(1L)), na.rm = TRUE)
}

last_prediction_value <- function(x) {
  if (is.list(x) && !is.data.frame(x)) return(x[[length(x)]])
  if (length(dim(x)) == 3L) return(x[, , dim(x)[3L], drop = TRUE])
  x
}

metric_from_pred <- function(y_true, pred_obj, y_train = NULL) {
  yp <- last_prediction_value(pred_obj$Ypred)
  if (is.factor(y_true)) {
    pred <- NULL
    if (is.data.frame(yp)) pred <- as.factor(yp[[1L]])
    if (is.null(pred) && is.factor(yp)) pred <- as.factor(yp)
    if (is.null(pred) && is.matrix(yp) && ncol(yp) == 1L) pred <- as.factor(yp[, 1L])
    if (is.null(pred) && is.vector(yp)) pred <- as.factor(yp)
    if (is.null(pred) && length(dim(yp)) == 3L) {
      mat <- yp[, , 1L, drop = FALSE]
      lev <- pred_obj$lev
      if (is.null(lev)) lev <- levels(y_true)
      cls <- apply(mat, 1L, which.max)
      pred <- factor(lev[cls], levels = lev)
    }
    if (is.null(pred) && is.matrix(yp) && ncol(yp) > 1L) {
      lev <- colnames(yp)
      if (is.null(lev)) lev <- levels(y_true)
      pred <- factor(lev[max.col(yp, ties.method = "first")], levels = lev)
    }
    if (is.null(pred)) stop("Cannot decode classification predictions")
    val <- mean(as.character(pred) == as.character(y_true), na.rm = TRUE)
    secondary <- classification_secondary_metrics(y_true, pred)
    return(list(
      metric_name = "accuracy",
      metric_value = as.numeric(val),
      pred = pred,
      top5_accuracy = classification_topk_accuracy(pred_obj, y_true, 5L),
      balanced_accuracy = as.numeric(secondary$balanced_accuracy),
      macro_f1 = as.numeric(secondary$macro_f1)
    ))
  }

  if (is_float32_matrix(yp) && is_float32_matrix(y_true)) {
    if (!identical(dim(yp), dim(y_true))) {
      stop("Float32 prediction dimensions do not match the response dimensions")
    }
    residual <- yp - y_true
    press <- as.numeric(float::dbl(sum(residual * residual)))
    if (ncol(y_true) == 1L) {
      train_mean <- as.numeric(float::dbl(colMeans(y_train)))[[1L]]
      centered <- y_true - train_mean
      tss <- as.numeric(float::dbl(sum(centered * centered)))
      q2 <- if (is.finite(tss) && tss > 0) 1 - (press / tss) else NA_real_
      return(list(metric_name = "q2", metric_value = as.numeric(q2), pred = yp))
    }
    rmsd <- sqrt(press / (nrow(y_true) * ncol(y_true)))
    return(list(metric_name = "rmsd", metric_value = as.numeric(rmsd), pred = yp))
  }

  y_num <- as_double_matrix(y_true)
  pred_num <- NULL
  if (length(dim(yp)) == 3L) {
    pred_num <- as.matrix(yp[, , 1L, drop = TRUE])
  } else if (is.matrix(yp)) {
    pred_num <- yp
  } else {
    pred_num <- as_double_matrix(yp)
  }
  if (!all(dim(pred_num) == dim(y_num))) {
    pred_num <- matrix(as.numeric(pred_num), nrow = nrow(y_num), ncol = ncol(y_num))
  }
  if (ncol(y_num) == 1L) {
    train_mean <- suppressWarnings(mean(as.numeric(as_double_matrix(y_train)), na.rm = TRUE))
    if (!is.finite(train_mean)) {
      train_mean <- mean(y_num[, 1L], na.rm = TRUE)
    }
    press <- sum((pred_num[, 1L] - y_num[, 1L])^2, na.rm = TRUE)
    tss <- sum((y_num[, 1L] - train_mean)^2, na.rm = TRUE)
    q2 <- if (is.finite(tss) && tss > 0) 1 - (press / tss) else NA_real_
    return(list(metric_name = "q2", metric_value = as.numeric(q2), pred = pred_num))
  }

  rmsd <- sqrt(mean((pred_num - y_num)^2, na.rm = TRUE))
  list(metric_name = "rmsd", metric_value = as.numeric(rmsd), pred = pred_num)
}

safe_accuracy <- function(truth, pred) {
  mean(as.character(truth) == as.character(pred), na.rm = TRUE)
}

write_one_row_csv <- function(row, path) {
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  utils::write.csv(row, file = path, row.names = FALSE, quote = TRUE)
}
