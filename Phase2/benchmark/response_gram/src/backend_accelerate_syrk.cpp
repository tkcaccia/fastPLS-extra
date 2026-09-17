#include "backend.hpp"

#define ACCELERATE_NEW_LAPACK
#include <Accelerate/Accelerate.h>

namespace gram_bench {

BackendInfo backend_info() {
  return {"accelerate_syrk", "Apple Accelerate", "arm64-library-dispatch", false, true};
}

void backend_set_threads(int) {}

void backend_gram_f32(const float* y, std::size_t n, std::size_t q,
                      std::size_t ldy, float* gram, std::size_t ldg) {
  cblas_ssyrk(CblasColMajor, CblasLower, CblasNoTrans,
              static_cast<int>(n), static_cast<int>(q), 1.0f, y,
              static_cast<int>(ldy), 0.0f, gram, static_cast<int>(ldg));
}

void backend_gram_f64(const double* y, std::size_t n, std::size_t q,
                      std::size_t ldy, double* gram, std::size_t ldg) {
  cblas_dsyrk(CblasColMajor, CblasLower, CblasNoTrans,
              static_cast<int>(n), static_cast<int>(q), 1.0, y,
              static_cast<int>(ldy), 0.0, gram, static_cast<int>(ldg));
}

void backend_crossprod_f32(const float* y, std::size_t n, std::size_t q,
                           std::size_t ldy, float* gram, std::size_t ldg) {
  cblas_ssyrk(CblasColMajor, CblasLower, CblasTrans,
              static_cast<int>(q), static_cast<int>(n), 1.0f, y,
              static_cast<int>(ldy), 0.0f, gram, static_cast<int>(ldg));
}

void backend_crossprod_f64(const double* y, std::size_t n, std::size_t q,
                           std::size_t ldy, double* gram, std::size_t ldg) {
  cblas_dsyrk(CblasColMajor, CblasLower, CblasTrans,
              static_cast<int>(q), static_cast<int>(n), 1.0, y,
              static_cast<int>(ldy), 0.0, gram, static_cast<int>(ldg));
}

}  // namespace gram_bench
