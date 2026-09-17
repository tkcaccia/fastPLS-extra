// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Stefano Cacciatore
#include "candidates.hpp"
#include <iostream>
#include <type_traits>

template<class T>
void audit() {
  for (int condition = 0; condition < 4; ++condition) {
    arma::Mat<T> covariance(12, 12, arma::fill::eye), means(3, 12);
    for (arma::uword i = 0; i < means.n_elem; ++i) means(i) = T(i % 7) / T(7);
    if (condition == 1) covariance.ones();
    if (condition == 2) covariance.zeros();
    if (condition == 3) covariance(0, 0) = T(-1e-4);
    arma::Mat<T> manual, lapack;
    T manual_rho, lapack_rho, lambda;
    if constexpr (std::is_same<T, float>::value) {
      auto a = fastpls::native::lda_cholesky_solve_float(covariance, means);
      auto b = candidate_lapack32::lda_cholesky_solve(covariance, means);
      manual = a.linear; lapack = b.linear;
      manual_rho = a.relative_ridge; lapack_rho = b.relative_ridge; lambda = b.lambda;
    } else {
      auto a = candidate_manual64::lda_cholesky_solve_double(covariance, means);
      auto b = fastpls::native::lda_cholesky_solve(covariance, means);
      manual = a.linear; lapack = b.linear;
      manual_rho = a.relative_ridge; lapack_rho = b.relative_ridge; lambda = b.lambda;
    }
    covariance.diag() += lambda;
    arma::Mat<T> solution = lapack.t();
    const T error = arma::norm(covariance * solution - means.t(), "fro") /
      std::max(T(1), arma::norm(covariance, "fro") * arma::norm(solution, "fro"));
    const T difference = arma::norm(lapack - manual, "fro") /
      std::max(T(1), arma::norm(manual, "fro"));
    std::cout << (std::is_same<T,float>::value ? "float32" : "float64") << ','
      << condition << ',' << manual_rho << ',' << lapack_rho << ','
      << error << ',' << difference << '\n';
    if (!lapack.is_finite() || error > (std::is_same<T,float>::value ? T(2e-6) : T(1e-12)))
      throw std::runtime_error("LAPACK candidate failed residual test");
  }
}
int main() {
  std::cout << "precision,condition,workspace_rho,lapack_rho,residual,relative_weight_difference\n";
  audit<float>();
  audit<double>();
}
