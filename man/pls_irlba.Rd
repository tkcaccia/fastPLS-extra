\name{pls_irlba}
\alias{pls_irlba}
\alias{predict.fastPLSextra}
\title{PLS Models Using the Companion Iterative Solver}
\description{Fits SIMPLS or PLS-SVD using the native PLS engines supplied by
fastPLS, with IRLBA as the direction solver.}
\usage{
pls_irlba(Xtrain, Ytrain, Xtest = NULL, ncomp = 2L,
  method = c("simpls", "plssvd"),
  scaling = c("center", "autoscale", "none"), fit = FALSE, seed = 1L)
\method{predict}{fastPLSextra}(object, newdata, ...)
}
\arguments{
\item{Xtrain}{Finite predictor matrix.}
\item{Ytrain}{Finite numeric response vector or matrix, including explicitly
dummy-coded responses. Factor labels are not decoded by this interface.}
\item{Xtest}{Optional independent predictor matrix.}
\item{ncomp}{Positive component counts, sorted and deduplicated internally.}
\item{method}{PLS model family.}
\item{scaling}{Predictor centering, centering and unit-variance scaling, or
neither. Responses are centered.}
\item{fit}{Whether to retain training fitted responses.}
\item{seed}{Reproducible seed; the caller's RNG state is restored.}
\item{object}{A model returned by \code{pls_irlba}.}
\item{newdata}{Independent predictors with the training column order.}
\item{...}{Reserved; no additional prediction controls are currently used.}
}
\value{A serializable model with projection \code{R}, response loadings
\code{Q}, training \code{scores}, predictor means/scales \code{mX}/\code{vX},
response means \code{mY}, component counts \code{ncomp}, optional \code{Yfit}
and training \code{R2Y}, model \code{method}, and per-decomposition
\code{convergence} records. PLS-SVD additionally stores compact prediction
\code{weights}. \code{Ypred} is included when \code{Xtest} is supplied.
Prediction returns a list of numeric matrices named by component count.
When \code{fit=FALSE}, fitted responses and training R2 are omitted.}
\details{This development interface supports explicit CPU float64 fits.
It does not yet replace all former implicit, float32 or accelerator IRLBA
routes. No PLS algorithm is copied into this package: its compiled adapter
uses the installed fastPLS native headers. Nonconvergence raises an error.
The convergence record identifies dense full-subspace decompositions
separately from iterative IRLBA calls.}
\examples{
x <- as.matrix(mtcars[, c("disp", "hp", "wt")])
y <- mtcars$mpg
model <- pls_irlba(x, y, ncomp = 2)
head(predict(model, x)[[1]])
}
