// [[Rcpp::depends(RcppArmadillo)]]
// [[Rcpp::plugins(cpp17)]]
#include "float_crosscov_operator.h"

// This benchmark-only bridge is not registered or shipped as a package API.
// [[Rcpp::export]]
Rcpp::List probe_float_crosscov(arma::fmat X, arma::fmat Y, arma::fmat directions,
                               arma::fmat B, arma::fmat C, int backend) {
  fastpls_svd::FloatCrosscovOperator op(X, Y, directions.n_cols, backend);
  arma::fmat S = X.t() * Y;
  Rcpp::List rows(directions.n_cols + 1);
  for (arma::uword a = 0; a <= directions.n_cols; ++a) {
    arma::fmat forward = op.multiply(B), reverse = op.multiply(C, true);
    arma::fmat expected_forward = S * B, expected_reverse = S.t() * C;
    rows[a] = Rcpp::List::create(
      Rcpp::Named("forward_error") = arma::norm(forward - expected_forward, "fro") /
        std::max(arma::norm(expected_forward, "fro"), 1e-6f),
      Rcpp::Named("reverse_error") = arma::norm(reverse - expected_reverse, "fro") /
        std::max(arma::norm(expected_reverse, "fro"), 1e-6f),
      Rcpp::Named("forward") = forward,
      Rcpp::Named("reverse") = reverse);
    if (a < directions.n_cols) {
      arma::fvec v = directions.col(a);
      op.deflate(v);
      arma::frowvec row = v.t() * S;
      S -= v * row;
    }
  }
  arma::fmat U, V;
  arma::fvec d;
  op.full_svd(U, d, V, false);
  arma::fmat reconstructed = U * arma::diagmat(d) * V.t();
  const float reconstruction_error = arma::norm(reconstructed - S, "fro") /
    std::max(arma::norm(S, "fro"), 1e-6f);
  bool rejects_shape = false, rejects_capacity = false;
  try { op.multiply(arma::fmat(B.n_rows + 1, 1)); }
  catch (const std::exception&) { rejects_shape = true; }
  try { op.deflate(arma::fvec(X.n_cols, arma::fill::ones)); }
  catch (const std::exception&) { rejects_capacity = true; }
  return Rcpp::List::create(Rcpp::Named("products") = rows,
    Rcpp::Named("reconstruction_error") = reconstruction_error,
    Rcpp::Named("zero_width") = op.multiply(arma::fmat(Y.n_cols, 0)).n_cols == 0,
    Rcpp::Named("rejects_shape") = rejects_shape,
    Rcpp::Named("rejects_capacity") = rejects_capacity,
    Rcpp::Named("scalar_bytes") = sizeof(arma::fmat::elem_type),
    Rcpp::Named("index_bytes") = sizeof(arma::uword));
}
