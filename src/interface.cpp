// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Stefano Cacciatore
#include <RcppArmadillo.h>
#include <fastpls/native/simpls.hpp>
#include <fastpls/native/plssvd.hpp>
#include "irlba_workspace.h"

class Solver {
 public:
  int work = 0, maxit = 1000;
  double tol = 1e-5, eps = 1e-9, svtol = 1e-5;
  std::vector<int> iterations, products, statuses;
  std::vector<std::string> algorithms;
  fastpls_svd::IrlbaWorkspace workspace;
  fastpls::native::SingularTriplets<double> solve(const arma::mat& A, int k, bool left) {
    if (!A.is_finite() || A.is_empty() || k < 1 || arma::uword(k) > std::min(A.n_rows, A.n_cols))
      Rcpp::stop("Invalid IRLBA matrix or rank");
    const int width = std::min(int(std::min(A.n_rows, A.n_cols)),
                              work <= k ? std::max(k + 7, 8) : work);
    if (std::min(A.n_rows, A.n_cols) < 6 || width == int(std::min(A.n_rows, A.n_cols))) {
      iterations.push_back(0); products.push_back(0); statuses.push_back(0);
      algorithms.push_back("dense_full_subspace");
      return fastpls::native::dense_triplets(A, k, left);
    }
    workspace.solve(const_cast<double*>(A.memptr()), nullptr,
      int(A.n_rows), int(A.n_cols), k, width, maxit, tol, eps, svtol);
    iterations.push_back(workspace.iterations);
    products.push_back(workspace.products);
    statuses.push_back(workspace.status);
    algorithms.push_back("irlba");
    if (workspace.status != 0) Rcpp::stop("IRLBA did not converge (status %d)", workspace.status);
    fastpls::native::SingularTriplets<double> out;
    out.U = workspace.U.head_cols(k);
    out.s = workspace.s;
    if (!left) out.Vt = workspace.V.head_cols(k).t();
    if (!out.U.is_finite() || !out.s.is_finite() || !out.Vt.is_finite())
      Rcpp::stop("IRLBA returned non-finite factors");
    return out;
  }
  Rcpp::List diagnostics() const {
    return Rcpp::List::create(Rcpp::Named("status") = statuses,
      Rcpp::Named("iterations") = iterations, Rcpp::Named("products") = products,
      Rcpp::Named("algorithm") = algorithms);
  }

};

template<class Model>
Rcpp::List wrap_model(const Model& model, const std::string& family, const Solver& solver) {
  Rcpp::List result = Rcpp::List::create(
    Rcpp::Named("R") = model.R, Rcpp::Named("Q") = model.Q,
    Rcpp::Named("mX") = model.x_mean,
    Rcpp::Named("vX") = model.x_scale, Rcpp::Named("mY") = model.y_mean,
    Rcpp::Named("ncomp") = model.components, Rcpp::Named("method") = family,
    Rcpp::Named("convergence") = solver.diagnostics());
  if (model.fitted.n_slices > 0) {
    result["Yfit"] = model.fitted;
    result["R2Y"] = model.r2;
  }
  return result;
}

