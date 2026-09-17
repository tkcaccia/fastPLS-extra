library_path <- Sys.getenv("FASTPLS_LIBRARY", unset = NA_character_)
if (!is.na(library_path)) .libPaths(c(library_path, .libPaths()))
suppressPackageStartupMessages(library(fastPLS))

set.seed(812L)
n <- 2200L
p <- 64L
X <- matrix(rnorm(n * p), n, p)
groups <- rep(seq_len(n / 2L), each = 2L)
beta <- matrix(rnorm(p * 12L), p, 12L)
signal <- X %*% beta + matrix(rnorm(n * 12L, sd = 0.3), n, 12L)
responses <- list(
  classification = factor(max.col(signal[, seq_len(6L)], ties.method = "first")),
  regression = signal
)

cache_state <- function(enabled) {
  value <- if (enabled) "1" else "0"
  Sys.setenv(
    FASTPLS_CV_FOLD_GRAM_CACHE = value,
    FASTPLS_CV_FOLD_CROSSCOV_CACHE = value,
    FASTPLS_CV_CLASS_SUM_CACHE = value
  )
}

canonical_predictions <- function(fit, classification) {
  if (classification && is.list(fit$pred)) {
    return(lapply(fit$pred, as.character))
  }
  fit$Ypred
}

prediction_difference <- function(left, right) {
  if (is.list(left)) {
    return(if (all(vapply(seq_along(left), function(index) {
      identical(left[[index]], right[[index]])
    }, logical(1L)))) 0 else Inf)
  }
  max(abs(as.numeric(left) - as.numeric(right)), na.rm = TRUE)
}

rows <- list()
for (task in names(responses)) {
  for (method in c("plssvd", "simpls", "opls", "kernelpls")) {
    for (scaling in c("centering", "autoscaling", "none")) {
      classifiers <- if (task == "classification") c("argmax", "lda") else "argmax"
      for (classifier in classifiers) {
        call <- function(enabled) {
          cache_state(enabled)
          pls.single.cv(
            X, responses[[task]], constrain = groups,
            ncomp = c(10L, 20L), kfold = 5L, method = method,
            scaling = scaling, backend = "cpu", classifier = classifier,
            kernel = "linear", north = 1L, seed = 99L, fit = FALSE
          )
        }
        baseline <- call(FALSE)
        candidate <- call(TRUE)
        rows[[length(rows) + 1L]] <- data.frame(
          task = task,
          method = method,
          scaling = scaling,
          classifier = classifier,
          folds_identical = identical(baseline$fold, candidate$fold),
          ncomp_identical = identical(baseline$best_ncomp, candidate$best_ncomp),
          metric_difference = abs(
            baseline$best_metric_value - candidate$best_metric_value
          ),
          prediction_difference = prediction_difference(
            canonical_predictions(baseline, task == "classification"),
            canonical_predictions(candidate, task == "classification")
          ),
          stringsAsFactors = FALSE
        )
      }
    }
  }
}
result <- do.call(rbind, rows)
print(result)
stopifnot(
  all(result$folds_identical),
  all(result$ncomp_identical),
  all(result$metric_difference <= 1e-10),
  all(result$prediction_difference <= 1e-8)
)
