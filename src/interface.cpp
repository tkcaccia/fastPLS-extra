// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Stefano Cacciatore
#include <RcppArmadillo.h>
#include <fastpls/native/simpls.hpp>
#include <fastpls/native/plssvd.hpp>
#include <fastpls/native/operators.hpp>
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

  template<class Operator>
  fastpls::native::SingularTriplets<double> solve_operator(Operator& A, int k) {
    const int bound = std::min(A.n_rows, A.n_cols);
    if (k < 1 || k > bound) Rcpp::stop("Invalid operator rank");
    const int width = std::min(bound, work <= k ? std::max(k + 7, 8) : work);
    fastpls::native::SingularTriplets<double> out;
    if (bound < 6 || width == bound) {
      arma::mat V;
      A.full_svd(out.U, out.s, V, false);
      if (out.s.n_elem < arma::uword(k)) Rcpp::stop("Operator rank bound exceeded");
      out.U = out.U.head_cols(k).eval();
      out.s = out.s.head(k).eval();
      out.Vt = V.head_cols(k).t();
      iterations.push_back(0); products.push_back(0); statuses.push_back(0);
      algorithms.push_back("factor_product_full_subspace");
    } else {
      fastpls_irlba_operator callback;
      callback.data = &A;
      callback.mult = [](char transpose, int rows, int columns, void* data,
                         double* input, double* output) {
        const bool transposed = transpose == 't' || transpose == 'T';
        arma::mat rhs(input, transposed ? rows : columns, 1, false, true);
        arma::mat target(output, transposed ? columns : rows, 1, false, true);
        target = static_cast<Operator*>(data)->multiply(rhs, transposed);
      };
      workspace.solve(nullptr, &callback, A.n_rows, A.n_cols, k, width,
                      maxit, tol, eps, svtol);
      iterations.push_back(workspace.iterations);
      products.push_back(workspace.products); statuses.push_back(workspace.status);
      algorithms.push_back("irlba_crossprod");
      if (workspace.status != 0)
        Rcpp::stop("IRLBA did not converge (status %d)", workspace.status);
      out.U = workspace.U.head_cols(k);
      out.s = workspace.s;
      out.Vt = workspace.V.head_cols(k).t();
    }
    if (!out.U.is_finite() || !out.s.is_finite() || !out.Vt.is_finite())
      Rcpp::stop("IRLBA operator returned non-finite factors");
    return out;
  }
};

// [[Rcpp::export]]
Rcpp::List extra_irlba_crossprod_cpp(const arma::mat& x, const arma::mat& y,
                                    int k, int work, int maxit,
                                    double tol, double eps, double svtol) {
  fastpls::native::CrosscovOperator<double> op(x, y, 0);
  Solver solver;
  solver.work = work; solver.maxit = maxit;
  solver.tol = tol; solver.eps = eps; solver.svtol = svtol;
  auto result = solver.solve_operator(op, k);
  return Rcpp::List::create(Rcpp::Named("u") = result.U,
    Rcpp::Named("d") = result.s, Rcpp::Named("v") = arma::mat(result.Vt.t()),
    Rcpp::Named("convergence") = solver.diagnostics());
}

// [[Rcpp::export]]
Rcpp::List extra_irlba_cpp(const arma::mat& x, int k, int work, int maxit,
                          double tol, double eps, double svtol) {
  Solver solver;
  solver.work = work; solver.maxit = maxit;
  solver.tol = tol; solver.eps = eps; solver.svtol = svtol;
  auto result = solver.solve(x, k, false);
  return Rcpp::List::create(Rcpp::Named("u") = result.U,
    Rcpp::Named("d") = result.s, Rcpp::Named("v") = arma::mat(result.Vt.t()),
    Rcpp::Named("convergence") = solver.diagnostics());
}

template<class Model>
Rcpp::List wrap_model(const Model& model, const std::string& family, const Solver& solver) {
  return Rcpp::List::create(Rcpp::Named("R") = model.R, Rcpp::Named("Q") = model.Q,
    Rcpp::Named("scores") = model.scores, Rcpp::Named("mX") = model.x_mean,
    Rcpp::Named("vX") = model.x_scale, Rcpp::Named("mY") = model.y_mean,
    Rcpp::Named("ncomp") = model.components, Rcpp::Named("Yfit") = model.fitted,
    Rcpp::Named("R2Y") = model.r2, Rcpp::Named("method") = family,
    Rcpp::Named("convergence") = solver.diagnostics());
}

// [[Rcpp::export]]
Rcpp::List extra_pls_cpp(const arma::mat& x, const arma::mat& y,
                        arma::ivec components, std::string method, int scaling, bool fitted) {
  Solver solver;
  if (method == "simpls") {
    fastpls::native::SimplsOptions options;
    options.scaling = scaling; options.fitted = fitted;
    options.randomized_directions = false; options.store_scores = true;
    auto direction = [&](const arma::mat& A, const arma::mat&, bool, int,
                          unsigned int, arma::mat& U) {
      U = solver.solve(A, 1, true).U;
      return U.n_cols > 0;
    };
    auto model = fastpls::native::fit_simpls_with_solver(x, y, components, options, direction);
    if (model.completed_components < components.max()) Rcpp::stop("SIMPLS stopped before the requested component");
    return wrap_model(model, method, solver);
  }
  if (method != "plssvd") Rcpp::stop("Unknown PLS family");
  fastpls::native::PlssvdOptions options;
  options.scaling = scaling; options.fitted = fitted;
  auto decompose = [&](const arma::mat& A, int k, int) { return solver.solve(A, k, false); };
  auto model = fastpls::native::fit_plssvd_with_solver(x, y, components, options, decompose);
  Rcpp::List result = wrap_model(model, method, solver);
  result["weights"] = model.prediction_weights;
  return result;
}

// [[Rcpp::export]]
Rcpp::List extra_predict_cpp(Rcpp::List model, const arma::mat& x) {
  const std::string family = Rcpp::as<std::string>(model["method"]);
  const arma::ivec counts = Rcpp::as<arma::ivec>(model["ncomp"]);
  Rcpp::List out(counts.n_elem);
  if (family == "simpls") {
    fastpls::native::SimplsModel<double> fit;
    fit.R = Rcpp::as<arma::mat>(model["R"]); fit.Q = Rcpp::as<arma::mat>(model["Q"]);
    fit.x_mean = Rcpp::as<arma::mat>(model["mX"]); fit.x_scale = Rcpp::as<arma::mat>(model["vX"]);
    fit.y_mean = Rcpp::as<arma::mat>(model["mY"]);
    fit.completed_components = fit.R.n_cols;
    for (arma::uword j = 0; j < counts.n_elem; ++j)
      out[j] = fastpls::native::predict_simpls(fit, x, counts(j));
  } else {
    fastpls::native::PlssvdModel<double> fit;
    fit.R = Rcpp::as<arma::mat>(model["R"]); fit.components = counts;
    fit.x_mean = Rcpp::as<arma::mat>(model["mX"]); fit.x_scale = Rcpp::as<arma::mat>(model["vX"]);
    fit.y_mean = Rcpp::as<arma::mat>(model["mY"]);
    fit.prediction_weights = Rcpp::as<arma::cube>(model["weights"]);
    for (arma::uword j = 0; j < counts.n_elem; ++j)
      out[j] = fastpls::native::predict_plssvd(fit, x, j);
  }
  return out;
}
