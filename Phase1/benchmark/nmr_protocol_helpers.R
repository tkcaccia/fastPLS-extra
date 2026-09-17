# Shared NMR protocol used by component selection and final method comparisons.

.fastpls_canonical_nmr <- list(
  md5 = "5b6f7dfc0a3572aabce90d437808f309",
  n_train = 1200L,
  n_test = 321L,
  p = 13000L,
  q = 28355L
)

fastpls_nmr_protocol <- function(input) {
  input_md5 <- unname(tools::md5sum(input))
  if (!identical(input_md5, .fastpls_canonical_nmr$md5)) {
    stop(
      "The NMR publication benchmark requires the canonical stored data file.",
      call. = FALSE
    )
  }
  data_env <- new.env(parent = emptyenv())
  load(input, envir = data_env)
  required <- c("Xtrain", "Ytrain", "Xtest", "Ytest")
  if (!all(required %in% ls(data_env))) {
    stop("Input must contain Xtrain, Ytrain, Xtest, and Ytest.", call. = FALSE)
  }

  Xtrain <- as.matrix(get("Xtrain", envir = data_env))
  Ytrain <- as.matrix(get("Ytrain", envir = data_env))
  Xtest <- as.matrix(get("Xtest", envir = data_env))
  Ytest <- as.matrix(get("Ytest", envir = data_env))

  if (ncol(Xtrain) != ncol(Xtest) || ncol(Ytrain) != ncol(Ytest)) {
    stop("Training and test matrix dimensions are incompatible.", call. = FALSE)
  }
  if (!identical(colnames(Xtrain), colnames(Xtest))) {
    stop("Xtrain and Xtest predictor columns are not identical.", call. = FALSE)
  }
  if (!identical(colnames(Ytrain), colnames(Ytest))) {
    stop("Ytrain and Ytest response columns are not identical.", call. = FALSE)
  }
  observed_dimensions <- c(
    n_train = nrow(Xtrain), n_test = nrow(Xtest),
    p = ncol(Xtrain), q = ncol(Ytrain)
  )
  expected_dimensions <- unlist(
    .fastpls_canonical_nmr[c("n_train", "n_test", "p", "q")],
    use.names = TRUE
  )
  if (!identical(as.integer(observed_dimensions), as.integer(expected_dimensions))) {
    stop(
      "The NMR publication benchmark received noncanonical matrix dimensions.",
      call. = FALSE
    )
  }

  x_axis <- suppressWarnings(as.numeric(colnames(Xtrain)))
  water_columns <- which(is.finite(x_axis) & x_axis > 4.6 & x_axis < 4.8)
  if (!length(water_columns)) {
    stop(
      "No predictor columns were found in the required 4.6-4.8 ppm interval.",
      call. = FALSE
    )
  }
  Xtrain[, water_columns] <- 0
  Xtest[, water_columns] <- 0
  if (any(Xtrain[, water_columns, drop = FALSE] != 0) ||
      any(Xtest[, water_columns, drop = FALSE] != 0)) {
    stop("The predictor water-region mask was not applied completely.", call. = FALSE)
  }

  signature <- function(x) {
    finite <- is.finite(x)
    values <- x[finite]
    c(
      nrow = nrow(x), ncol = ncol(x), finite = sum(finite),
      sum = sum(values), sumsq = sum(values * values)
    )
  }

  metadata <- list(
    protocol_version = "nmr_matched_v2",
    input = normalizePath(input, winslash = "/", mustWork = TRUE),
    input_md5 = input_md5,
    canonical_input_verified = TRUE,
    outer_split = "predefined Xtrain/Ytrain and Xtest/Ytest objects",
    response_target = "full, unchanged multivariate Y spectrum",
    response_metric_columns = "all Y columns",
    response_columns_scored = ncol(Ytest),
    scaling = "column centering only; scale=FALSE",
    water_rule = "set X columns with 4.6 < chemical shift < 4.8 ppm to zero",
    water_applied_to = "Xtrain and Xtest only, before any inner split or model fit",
    water_columns_masked = length(water_columns),
    n_train = nrow(Xtrain),
    n_test = nrow(Xtest),
    p = ncol(Xtrain),
    q = ncol(Ytrain),
    Xtrain_signature = signature(Xtrain),
    Xtest_signature = signature(Xtest),
    Ytrain_signature = signature(Ytrain),
    Ytest_signature = signature(Ytest)
  )

  list(
    Xtrain = Xtrain, Ytrain = Ytrain, Xtest = Xtest, Ytest = Ytest,
    x_axis = x_axis, water_columns = water_columns, metadata = metadata
  )
}

write_fastpls_nmr_manifest <- function(metadata, path, extra = list()) {
  values <- c(metadata, extra)
  lines <- unlist(lapply(names(values), function(name) {
    value <- values[[name]]
    if (is.list(value)) value <- unlist(value, use.names = TRUE)
    if (length(value) > 1L) {
      paste0(name, ".", names(value) %||% seq_along(value), "=", format(value, digits = 16))
    } else {
      paste0(name, "=", format(value, digits = 16))
    }
  }), use.names = FALSE)
  writeLines(lines, path)
  invisible(path)
}

`%||%` <- function(x, y) if (is.null(x)) y else x
