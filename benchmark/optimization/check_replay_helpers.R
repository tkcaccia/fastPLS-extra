# No PLS fit or external estimator is run in these helper tests.
source("benchmark/optimization/replay_helpers.R")
path <- tempfile(fileext = ".R")
writeLines(c("stop('top-level execution is forbidden')",
    "keep <- function(x) x + 1", "forbidden <- function() stop('not loaded')"), path)
environment <- new.env(parent = baseenv())
load_replay_functions(path, "keep", environment)
stopifnot(environment$keep(1) == 2, !exists("forbidden", environment, inherits = FALSE))
unlink(path)
stored <- data.frame(case = "x", component = c(1, 2), fast_metric = c(.8, .9))
stopifnot(replay_stored_match(data.frame(case = "x", component = 2), stored,
    c("case", "component"))$fast_metric == .9)
stopifnot(inherits(try(replay_stored_match(data.frame(case = "x", component = 2),
    rbind(stored, stored), c("case", "component")), silent = TRUE), "try-error"))
case <- list(x_train = matrix(1:8, 4), x_test = matrix(1:4, 2),
    y_train = factor(c("a", "b", "a", "b")), y_test = factor(c("a", "b")),
    task = "classification", ncomp = 2)
row <- data.frame(family = "OPLS", north = 3)
calls <- list()
fake <- function(...) {
    calls[[length(calls) + 1L]] <<- list(...)
    list(Ypred = data.frame(`ncomp=2` = factor(c("a", "b"))))
}
result <- replay_case_fit(case, row, fake)
stopifnot(result$metric == 1, result$status == "success", length(calls) == 1,
    calls[[1L]]$north == 3, calls[[1L]]$svd.method == "irlba")
row <- data.frame(family = "kernelPLS", kernel = "poly", gamma = .25, degree = 4, coef0 = 1)
invisible(replay_case_fit(case, row, fake))
stopifnot(calls[[2L]]$method == "kernelpls", calls[[2L]]$gamma == .25,
    calls[[2L]]$degree == 4, calls[[2L]]$coef0 == 1)
bad <- replay_case_fit(case, row, function(...) stop("test failure"))
stopifnot(bad$status == "error", bad$error == "test failure", is.na(bad$metric))
cat("Replay loader, exact row matching, setting preservation, and failure retention: OK\n")
settings <- new.env(parent = baseenv())
load_replay_settings("benchmark/benchmark_opls_kernel_setting_reliability.R", settings)
case$name <- "synthetic_regression_p_lt_n"
case$source <- "synthetic"
grid <- replay_setting_grid(list(case), settings$opls_settings, settings$kernel_settings)
stopifnot(nrow(grid) == 11L, sum(grid$family == "OPLS") == 3L,
    grid$gamma[grid$setting == "rbf_gamma_0.25_over_p"] == .25 / ncol(case$x_train),
    grid$degree[grid$setting == "poly_degree4_offset1"] == 4L)
cat("Source-only setting grid generation: OK\n")
fixture <- tempfile(fileext = ".R")
writeLines(c("stop('do not execute setup')", "synthetic_seeds <- 101L",
    "tasks <- list(list(seed=synthetic_seeds))", "task_manifest <- stop('no fits')",
    "stop('do not execute benchmark loop')", "task_manifest <- 'later annotation'"), fixture)
tasks <- load_simpls_replay_tasks(fixture, new.env(parent = baseenv()))
stopifnot(length(tasks) == 1L, tasks[[1L]]$seed == 101L)
unlink(fixture)
cat("Task loader stops before the first manifest and all fit loops: OK\n")
prediction_helpers <- new.env(parent = .GlobalEnv)
load_replay_functions("benchmark/benchmark_simpls_estimator_preservation.R",
    c("slice_cube", "fast_prediction", "prediction_metric"), prediction_helpers)
values <- array(seq_len(12), c(3L, 2L, 2L))
prediction <- prediction_helpers$fast_prediction(list(Ypred = values), 2L, 4L)
stopifnot(identical(prediction, values[, , 2L]),
    prediction_helpers$prediction_metric("regression", prediction, values[, , 2L]) == 0)
cat("SIMPLS prediction helper dependencies and component slices: OK\n")
complete <- list(data.frame(status = "success", candidate_metric = 1))
selected <- list(data.frame(complete = TRUE))
stopifnot(replay_check_completion(complete, complete, selected, 1L, 1L))
failed <- list(data.frame(status = "error", candidate_metric = NA_real_))
stopifnot(inherits(try(replay_check_completion(failed, failed, selected, 1L, 1L),
    silent = TRUE), "try-error"))
cat("Failed scientific rows do not produce a successful replay exit: OK\n")
