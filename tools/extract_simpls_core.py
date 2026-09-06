#!/usr/bin/env python3
"""Emit an apply_patch refactor of the current owned SIMPLS implementation."""

import argparse
from pathlib import Path
import re


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise ValueError("Extraction anchor is not unique: " + old[:90])
    return text.replace(old, new, 1)


def typed(text):
    for old, new in (("arma::rowvec", "arma::Row<Scalar>"),
                     ("arma::mat", "arma::Mat<Scalar>"),
                     ("arma::vec", "arma::Col<Scalar>"),
                     ("arma::cube", "arma::Cube<Scalar>")):
        text = text.replace(old, new)
    return re.sub(r"\bdouble\b", "Scalar", text)


def added(path, text):
    return "*** Add File: " + str(path) + "\n" + "\n".join(
        "+" + line for line in text.splitlines()) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path)
    args = parser.parse_args()
    root = args.source.resolve(strict=True)
    path = root / "src/fastPLS.cpp"
    text = path.read_text()
    start = text.index("List pls_model2_fast_impl(")
    end = text.index("// [[Rcpp::export]]\nList pls_model2_fast(", start)
    old_function = text[start:end]
    body = old_function[old_function.index("  using BenchClock"):]
    body = body[:body.index("  const auto assembly_started")]
    options_start = body.index("  const int center_t =")
    options_end = body.index("  const bool use_batched_candidate_geometry", options_start)
    option_aliases = """  const int center_t = options.center_scores;
  const int reorth_v = options.reorthogonalize;
  const int defl_cache = options.cache_deflation;
  const int fast_optimized = options.cache_crossprod;
  const int incremental_coefficients = options.incremental_coefficients;
  const int fast_crossprod_min_ncomp = options.crossprod_min_components;
  const int fast_crossprod_max_p = options.crossprod_max_predictors;
  const int fast_crossprod_min_n_to_p_ratio = options.crossprod_min_ratio;
  const bool randomized_solver = options.randomized_directions;
"""
    body = body[:options_start] + option_aliases + body[options_end:]
    body = body.replace('env_int_or("FASTPLS_BENCH_PHASE_TIMING", 0, 0, 1) == 1',
                        "options.phase_timing")
    body = body.replace('env_int_or("FASTPLS_RETURN_TTRAIN", 0, 0, 1) == 1',
                        "options.store_scores")
    body = body.replace("should_store_coefficients(p, m, length_ncomp, true)",
                        "options.store_coefficients")
    body = body.replace("accelerated_simpls_block_size(", "candidate_block_size(")
    body = body.replace("max_ncomp, p, m, classification_response, n\n",
                        "max_ncomp, p, m, classification_response, n, options.maximum_block\n")
    body = body.replace("max_ncomp - a, p, m, classification_response, n\n",
                        "max_ncomp - a, p, m, classification_response, n, options.maximum_block\n")
    body = body.replace("variance(scaled_X)", "column_standard_deviation(scaled_X)")
    body = body.replace("RQ(Ytrain, Yfit_cur)", "fitted_r2(Ytrain, Yfit_cur)")
    body = replace_once(body,
        "  SimplsFastRefreshWorkspace refresh_ws;\n  fastpls_svd::IrlbaWorkspace irlba_ws;\n", "")
    solve_start = body.index("    if (randomized_solver) {")
    solve_end = body.index("    if (benchmark_phase_timing) {", solve_start)
    body = body[:solve_start] + """    if (!direction_solver(S, right_gram, use_right_gram_refresh, k_block,
                          static_cast<unsigned int>(seed + a), Ublock)) break;
""" + body[solve_end:]
    body = body.replace('stop("ncomp must contain at least one value");',
                        'throw std::invalid_argument("ncomp must contain at least one value");')
    # The engine keeps T-specific arrays/arithmetic; timing measurements remain double.
    body = typed(body)
    body = re.sub(r"Scalar (estimator_sec|direction_sec|component_update_sec|coefficient_sec|fitted_sec|elapsed)",
                  r"double \1", body)
    body = body.replace("std::chrono::duration<Scalar>", "std::chrono::duration<double>")
    body = body.replace("std::max(1.0, arma::abs(Yinput).max())",
                        "std::max(Scalar(1), arma::abs(Yinput).max())")
    if any(token in body for token in ("IRLBA", "Irlba", "Rcpp", "env_int_or", "svd_method", "refresh_ws")):
        raise ValueError("R/solver-specific implementation remained in the native engine")

    helpers = text[text.index("bool is_one_hot_response("):text.index("void dense_product_into(")]
    helpers = typed(helpers)
    for name in ("is_one_hot_response", "is_centered_one_hot_response", "extract_one_hot_labels",
                 "dummy_crossprod", "dummy_vector_crossprod", "symmetric_crossprod"):
        helpers = re.sub(r"(?m)^([^\n]+\b" + name + r"\()", r"template<typename Scalar>\n\1", helpers)
    # Expressions such as -mY need an explicit temporary for template deduction.
    body = body.replace("dummy_crossprod(Xtrain, one_hot_labels, -mY)",
                        "dummy_crossprod<Scalar>(Xtrain, one_hot_labels, -mY)")
    body = body.replace("dummy_vector_crossprod(\n", "dummy_vector_crossprod<Scalar>(\n")

    variance_start = text.index("arma::mat variance(const arma::mat& x) {")
    variance_end = text.index("// [[Rcpp::export]]", variance_start)
    variance = typed(text[variance_start:variance_end].strip().replace(
        "variance(", "column_standard_deviation("))
    rq_start = text.index("double RQ(arma::mat yData,arma::mat yPred){")
    rq_end = text.index("/* irlb C++ implementation", rq_start)
    rq = typed(text[rq_start:rq_end].strip().replace(
        "RQ(arma::mat yData,arma::mat yPred)",
        "fitted_r2(const arma::mat& yData,const arma::mat& yPred)"))
    rq = rq.replace("mean(yData.col(i))", "arma::mean(yData.col(i))")

    head = """// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Stefano Cacciatore
#ifndef FASTPLS_NATIVE_SIMPLS_HPP
#define FASTPLS_NATIVE_SIMPLS_HPP
#include <fastpls/native/direction.hpp>
#include <chrono>
#include <vector>

namespace fastpls { namespace native {

struct SimplsOptions {
  int scaling = 1;
  bool fitted = false;
  bool store_coefficients = false;
  bool store_scores = false;
  bool phase_timing = false;
  bool center_scores = false;
  bool reorthogonalize = false;
  bool cache_deflation = true;
  bool cache_crossprod = true;
  bool incremental_coefficients = true;
  bool randomized_directions = true;
  int crossprod_min_components = 20;
  int crossprod_max_predictors = 512;
  int crossprod_min_ratio = 8;
  int maximum_block = 8;
  RsvdControls svd;
};

struct SimplsTiming {
  double preprocess = 0, response_crosscov = 0, crossprod_cache = 0, right_gram = 0;
  double estimator = 0, direction = 0, component_update = 0;
  double coefficients = 0, fitted = 0, total = 0;
};

template<typename Scalar>
struct SimplsModel {
  arma::Mat<Scalar> R, Q, scores, x_mean, x_scale, y_mean;
  arma::Cube<Scalar> coefficients, fitted;
  arma::Col<Scalar> r2;
  arma::ivec components;
  int completed_components = 0;
  SimplsTiming timing;
};

inline int candidate_block_size(int remaining, int p, int q,
                                bool classification = false, int n = 0, int maximum = 8) {
  const double work = static_cast<double>(std::max(n, 0)) *
    static_cast<double>(std::max(p, 0)) * static_cast<double>(std::max(q, 0));
  if (!classification || q <= 1 || q > 2048 || remaining < 4 || work < 5.0e8) return 1;
  return std::max(1, std::min({maximum, remaining, p, q}));
}

"""
    signature = """
template<typename Scalar, typename DirectionSolver>
SimplsModel<Scalar> fit_simpls_with_solver(
    const arma::Mat<Scalar>& Xinput, const arma::Mat<Scalar>& Yinput,
    arma::ivec ncomp, const SimplsOptions& options,
    DirectionSolver&& direction_solver, arma::Mat<Scalar>* owned_X = nullptr) {
  using namespace arma;
  const int scaling = options.scaling;
  const bool fit = options.fitted;
  const unsigned int seed = options.svd.seed;
"""
    ending = """  SimplsModel<Scalar> result;
  result.R = std::move(RR);
  result.Q = std::move(QQ);
  result.scores = std::move(TT);
  result.x_mean = std::move(mX);
  result.x_scale = std::move(vX);
  result.y_mean = std::move(mY);
  result.coefficients = std::move(B);
  result.fitted = std::move(Yfit);
  result.r2 = std::move(R2Y);
  result.components = std::move(ncomp);
  result.completed_components = a;
  if (benchmark_phase_timing) {
    auto seconds = [](auto duration) { return std::chrono::duration<double>(duration).count(); };
    result.timing.preprocess = seconds(estimator_started - function_started);
    result.timing.response_crosscov = seconds(response_crosscov_done - function_started);
    result.timing.crossprod_cache = seconds(crossprod_cache_done - response_crosscov_done);
    result.timing.right_gram = seconds(right_gram_done - crossprod_cache_done);
    result.timing.estimator = estimator_sec;
    result.timing.direction = direction_sec;
    result.timing.component_update = component_update_sec;
    result.timing.coefficients = coefficient_sec;
    result.timing.fitted = fitted_sec;
    result.timing.total = seconds(BenchClock::now() - function_started);
  }
  return result;
}

template<typename Scalar>
SimplsModel<Scalar> fit_simpls(const arma::Mat<Scalar>& X, const arma::Mat<Scalar>& Y,
                              arma::ivec components, const SimplsOptions& options = {}) {
  DirectionWorkspace<Scalar> workspace;
  auto solve = [&](const arma::Mat<Scalar>& S, const arma::Mat<Scalar>& gram,
                   bool use_gram, int width, unsigned int seed, arma::Mat<Scalar>& U) {
    return use_gram ? workspace.refresh_from_right_gram(S, gram, width,
      options.svd.oversample, options.svd.power, seed, U) :
      workspace.refresh(S, width, options.svd.oversample, options.svd.power, seed, U);
  };
  return fit_simpls_with_solver(X, Y, std::move(components), options, solve);
}

template<typename Scalar>
arma::Mat<Scalar> predict_simpls(const SimplsModel<Scalar>& model,
                                arma::Mat<Scalar> X, int components) {
  if (components < 1 || components > model.completed_components ||
      X.n_cols != model.R.n_rows) {
    throw std::invalid_argument("predict_simpls: invalid dimensions or component count");
  }
  X.each_row() -= model.x_mean;
  X.each_row() /= model.x_scale;
  arma::Mat<Scalar> scores = X * model.R.cols(0, components - 1);
  arma::Mat<Scalar> result = scores * model.Q.cols(0, components - 1).t();
  result.each_row() += model.y_mean;
  return result;
}

} } // namespace fastpls::native
#endif
"""
    native = head + helpers + "template<typename Scalar>\n" + variance + "\n\n" + \
        "template<typename Scalar>\n" + rq + "\n" + signature + body + ending
    wrapper = (Path(__file__).with_name("simpls_adapter.cpp.in")).read_text()
    # Avoid hiding a second engine or backend fallback in the native extraction.
    if any(token in native for token in ("Rcpp", "IrlbaWorkspace", "fastpls_svd::", "env_int_or")):
        raise ValueError("Native source still depends on the R/IRLBA integration")
    patch = "*** Begin Patch\n" + added(root / "inst/include/fastpls/native/simpls.hpp", native)
    patch += "*** Update File: " + str(path) + "\n@@\n"
    patch += "\n".join("-" + line for line in old_function.rstrip().splitlines()) + "\n"
    patch += "\n".join("+" + line for line in wrapper.rstrip().splitlines()) + "\n"
    patch += "*** End Patch\n"
    print(patch, end="")


if __name__ == "__main__":
    main()
