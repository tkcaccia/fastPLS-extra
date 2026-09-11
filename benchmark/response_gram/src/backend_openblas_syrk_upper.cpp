#include "backend.hpp"

#include <cblas.h>
#include <openblas_config.h>

namespace gram_bench {

BackendInfo backend_info() {
  return {"openblas_syrk_upper", openblas_get_config(), "library-dispatch", true, true};
}

void backend_set_threads(int threads) {
  openblas_set_num_threads(threads);
}

template<class T>
void copy_upper_to_lower(T* gram, std::size_t n, std::size_t ldg) {
  for (std::size_t column = 0; column < n; ++column) {
    for (std::size_t row = column + 1; row < n; ++row) {
      gram[row + column * ldg] = gram[column + row * ldg];
    }
  }
}

void backend_gram_f32(const float* y, std::size_t n, std::size_t q,
                      std::size_t ldy, float* gram, std::size_t ldg) {
  cblas_ssyrk(CblasColMajor, CblasUpper, CblasNoTrans,
              static_cast<int>(n), static_cast<int>(q), 1.0f, y,
              static_cast<int>(ldy), 0.0f, gram, static_cast<int>(ldg));
  copy_upper_to_lower(gram, n, ldg);
}

void backend_gram_f64(const double* y, std::size_t n, std::size_t q,
                      std::size_t ldy, double* gram, std::size_t ldg) {
  cblas_dsyrk(CblasColMajor, CblasUpper, CblasNoTrans,
              static_cast<int>(n), static_cast<int>(q), 1.0, y,
              static_cast<int>(ldy), 0.0, gram, static_cast<int>(ldg));
  copy_upper_to_lower(gram, n, ldg);
}

void backend_crossprod_f32(const float* y, std::size_t n, std::size_t q,
                           std::size_t ldy, float* gram, std::size_t ldg) {
  cblas_ssyrk(CblasColMajor, CblasUpper, CblasTrans,
              static_cast<int>(q), static_cast<int>(n), 1.0f, y,
              static_cast<int>(ldy), 0.0f, gram, static_cast<int>(ldg));
  copy_upper_to_lower(gram, q, ldg);
}

void backend_crossprod_f64(const double* y, std::size_t n, std::size_t q,
                           std::size_t ldy, double* gram, std::size_t ldg) {
  cblas_dsyrk(CblasColMajor, CblasUpper, CblasTrans,
              static_cast<int>(q), static_cast<int>(n), 1.0, y,
              static_cast<int>(ldy), 0.0, gram, static_cast<int>(ldg));
  copy_upper_to_lower(gram, q, ldg);
}

}  // namespace gram_bench
