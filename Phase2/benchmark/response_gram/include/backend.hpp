#ifndef FASTPLS_RESPONSE_GRAM_BACKEND_HPP
#define FASTPLS_RESPONSE_GRAM_BACKEND_HPP

#include <cstddef>
#include <string>

namespace gram_bench {

struct BackendInfo {
  std::string name;
  std::string library_version;
  std::string instruction_set;
  bool computes_full_matrix = false;
  bool native_symmetric_kernel = true;
};

BackendInfo backend_info();
void backend_set_threads(int threads);

void backend_gram_f32(const float* y, std::size_t n, std::size_t q,
                      std::size_t ldy, float* gram, std::size_t ldg);
void backend_gram_f64(const double* y, std::size_t n, std::size_t q,
                      std::size_t ldy, double* gram, std::size_t ldg);

void backend_crossprod_f32(const float* y, std::size_t n, std::size_t q,
                           std::size_t ldy, float* gram, std::size_t ldg);
void backend_crossprod_f64(const double* y, std::size_t n, std::size_t q,
                           std::size_t ldy, double* gram, std::size_t ldg);

}  // namespace gram_bench

#endif
