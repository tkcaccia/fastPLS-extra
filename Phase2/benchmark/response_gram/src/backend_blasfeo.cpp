#include "backend.hpp"

#include <blasfeo_common.h>
#include <blasfeo_d_aux.h>
#include <blasfeo_d_aux_ext_dep.h>
#include <blasfeo_d_blasfeo_api.h>
#include <blasfeo_s_aux.h>
#include <blasfeo_s_aux_ext_dep.h>
#include <blasfeo_s_blasfeo_api.h>

namespace gram_bench {
namespace {

struct FloatWorkspace {
  blasfeo_smat input{};
  blasfeo_smat output{};
  int n = 0;
  int q = 0;
  int output_dimension = 0;

  ~FloatWorkspace() { release(); }

  void release() {
    if (n == 0) return;
    blasfeo_free_smat(&input);
    blasfeo_free_smat(&output);
    n = 0;
    q = 0;
    output_dimension = 0;
  }

  void prepare(int requested_n, int requested_q, int requested_output) {
    if (n == requested_n && q == requested_q &&
        output_dimension == requested_output) return;
    release();
    blasfeo_allocate_smat(requested_n, requested_q, &input);
    blasfeo_allocate_smat(requested_output, requested_output, &output);
    n = requested_n;
    q = requested_q;
    output_dimension = requested_output;
  }
};

struct DoubleWorkspace {
  blasfeo_dmat input{};
  blasfeo_dmat output{};
  int n = 0;
  int q = 0;
  int output_dimension = 0;

  ~DoubleWorkspace() { release(); }

  void release() {
    if (n == 0) return;
    blasfeo_free_dmat(&input);
    blasfeo_free_dmat(&output);
    n = 0;
    q = 0;
    output_dimension = 0;
  }

  void prepare(int requested_n, int requested_q, int requested_output) {
    if (n == requested_n && q == requested_q &&
        output_dimension == requested_output) return;
    release();
    blasfeo_allocate_dmat(requested_n, requested_q, &input);
    blasfeo_allocate_dmat(requested_output, requested_output, &output);
    n = requested_n;
    q = requested_q;
    output_dimension = requested_output;
  }
};

thread_local FloatWorkspace float_workspace;
thread_local DoubleWorkspace double_workspace;

}  // namespace

BackendInfo backend_info() {
  return {"blasfeo_syrk", "BLASFEO 0.1.4.3", "X64_INTEL_HASWELL", false, true};
}

void backend_set_threads(int) {}

void backend_gram_f32(const float* y, std::size_t n, std::size_t q,
                      std::size_t ldy, float* gram, std::size_t ldg) {
  float_workspace.prepare(
    static_cast<int>(n), static_cast<int>(q), static_cast<int>(n)
  );
  blasfeo_smat& input = float_workspace.input;
  blasfeo_smat& output = float_workspace.output;
  blasfeo_pack_smat(static_cast<int>(n), static_cast<int>(q),
                    const_cast<float*>(y), static_cast<int>(ldy), &input, 0, 0);
  blasfeo_ssyrk_ln(static_cast<int>(n), static_cast<int>(q), 1.0f,
                   &input, 0, 0, &input, 0, 0, 0.0f,
                   &output, 0, 0, &output, 0, 0);
  blasfeo_unpack_smat(static_cast<int>(n), static_cast<int>(n),
                      &output, 0, 0, gram, static_cast<int>(ldg));
}

void backend_gram_f64(const double* y, std::size_t n, std::size_t q,
                      std::size_t ldy, double* gram, std::size_t ldg) {
  double_workspace.prepare(
    static_cast<int>(n), static_cast<int>(q), static_cast<int>(n)
  );
  blasfeo_dmat& input = double_workspace.input;
  blasfeo_dmat& output = double_workspace.output;
  blasfeo_pack_dmat(static_cast<int>(n), static_cast<int>(q),
                    const_cast<double*>(y), static_cast<int>(ldy), &input, 0, 0);
  blasfeo_dsyrk_ln(static_cast<int>(n), static_cast<int>(q), 1.0,
                   &input, 0, 0, &input, 0, 0, 0.0,
                   &output, 0, 0, &output, 0, 0);
  blasfeo_unpack_dmat(static_cast<int>(n), static_cast<int>(n),
                      &output, 0, 0, gram, static_cast<int>(ldg));
}

void backend_crossprod_f32(const float* y, std::size_t n, std::size_t q,
                           std::size_t ldy, float* gram, std::size_t ldg) {
  float_workspace.prepare(
    static_cast<int>(n), static_cast<int>(q), static_cast<int>(q)
  );
  blasfeo_smat& input = float_workspace.input;
  blasfeo_smat& output = float_workspace.output;
  blasfeo_pack_smat(static_cast<int>(n), static_cast<int>(q),
                    const_cast<float*>(y), static_cast<int>(ldy), &input, 0, 0);
  blasfeo_ssyrk_lt(static_cast<int>(q), static_cast<int>(n), 1.0f,
                   &input, 0, 0, &input, 0, 0, 0.0f,
                   &output, 0, 0, &output, 0, 0);
  blasfeo_unpack_smat(static_cast<int>(q), static_cast<int>(q),
                      &output, 0, 0, gram, static_cast<int>(ldg));
}

void backend_crossprod_f64(const double* y, std::size_t n, std::size_t q,
                           std::size_t ldy, double* gram, std::size_t ldg) {
  double_workspace.prepare(
    static_cast<int>(n), static_cast<int>(q), static_cast<int>(q)
  );
  blasfeo_dmat& input = double_workspace.input;
  blasfeo_dmat& output = double_workspace.output;
  blasfeo_pack_dmat(static_cast<int>(n), static_cast<int>(q),
                    const_cast<double*>(y), static_cast<int>(ldy), &input, 0, 0);
  blasfeo_dsyrk_lt(static_cast<int>(q), static_cast<int>(n), 1.0,
                   &input, 0, 0, &input, 0, 0, 0.0,
                   &output, 0, 0, &output, 0, 0);
  blasfeo_unpack_dmat(static_cast<int>(q), static_cast<int>(q),
                      &output, 0, 0, gram, static_cast<int>(ldg));
}

}  // namespace gram_bench
