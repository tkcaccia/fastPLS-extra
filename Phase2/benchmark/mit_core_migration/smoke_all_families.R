args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 2L) {
    stop(paste(
        "usage: Rscript smoke_all_families.R LIBRARY OUTPUT_CSV",
        "[BACKENDS=cpu,cuda]"
    ))
}

.libPaths(c(args[[1L]], .libPaths()))
suppressPackageStartupMessages(library(fastPLS))
suppressPackageStartupMessages(library(float))

set.seed(20260909)
n <- 90L
p <- 14L
X <- matrix(rnorm(n * p), n, p)
latent <- X[, 1L] - 0.6 * X[, 2L] + 0.3 * X[, 3L]
y_class <- factor(cut(latent, quantile(latent, 0:3 / 3),
    include.lowest = TRUE, labels = c("A", "B", "C")))
Y_reg <- cbind(
    0.8 * X[, 1L] - 0.2 * X[, 4L],
    -0.5 * X[, 2L] + 0.4 * X[, 5L],
    X[, 3L] + 0.1 * X[, 6L]
) + matrix(rnorm(n * 3L, sd = 0.05), n, 3L)
train <- seq_len(66L)
test <- setdiff(seq_len(n), train)

as_double <- function(value) {
    if (inherits(value, "float32")) {
        return(float::dbl(value))
    }
    as.matrix(value)
}

prediction_at_first_component <- function(value, classification) {
    if (is.list(value)) {
        return(value[[1L]])
    }
    dimensions <- dim(value)
    if (!classification && length(dimensions) == 3L) {
        return(value[, , 1L, drop = TRUE])
    }
    value
}

backends <- if (length(args) >= 3L) {
    strsplit(args[[3L]], ",", fixed = TRUE)[[1L]]
} else {
    c("cpu", "cuda")
}
if (!length(backends) || any(!backends %in% c("cpu", "cuda", "metal"))) {
    stop("BACKENDS must contain cpu, cuda, and/or metal")
}

cases <- expand.grid(
    backend = backends,
    precision = c("float64", "float32"),
    family = c("plssvd", "simpls", "opls", "kernelpls"),
    task = c("classification", "regression"),
    stringsAsFactors = FALSE
)
cases$classifier <- "argmax"
cases$kernel <- ifelse(cases$family == "kernelpls", "rbf", "linear")
cases <- rbind(
    cases,
    data.frame(
        backend = rep(backends, each = 2L),
        precision = rep(c("float64", "float32"), length(backends)),
        family = "simpls",
        task = "classification",
        classifier = "lda",
        kernel = "linear",
        stringsAsFactors = FALSE
    )
)

run_case <- function(index) {
    case <- cases[index, ]
    classification <- case$task == "classification"
    Xtrain <- X[train, , drop = FALSE]
    Xtest <- X[test, , drop = FALSE]
    Ytrain <- if (classification) y_class[train] else Y_reg[train, , drop = FALSE]
    Ytest <- if (classification) y_class[test] else Y_reg[test, , drop = FALSE]
    if (case$precision == "float32") {
        Xtrain <- float::fl(Xtrain)
        Xtest <- float::fl(Xtest)
        if (!classification) {
            Ytrain <- float::fl(Ytrain)
            Ytest <- float::fl(Ytest)
        }
    }
    started <- proc.time()[[3L]]
    fit <- pls(
        Xtrain, Ytrain, Xtest, Ytest,
        ncomp = 2L,
        method = case$family,
        backend = case$backend,
        classifier = case$classifier,
        kernel = case$kernel,
        gamma = 0.1,
        north = 1L,
        scaling = "centering",
        fit = FALSE,
        return_variance = FALSE,
        seed = 17L
    )
    elapsed <- proc.time()[[3L]] - started
    prediction <- prediction_at_first_component(fit$Ypred, classification)
    metric <- if (classification) {
        mean(prediction == Ytest)
    } else {
        sqrt(mean((as.numeric(as_double(prediction)) -
            as.numeric(as_double(Ytest)))^2))
    }
    internal <- attr(fit, "fastPLS_internal")
    data.frame(
        backend = case$backend,
        precision = case$precision,
        family = case$family,
        classifier = case$classifier,
        task = if (classification) "classification" else "regression",
        seconds = unname(elapsed),
        metric = metric,
        prediction_checksum = if (classification) {
            sum(as.integer(prediction) * seq_along(prediction))
        } else {
            value <- as.numeric(as_double(prediction))
            sum(value * seq_along(value))
        },
        execution_route = internal$execution_route %||%
            fit$diagnostics$residency$route %||% NA_character_,
        resident_backend = internal$resident_backend %||%
            fit$diagnostics$residency$route %||% NA_character_,
        algorithm = fit$diagnostics$algorithm_variant %||% NA_character_,
        status = "ok",
        error = NA_character_,
        stringsAsFactors = FALSE
    )
}

`%||%` <- function(left, right) if (is.null(left)) right else left

results <- lapply(seq_len(nrow(cases)), function(index) {
    tryCatch(run_case(index), error = function(condition) {
        data.frame(
            backend = cases$backend[[index]],
            precision = cases$precision[[index]],
            family = cases$family[[index]],
            classifier = cases$classifier[[index]],
            task = NA_character_, seconds = NA_real_, metric = NA_real_,
            prediction_checksum = NA_real_, execution_route = NA_character_,
            resident_backend = NA_character_, algorithm = NA_character_,
            status = "error", error = conditionMessage(condition),
            stringsAsFactors = FALSE
        )
    })
})
results <- do.call(rbind, results)
write.csv(results, args[[2L]], row.names = FALSE)
print(results, row.names = FALSE)
