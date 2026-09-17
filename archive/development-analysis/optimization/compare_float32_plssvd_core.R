#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 3L) {
  stop("Usage: compare_float32_plssvd_core.R TASK_RDS LIBRARY OUTPUT_CSV")
}
.libPaths(unique(c(args[[2L]], .libPaths())))
task <- readRDS(args[[1L]])
library(fastPLS)

components <- as.integer(Sys.getenv("FASTPLS_BENCH_NCOMP", "50"))
oversample <- as.integer(Sys.getenv("FASTPLS_BENCH_OVERSAMPLE", "32"))
power <- as.integer(Sys.getenv("FASTPLS_BENCH_POWER", "5"))
seed <- as.integer(Sys.getenv("FASTPLS_BENCH_SEED", "123"))
Xtrain <- float::fl(as.matrix(task$Xtrain))
Xtest <- float::fl(as.matrix(task$Xtest))
labels <- as.integer(factor(task$Ytrain))
classes <- max(labels)

legacy <- fastPLS:::pls_float32_labels_cpp(
  Xtrain, labels, classes, components, 3L, FALSE, 1L, 0L, 3L,
  oversample, power, seed
)
candidate <- fastPLS:::pls_float32_labels_core_cpp(
  Xtrain, labels, classes, components, 3L, FALSE, 1L, oversample, power, seed
)

predict_scores <- function(model) {
  center <- fastPLS:::.float32_from_bits(model$mX)
  scale <- fastPLS:::.float32_from_bits(model$vX)
  projection <- fastPLS:::.float32_from_bits(model$R)
  weights <- fastPLS:::.float32_bits_list_to_float(model$W_latent)[[1L]]
  standardized <- fastPLS:::.float32_standardize(Xtest, center, scale)
  (standardized %*% projection) %*% weights
}

legacy_scores <- float::dbl(predict_scores(legacy))
candidate_scores <- float::dbl(predict_scores(candidate))
legacy_labels <- max.col(legacy_scores)
candidate_labels <- max.col(candidate_scores)
observed <- as.integer(factor(task$Ytest, levels = levels(task$Ytrain)))

utils::write.csv(data.frame(
  dataset = task$dataset,
  ncomp = components,
  oversample = oversample,
  power = power,
  seed = seed,
  maximum_absolute_score_difference = max(abs(
    legacy_scores - candidate_scores
  )),
  relative_score_difference = sqrt(
    sum((legacy_scores - candidate_scores)^2) /
      max(sum(legacy_scores^2), .Machine$double.eps)
  ),
  prediction_agreement = mean(legacy_labels == candidate_labels),
  legacy_accuracy = mean(legacy_labels == observed),
  candidate_accuracy = mean(candidate_labels == observed),
  legacy_checksum = sum(legacy_labels * seq_along(legacy_labels)),
  candidate_checksum = sum(candidate_labels * seq_along(candidate_labels))
), args[[3L]], row.names = FALSE)
