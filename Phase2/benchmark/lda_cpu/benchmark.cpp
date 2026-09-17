// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Stefano Cacciatore
#include "candidates.hpp"
#include <chrono>
#include <iostream>
#include <iomanip>
#include <random>
#include <type_traits>

extern "C" int openblas_get_num_threads();
extern "C" const char* openblas_get_config();
using Clock = std::chrono::steady_clock;
double elapsed(Clock::time_point start) {
  return std::chrono::duration<double>(Clock::now() - start).count();
}

template<class T>
struct Result { arma::Mat<T> linear; T lambda, rho; };

template<class T>
Result<T> solve(const arma::Mat<T>& cov, const arma::Mat<T>& means, bool lapack) {
  if constexpr (std::is_same<T, float>::value) {
    if (lapack) {
      auto s = candidate_lapack32::lda_cholesky_solve(cov, means);
      return {std::move(s.linear), s.lambda, s.relative_ridge};
    }
    auto s = fastpls::native::lda_cholesky_solve_float(cov, means);
    return {std::move(s.linear), s.lambda, s.relative_ridge};
  } else {
    if (lapack) {
      auto s = fastpls::native::lda_cholesky_solve(cov, means);
      return {std::move(s.linear), s.lambda, s.relative_ridge};
    }
    auto s = candidate_manual64::lda_cholesky_solve_double(cov, means);
    return {std::move(s.linear), s.lambda, s.relative_ridge};
  }
}

template<class T>
void run(int n, int width, int classes, int repeats) {
  std::mt19937 rng(971);
  std::normal_distribution<double> normal(0.0, 1.0);
  arma::Mat<T> train(n, width), test(400, width);
  for (auto& value : train) value = static_cast<T>(normal(rng));
  for (auto& value : test) value = static_cast<T>(normal(rng));
  for (int i = 0; i < n; ++i) train(i, (i % classes) % width) += T(3);
  for (int i = 0; i < 400; ++i) test(i, (i % classes) % width) += T(3);
  arma::Mat<T> reference;
  arma::uvec reference_labels;
  // Baseline and candidate receive identical already typed scores and fixed labels.
  for (int rep = -1; rep < repeats; ++rep) {
    for (int pass = 0; pass < 2; ++pass) {
      const bool lapack = ((pass + std::max(0, rep)) % 2) != 0;
      const auto begin = Clock::now();
      arma::Col<T> counts(classes, arma::fill::zeros);
      arma::Mat<T> means(classes, width, arma::fill::zeros);
      for (int i = 0; i < n; ++i) {
        ++counts(i % classes);
        means.row(i % classes) += train.row(i);
      }
      for (int c = 0; c < classes; ++c) means.row(c) /= counts(c);
      arma::Mat<T> cov = arma::symmatu(train.t() * train);
      for (int c = 0; c < classes; ++c)
        cov -= counts(c) * (means.row(c).t() * means.row(c));
      cov /= T(std::max(1, n - classes));
      const double moments_time = elapsed(begin);
      const auto solve_start = Clock::now();
      auto model = solve(cov, means, lapack);
      const double solve_time = elapsed(solve_start);
      const auto pred_start = Clock::now();
      arma::Mat<T> scores = test * model.linear.t();
      for (int c = 0; c < classes; ++c)
        scores.col(c) += -T(0.5) * arma::dot(means.row(c), model.linear.row(c)) +
          std::log(counts(c) / T(n));
      arma::uvec labels = arma::index_max(scores, 1);
      const double predict_time = elapsed(pred_start);
      const double total = elapsed(begin);
      if (rep == -1 && !lapack) { reference = scores; reference_labels = labels; }
      if (reference.is_empty()) throw std::runtime_error("Missing benchmark baseline");
      int correct = 0, agreement = 0;
      for (int i = 0; i < 400; ++i) {
        correct += labels(i) == arma::uword(i % classes);
        agreement += labels(i) == reference_labels(i);
      }
      if (rep < 0) continue;
      const double error = arma::norm(scores - reference, "fro") /
        std::max(T(1), arma::norm(reference, "fro"));
      std::cout << (std::is_same<T, float>::value ? "float32" : "float64") << ','
        << n << ',' << width << ',' << classes << ',' << openblas_get_num_threads()
        << ',' << (lapack ? "lapack" : "workspace") << ',' << rep << ','
        << moments_time << ',' << solve_time << ',' << predict_time << ',' << total
        << ',' << correct / 400.0 << ',' << agreement / 400.0 << ',' << error
        << ',' << model.rho << '\n';
    }
  }
}

int main() {
  std::cerr << openblas_get_config() << "; threads=" << openblas_get_num_threads() << '\n';
  std::cout << std::setprecision(12)
    << "precision,n,scores,classes,threads,solver,rep,moments_s,solve_s,predict_s,total_s,accuracy,agreement,relative_score_error,rho\n";
  for (int n : {1000, 5000}) for (int width : {10, 50, 200, 500}) {
    run<float>(n, width, 10, 15);
    run<double>(n, width, 10, 15);
  }
}
