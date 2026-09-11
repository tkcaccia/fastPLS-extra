#include "backend.hpp"

#include <libxsmm.h>
#include <libxsmm_version.h>

namespace gram_bench {

BackendInfo backend_info() {
  return {"libxsmm_gemm", LIBXSMM_CONFIG_VERSION, "JIT runtime dispatch", true, false};
}

void backend_set_threads(int) {
  libxsmm_init();
}

void backend_gram_f32(const float* y, std::size_t n, std::size_t q,
                      std::size_t ldy, float* gram, std::size_t ldg) {
  const char no_transpose = 'N';
  const char transpose = 'T';
  const libxsmm_blasint dimension = static_cast<libxsmm_blasint>(n);
  const libxsmm_blasint rank = static_cast<libxsmm_blasint>(q);
  const libxsmm_blasint input_ld = static_cast<libxsmm_blasint>(ldy);
  const libxsmm_blasint output_ld = static_cast<libxsmm_blasint>(ldg);
  const float alpha = 1.0f;
  const float beta = 0.0f;
  libxsmm_sgemm(&no_transpose, &transpose, &dimension, &dimension, &rank,
                &alpha, y, &input_ld, y, &input_ld, &beta, gram, &output_ld);
}

void backend_gram_f64(const double* y, std::size_t n, std::size_t q,
                      std::size_t ldy, double* gram, std::size_t ldg) {
  const char no_transpose = 'N';
  const char transpose = 'T';
  const libxsmm_blasint dimension = static_cast<libxsmm_blasint>(n);
  const libxsmm_blasint rank = static_cast<libxsmm_blasint>(q);
  const libxsmm_blasint input_ld = static_cast<libxsmm_blasint>(ldy);
  const libxsmm_blasint output_ld = static_cast<libxsmm_blasint>(ldg);
  const double alpha = 1.0;
  const double beta = 0.0;
  libxsmm_dgemm(&no_transpose, &transpose, &dimension, &dimension, &rank,
                &alpha, y, &input_ld, y, &input_ld, &beta, gram, &output_ld);
}

void backend_crossprod_f32(const float* y, std::size_t n, std::size_t q,
                           std::size_t ldy, float* gram, std::size_t ldg) {
  const char transpose = 'T';
  const char no_transpose = 'N';
  const libxsmm_blasint dimension = static_cast<libxsmm_blasint>(q);
  const libxsmm_blasint rank = static_cast<libxsmm_blasint>(n);
  const libxsmm_blasint input_ld = static_cast<libxsmm_blasint>(ldy);
  const libxsmm_blasint output_ld = static_cast<libxsmm_blasint>(ldg);
  const float alpha = 1.0f;
  const float beta = 0.0f;
  libxsmm_sgemm(&transpose, &no_transpose, &dimension, &dimension, &rank,
                &alpha, y, &input_ld, y, &input_ld, &beta, gram, &output_ld);
}

void backend_crossprod_f64(const double* y, std::size_t n, std::size_t q,
                           std::size_t ldy, double* gram, std::size_t ldg) {
  const char transpose = 'T';
  const char no_transpose = 'N';
  const libxsmm_blasint dimension = static_cast<libxsmm_blasint>(q);
  const libxsmm_blasint rank = static_cast<libxsmm_blasint>(n);
  const libxsmm_blasint input_ld = static_cast<libxsmm_blasint>(ldy);
  const libxsmm_blasint output_ld = static_cast<libxsmm_blasint>(ldg);
  const double alpha = 1.0;
  const double beta = 0.0;
  libxsmm_dgemm(&transpose, &no_transpose, &dimension, &dimension, &rank,
                &alpha, y, &input_ld, y, &input_ld, &beta, gram, &output_ld);
}

}  // namespace gram_bench
