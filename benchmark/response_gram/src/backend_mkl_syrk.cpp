#include "backend.hpp"

#include <mkl.h>

namespace gram_bench {

BackendInfo backend_info() {
  char version[198] = {};
  MKL_Get_Version_String(version, static_cast<int>(sizeof(version)));
  return {"onemkl_syrk", version, "library-dispatch", false, true};
}

void backend_set_threads(int threads) {
  mkl_set_dynamic(0);
  mkl_set_num_threads_local(threads);
}

void backend_gram_f32(const float* y, std::size_t n, std::size_t q,
                      std::size_t ldy, float* gram, std::size_t ldg) {
  cblas_ssyrk(CblasColMajor, CblasLower, CblasNoTrans,
              static_cast<MKL_INT>(n), static_cast<MKL_INT>(q), 1.0f, y,
              static_cast<MKL_INT>(ldy), 0.0f, gram, static_cast<MKL_INT>(ldg));
}

void backend_gram_f64(const double* y, std::size_t n, std::size_t q,
                      std::size_t ldy, double* gram, std::size_t ldg) {
  cblas_dsyrk(CblasColMajor, CblasLower, CblasNoTrans,
              static_cast<MKL_INT>(n), static_cast<MKL_INT>(q), 1.0, y,
              static_cast<MKL_INT>(ldy), 0.0, gram, static_cast<MKL_INT>(ldg));
}

void backend_crossprod_f32(const float* y, std::size_t n, std::size_t q,
                           std::size_t ldy, float* gram, std::size_t ldg) {
  cblas_ssyrk(CblasColMajor, CblasLower, CblasTrans,
              static_cast<MKL_INT>(q), static_cast<MKL_INT>(n), 1.0f, y,
              static_cast<MKL_INT>(ldy), 0.0f, gram,
              static_cast<MKL_INT>(ldg));
}

void backend_crossprod_f64(const double* y, std::size_t n, std::size_t q,
                           std::size_t ldy, double* gram, std::size_t ldg) {
  cblas_dsyrk(CblasColMajor, CblasLower, CblasTrans,
              static_cast<MKL_INT>(q), static_cast<MKL_INT>(n), 1.0, y,
              static_cast<MKL_INT>(ldy), 0.0, gram,
              static_cast<MKL_INT>(ldg));
}

}  // namespace gram_bench