// [[Rcpp::export]]
Rcpp::List extra_pls_cpp(const arma::mat& x, const arma::mat& y,
                        arma::ivec components, std::string method, int scaling, bool fitted) {
  Solver solver;
  if (method == "simpls") {
    fastpls::native::SimplsOptions options;
    options.scaling = scaling; options.fitted = fitted;
    options.randomized_directions = false;
    options.store_scores = false;
    options.store_coefficients = false;
    auto direction = [&](const arma::mat& A, const arma::mat&, bool, int,
                          unsigned int, arma::mat& U) {
      U = solver.solve(A, 1, true).U;
      return U.n_cols > 0;
    };
    arma::mat x_workspace = x;
    auto model = fastpls::native::fit_simpls_with_solver(
      x, y, components, options, direction, &x_workspace
    );
    if (model.completed_components < components.max()) Rcpp::stop("SIMPLS stopped before the requested component");
    return wrap_model(model, method, solver);
  }
  if (method != "plssvd") Rcpp::stop("Unknown PLS family");
  fastpls::native::PlssvdOptions options;
  options.scaling = scaling;
  options.fitted = fitted;
  options.store_coefficients = false;
  options.cache_score_gram = true;
  auto decompose = [&](const arma::mat& A, int k, int) { return solver.solve(A, k, false); };
  arma::mat x_workspace = x;
  auto model = fastpls::native::fit_plssvd_with_solver(
    x, y, components, options, decompose, &x_workspace
  );
  Rcpp::List result = wrap_model(model, method, solver);
  result["weights"] = model.prediction_weights;
  return result;
}

// [[Rcpp::export]]
Rcpp::List extra_predict_cpp(Rcpp::List model, const arma::mat& x) {
  const std::string family = Rcpp::as<std::string>(model["method"]);
  const arma::ivec counts = Rcpp::as<arma::ivec>(model["ncomp"]);
  if (counts.n_elem < 1 || arma::any(counts < 1) ||
      (counts.n_elem > 1 && arma::any(arma::diff(counts) <= 0))) {
    Rcpp::stop("Stored component counts must be strictly increasing");
  }
  arma::mat standardized = x;
  const arma::mat x_mean = Rcpp::as<arma::mat>(model["mX"]);
  const arma::mat x_scale = Rcpp::as<arma::mat>(model["vX"]);
  const arma::mat y_mean = Rcpp::as<arma::mat>(model["mY"]);
  if (standardized.n_cols != x_mean.n_cols ||
      standardized.n_cols != x_scale.n_cols) {
    Rcpp::stop("Predictor column count differs from training");
  }
  standardized.each_row() -= x_mean;
  standardized.each_row() /= x_scale;
  Rcpp::List out(counts.n_elem);
  if (family == "simpls") {
    const arma::mat R = Rcpp::as<arma::mat>(model["R"]);
    const arma::mat Q = Rcpp::as<arma::mat>(model["Q"]);
    const int maximum = counts.max();
    if (R.n_cols < static_cast<arma::uword>(maximum) ||
        Q.n_cols < static_cast<arma::uword>(maximum) ||
        Q.n_rows != y_mean.n_cols) {
      Rcpp::stop("SIMPLS model dimensions are inconsistent");
    }
    const arma::mat scores = standardized * R.cols(0, maximum - 1);
    arma::mat prediction(x.n_rows, Q.n_rows, arma::fill::zeros);
    int previous = 0;
    for (arma::uword j = 0; j < counts.n_elem; ++j) {
      const int current = counts(j);
      prediction += scores.cols(previous, current - 1) *
        Q.cols(previous, current - 1).t();
      arma::mat value = prediction;
      value.each_row() += y_mean;
      out[j] = value;
      previous = current;
    }
  } else {
    if (family != "plssvd") Rcpp::stop("Unknown PLS family");
    const arma::mat R = Rcpp::as<arma::mat>(model["R"]);
    const arma::cube weights = Rcpp::as<arma::cube>(model["weights"]);
    const int maximum = counts.max();
    if (R.n_cols < static_cast<arma::uword>(maximum) ||
        weights.n_slices < counts.n_elem ||
        weights.n_cols != y_mean.n_cols) {
      Rcpp::stop("PLS-SVD model dimensions are inconsistent");
    }
    const arma::mat scores = standardized * R.cols(0, maximum - 1);
    for (arma::uword j = 0; j < counts.n_elem; ++j) {
      const int current = counts(j);
      arma::mat value = scores.cols(0, current - 1) *
        weights.slice(j).rows(0, current - 1);
      value.each_row() += y_mean;
      out[j] = value;
    }
  }
  return out;
}
