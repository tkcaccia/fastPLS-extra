args <- commandArgs(trailingOnly = TRUE)
output <- if (length(args)) args[[1L]] else tempfile(fileext = ".csv")
library_path <- Sys.getenv("FASTPLS_LIBRARY", unset = NA_character_)
if (!is.na(library_path)) {
  .libPaths(c(library_path, .libPaths()))
}
suppressPackageStartupMessages(library(fastPLS))

make_case <- function(case, seed) {
  set.seed(seed)
  spec <- switch(
    case,
    tall_classification = c(n = 20000L, p = 128L, q = 10L),
    tall_regression = c(n = 16000L, p = 96L, q = 8L),
    moderate_classification = c(n = 4000L, p = 128L, q = 6L)
  )
  X <- matrix(rnorm(spec[["n"]] * spec[["p"]]), spec[["n"]], spec[["p"]])
  B <- matrix(rnorm(spec[["p"]] * spec[["q"]]), spec[["p"]], spec[["q"]])
  signal <- X %*% B + matrix(rnorm(spec[["n"]] * spec[["q"]], sd = 0.5),
                             spec[["n"]], spec[["q"]])
  Y <- if (grepl("classification", case, fixed = TRUE)) {
    factor(max.col(signal, ties.method = "first"))
  } else {
    signal
  }
  list(X = X, Y = Y, spec = spec)
}

run_once <- function(data, enabled, replicate) {
  Sys.setenv(FASTPLS_CV_FOLD_GRAM_CACHE = if (enabled) "1" else "0")
  gc()
  started <- proc.time()[["elapsed"]]
  fit <- pls.single.cv(
    data$X,
    data$Y,
    ncomp = c(10L, 20L, 30L),
    kfold = 10L,
    method = "simpls",
    backend = "cpu",
    svd.method = "rsvd",
    classifier = "argmax",
    seed = 7301L,
    fit = FALSE
  )
  elapsed <- proc.time()[["elapsed"]] - started
  predictions <- if (is.list(fit$pred)) {
    vapply(fit$pred, function(x) paste(as.character(x), collapse = "|"), character(1L))
  } else {
    paste(as.character(fit$pred), collapse = "|")
  }
  data.frame(
    cache = if (enabled) "hoisted" else "fold_local",
    replicate = replicate,
    elapsed_sec = elapsed,
    best_ncomp = fit$best_ncomp,
    metric = fit$best_metric_value,
    prediction_signature = paste(predictions, collapse = "||"),
    stringsAsFactors = FALSE
  )
}

cases <- c("tall_classification", "tall_regression", "moderate_classification")
rows <- list()
for (case in cases) {
  data <- make_case(case, 4200L + match(case, cases))
  for (replicate in seq_len(7L)) {
    for (enabled in c(FALSE, TRUE)) {
      result <- run_once(data, enabled, replicate)
      result$case <- case
      result$n <- data$spec[["n"]]
      result$p <- data$spec[["p"]]
      result$q <- data$spec[["q"]]
      rows[[length(rows) + 1L]] <- result
    }
  }
}
result <- do.call(rbind, rows)
write.csv(result, output, row.names = FALSE)
print(aggregate(elapsed_sec ~ case + cache, result, median))
