.matrix <- function(x, name) {
    if (inherits(x, "float32")) {
        stop(name, ": this companion currently supports CPU float64 only")
    }
    if (!is.matrix(x) && !is.data.frame(x)) {
        if (is.numeric(x)) x <- matrix(x, ncol = 1L)
    }
    x <- as.matrix(x)
    if (!is.numeric(x) || any(!is.finite(x)) || !length(x)) {
        stop(name, " must be a nonempty finite numeric matrix")
    }
    storage.mode(x) <- "double"
    x
}

.integer <- function(x, name, minimum = 1L) {
    if (!is.numeric(x) || !length(x) || anyNA(x) ||
        any(!is.finite(x) | x < minimum | x > .Machine$integer.max | x != trunc(x))) {
        stop(name, " must contain valid integer values")
    }
    as.integer(x)
}

.with_seed <- function(seed, expression) {
    seed <- .integer(seed, "seed", 0L)
    if (length(seed) != 1L) stop("seed must have length one")
    present <- exists(".Random.seed", .GlobalEnv, inherits = FALSE)
    if (present) previous <- get(".Random.seed", .GlobalEnv)
    on.exit({
        if (present) assign(".Random.seed", previous, .GlobalEnv) else
            if (exists(".Random.seed", .GlobalEnv, inherits = FALSE))
                rm(".Random.seed", envir = .GlobalEnv)
    })
    set.seed(seed)
    force(expression)
}

irlba <- function(x, ncomp, seed = 1L, work = 0L, maxit = 1000L,
                  tol = 1e-5, eps = 1e-9, svtol = 1e-5) {
    x <- .matrix(x, "x")
    ncomp <- .integer(ncomp, "ncomp")
    work <- .integer(work, "work", 0L)
    maxit <- .integer(maxit, "maxit")
    if (length(ncomp) != 1L || ncomp > min(dim(x)) ||
        length(work) != 1L || length(maxit) != 1L) stop("Invalid solver dimensions")
    tolerances <- c(tol, eps, svtol)
    if (length(tolerances) != 3L || any(!is.finite(tolerances)) ||
        any(tolerances < 0 | tolerances > 1)) stop("Invalid solver tolerances")
    .with_seed(seed, extra_irlba_cpp(x, ncomp, work, maxit, tol, eps, svtol))
}

irlba_crossprod <- function(x, y, ncomp, seed = 1L, work = 0L,
                            maxit = 1000L, tol = 1e-5, eps = 1e-9, svtol = 1e-5) {
    x <- .matrix(x, "x")
    y <- .matrix(y, "y")
    ncomp <- .integer(ncomp, "ncomp")
    work <- .integer(work, "work", 0L)
    maxit <- .integer(maxit, "maxit")
    if (nrow(x) != nrow(y) || length(ncomp) != 1L ||
        ncomp > min(nrow(x), ncol(x), ncol(y)) || length(work) != 1L ||
        length(maxit) != 1L) stop("Invalid cross-product dimensions")
    tolerances <- c(tol, eps, svtol)
    if (length(tolerances) != 3L || any(!is.finite(tolerances)) ||
        any(tolerances < 0 | tolerances > 1)) stop("Invalid solver tolerances")
    .with_seed(seed, extra_irlba_crossprod_cpp(x, y, ncomp,
        work, maxit, tol, eps, svtol))
}

pls_irlba <- function(Xtrain, Ytrain, Xtest = NULL, ncomp = 2L,
                      method = c("simpls", "plssvd"),
                      scaling = c("center", "autoscale", "none"),
                      fit = FALSE, seed = 1L) {
    method <- match.arg(method)
    scaling <- match.arg(scaling)
    Xtrain <- .matrix(Xtrain, "Xtrain")
    Ytrain <- .matrix(Ytrain, "Ytrain")
    ncomp <- sort(unique(.integer(ncomp, "ncomp")))
    if (nrow(Xtrain) < 2L || nrow(Xtrain) != nrow(Ytrain)) {
        stop("Training matrices must have matching rows and at least two samples")
    }
    bound <- min(nrow(Xtrain) - as.integer(scaling != "none"), ncol(Xtrain))
    if (method == "plssvd") bound <- min(bound, ncol(Ytrain))
    if (max(ncomp) > bound) stop("ncomp exceeds the structural component bound")
    if (!is.logical(fit) || length(fit) != 1L || is.na(fit)) stop("fit must be TRUE or FALSE")
    model <- .with_seed(seed, extra_pls_cpp(Xtrain, Ytrain, ncomp,
        method, match(scaling, c("center", "autoscale", "none")), fit))
    class(model) <- "fastPLSextra"
    if (!fit) {
        model$Yfit <- NULL
        model$R2Y <- NULL
    }
    if (!is.null(Xtest)) model$Ypred <- predict(model, Xtest)
    model
}

predict.fastPLSextra <- function(object, newdata, ...) {
    newdata <- .matrix(newdata, "newdata")
    if (ncol(newdata) != nrow(object$R)) stop("Predictor column count differs from training")
    predicted <- extra_predict_cpp(object, newdata)
    names(predicted) <- paste0("ncomp=", object$ncomp)
    predicted
}
