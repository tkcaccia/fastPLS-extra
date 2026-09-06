\name{irlba}
\alias{irlba}
\alias{irlba_crossprod}
\title{Iterative Truncated Singular Value Decomposition}
\description{Computes selected leading singular triplets using the GPL-licensed
IRLBA implementation preserved from fastPLS.}
\usage{irlba(x, ncomp, seed = 1L, work = 0L, maxit = 1000L,
  tol = 1e-5, eps = 1e-9, svtol = 1e-5)
irlba_crossprod(x, y, ncomp, seed = 1L, work = 0L, maxit = 1000L,
  tol = 1e-5, eps = 1e-9, svtol = 1e-5)}
\arguments{
\item{x}{Finite numeric matrix. Only CPU float64 is currently supported.}
\item{y}{Finite numeric matrix with the same rows as \code{x}.}
\item{ncomp}{Number of leading singular triplets.}
\item{seed}{Reproducible starting seed; the caller's RNG state is restored.}
\item{work}{Working subspace size; zero selects the solver default.}
\item{maxit}{Maximum iteration count.}
\item{tol}{Residual convergence tolerance.}
\item{eps}{Orthogonality threshold.}
\item{svtol}{Singular-value convergence tolerance.}
}
\value{A list with left vectors \code{u}, singular values \code{d}, right
vectors \code{v}, and \code{convergence}, containing the status, iteration
count, matrix-vector product count and actual \code{algorithm} used.
Nonconvergence raises an error. For matrices with a dimension below six, or
when the working subspace spans the smaller matrix dimension, a dense SVD
is used. It is labelled \code{dense_full_subspace}, with zero iteration and
product counts, rather than being reported as an iterative IRLBA result.}
\details{\code{irlba_crossprod} decomposes \eqn{x^T y} without forming that
matrix. Inputs are used as supplied, without centering or scaling. The
iterative route uses composed products and is labelled \code{irlba_crossprod}.
When the working subspace spans the smaller product dimension, factor QR
decompositions and a reduced SVD are used instead, labelled
\code{factor_product_full_subspace}. This avoids forming the cross-product
but still requires factor, basis and reduced-decomposition workspaces.}
\examples{
set.seed(1)
x <- matrix(rnorm(200), 20, 10)
irlba(x, 2)$d
}
