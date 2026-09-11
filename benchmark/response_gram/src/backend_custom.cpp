#include "backend.hpp"

#include <algorithm>
#include <array>
#include <cstddef>
#include <string>
#include <thread>
#include <type_traits>
#include <vector>

#if defined(__x86_64__) || defined(_M_X64) || defined(__i386__) || defined(_M_IX86)
#define GRAM_X86 1
#include <immintrin.h>
#else
#define GRAM_X86 0
#endif

namespace gram_bench {
namespace {

constexpr std::size_t column_tile = 4;
int active_threads = 1;
std::string active_instruction_set = "portable";

template<class T>
void scalar_tile(const T* y, std::size_t n, std::size_t q,
                 std::size_t ldy, T* gram, std::size_t ldg,
                 std::size_t first_column) {
  const std::size_t columns = std::min(column_tile, n - first_column);
  for (std::size_t row = first_column; row < n; ++row) {
    std::array<T, column_tile> sums{};
    for (std::size_t response = 0; response < q; ++response) {
      const T* values = y + response * ldy;
      for (std::size_t local = 0; local < columns; ++local) {
        sums[local] += values[row] * values[first_column + local];
      }
    }
    for (std::size_t local = 0; local < columns; ++local) {
      const std::size_t column = first_column + local;
      if (row >= column) gram[row + column * ldg] = sums[local];
    }
  }
}

#if GRAM_X86 && (defined(__GNUC__) || defined(__clang__))
#define DEFINE_TILE_KERNEL(NAME, SCALAR, VECTOR, WIDTH, ZERO, LOAD, SET1, FMA, STORE, ATTR) \
  ATTR void NAME(const SCALAR* y, std::size_t n, std::size_t q, \
                 std::size_t ldy, SCALAR* gram, std::size_t ldg, \
                 std::size_t first_column) { \
    const std::size_t columns = std::min(column_tile, n - first_column); \
    std::size_t row = first_column; \
    for (; row + WIDTH <= n; row += WIDTH) { \
      VECTOR sums[column_tile] = {ZERO(), ZERO(), ZERO(), ZERO()}; \
      for (std::size_t response = 0; response < q; ++response) { \
        const SCALAR* values = y + response * ldy; \
        const VECTOR rows = LOAD(values + row); \
        for (std::size_t local = 0; local < columns; ++local) { \
          sums[local] = FMA(rows, SET1(values[first_column + local]), sums[local]); \
        } \
      } \
      alignas(64) SCALAR temporary[WIDTH]; \
      for (std::size_t local = 0; local < columns; ++local) { \
        STORE(temporary, sums[local]); \
        const std::size_t column = first_column + local; \
        for (std::size_t lane = 0; lane < WIDTH; ++lane) { \
          if (row + lane >= column) gram[row + lane + column * ldg] = temporary[lane]; \
        } \
      } \
    } \
    for (; row < n; ++row) { \
      SCALAR sums[column_tile] = {}; \
      for (std::size_t response = 0; response < q; ++response) { \
        const SCALAR* values = y + response * ldy; \
        for (std::size_t local = 0; local < columns; ++local) { \
          sums[local] += values[row] * values[first_column + local]; \
        } \
      } \
      for (std::size_t local = 0; local < columns; ++local) { \
        const std::size_t column = first_column + local; \
        if (row >= column) gram[row + column * ldg] = sums[local]; \
      } \
    } \
  }

DEFINE_TILE_KERNEL(
  avx2_tile_f32, float, __m256, 8, _mm256_setzero_ps, _mm256_loadu_ps,
  _mm256_set1_ps, _mm256_fmadd_ps, _mm256_store_ps,
  __attribute__((target("avx2,fma"))))
DEFINE_TILE_KERNEL(
  avx2_tile_f64, double, __m256d, 4, _mm256_setzero_pd, _mm256_loadu_pd,
  _mm256_set1_pd, _mm256_fmadd_pd, _mm256_store_pd,
  __attribute__((target("avx2,fma"))))
DEFINE_TILE_KERNEL(
  avx512_tile_f32, float, __m512, 16, _mm512_setzero_ps, _mm512_loadu_ps,
  _mm512_set1_ps, _mm512_fmadd_ps, _mm512_store_ps,
  __attribute__((target("avx512f,fma"))))
DEFINE_TILE_KERNEL(
  avx512_tile_f64, double, __m512d, 8, _mm512_setzero_pd, _mm512_loadu_pd,
  _mm512_set1_pd, _mm512_fmadd_pd, _mm512_store_pd,
  __attribute__((target("avx512f,fma"))))

#undef DEFINE_TILE_KERNEL
#endif

enum class InstructionSet { portable, avx2, avx512 };

InstructionSet instruction_set() {
#if GRAM_X86 && (defined(__GNUC__) || defined(__clang__))
  __builtin_cpu_init();
  if (__builtin_cpu_supports("avx512f") && __builtin_cpu_supports("fma")) {
    return InstructionSet::avx512;
  }
  if (__builtin_cpu_supports("avx2") && __builtin_cpu_supports("fma")) {
    return InstructionSet::avx2;
  }
#endif
  return InstructionSet::portable;
}

template<class T>
void run_custom(const T* y, std::size_t n, std::size_t q, std::size_t ldy,
                T* gram, std::size_t ldg) {
  const InstructionSet isa = instruction_set();
  active_instruction_set = isa == InstructionSet::avx512 ? "AVX-512/FMA" :
    (isa == InstructionSet::avx2 ? "AVX2/FMA" : "portable");
  const std::size_t tile_count = (n + column_tile - 1) / column_tile;
  const int threads = std::max(1, std::min(active_threads,
    static_cast<int>(tile_count)));
  auto worker = [&](int thread) {
    for (std::size_t tile = static_cast<std::size_t>(thread);
         tile < tile_count; tile += static_cast<std::size_t>(threads)) {
      const std::size_t first_column = tile * column_tile;
#if GRAM_X86 && (defined(__GNUC__) || defined(__clang__))
      if constexpr (std::is_same<T, float>::value) {
        if (isa == InstructionSet::avx512) {
          avx512_tile_f32(y, n, q, ldy, gram, ldg, first_column);
        } else if (isa == InstructionSet::avx2) {
          avx2_tile_f32(y, n, q, ldy, gram, ldg, first_column);
        } else {
          scalar_tile(y, n, q, ldy, gram, ldg, first_column);
        }
      } else {
        if (isa == InstructionSet::avx512) {
          avx512_tile_f64(y, n, q, ldy, gram, ldg, first_column);
        } else if (isa == InstructionSet::avx2) {
          avx2_tile_f64(y, n, q, ldy, gram, ldg, first_column);
        } else {
          scalar_tile(y, n, q, ldy, gram, ldg, first_column);
        }
      }
#else
      scalar_tile(y, n, q, ldy, gram, ldg, first_column);
#endif
    }
  };
  if (threads == 1) {
    worker(0);
    return;
  }
  std::vector<std::thread> workers;
  workers.reserve(static_cast<std::size_t>(threads));
  for (int thread = 0; thread < threads; ++thread) {
    workers.emplace_back(worker, thread);
  }
  for (auto& worker_thread : workers) worker_thread.join();
}

template<class T>
T scalar_dot(const T* left, const T* right, std::size_t size) {
  T sum = T(0);
  for (std::size_t index = 0; index < size; ++index) {
    sum += left[index] * right[index];
  }
  return sum;
}

#if GRAM_X86 && (defined(__GNUC__) || defined(__clang__))
__attribute__((target("avx2,fma")))
float avx2_dot_f32(const float* left, const float* right, std::size_t size) {
  __m256 sum = _mm256_setzero_ps();
  std::size_t index = 0;
  for (; index + 8 <= size; index += 8) {
    sum = _mm256_fmadd_ps(
      _mm256_loadu_ps(left + index), _mm256_loadu_ps(right + index), sum
    );
  }
  alignas(32) float lanes[8];
  _mm256_store_ps(lanes, sum);
  float result = 0.0f;
  for (float value : lanes) result += value;
  for (; index < size; ++index) result += left[index] * right[index];
  return result;
}

__attribute__((target("avx2,fma")))
double avx2_dot_f64(const double* left, const double* right, std::size_t size) {
  __m256d sum = _mm256_setzero_pd();
  std::size_t index = 0;
  for (; index + 4 <= size; index += 4) {
    sum = _mm256_fmadd_pd(
      _mm256_loadu_pd(left + index), _mm256_loadu_pd(right + index), sum
    );
  }
  alignas(32) double lanes[4];
  _mm256_store_pd(lanes, sum);
  double result = 0.0;
  for (double value : lanes) result += value;
  for (; index < size; ++index) result += left[index] * right[index];
  return result;
}

__attribute__((target("avx512f,fma")))
float avx512_dot_f32(const float* left, const float* right, std::size_t size) {
  __m512 sum = _mm512_setzero_ps();
  std::size_t index = 0;
  for (; index + 16 <= size; index += 16) {
    sum = _mm512_fmadd_ps(
      _mm512_loadu_ps(left + index), _mm512_loadu_ps(right + index), sum
    );
  }
  alignas(64) float lanes[16];
  _mm512_store_ps(lanes, sum);
  float result = 0.0f;
  for (float value : lanes) result += value;
  for (; index < size; ++index) result += left[index] * right[index];
  return result;
}

__attribute__((target("avx512f,fma")))
double avx512_dot_f64(const double* left, const double* right, std::size_t size) {
  __m512d sum = _mm512_setzero_pd();
  std::size_t index = 0;
  for (; index + 8 <= size; index += 8) {
    sum = _mm512_fmadd_pd(
      _mm512_loadu_pd(left + index), _mm512_loadu_pd(right + index), sum
    );
  }
  alignas(64) double lanes[8];
  _mm512_store_pd(lanes, sum);
  double result = 0.0;
  for (double value : lanes) result += value;
  for (; index < size; ++index) result += left[index] * right[index];
  return result;
}
#endif

template<class T>
void run_crossprod(const T* y, std::size_t n, std::size_t q,
                   std::size_t ldy, T* gram, std::size_t ldg) {
  const InstructionSet isa = instruction_set();
  active_instruction_set = isa == InstructionSet::avx512 ? "AVX-512/FMA" :
    (isa == InstructionSet::avx2 ? "AVX2/FMA" : "portable");
  const int threads = std::max(1, std::min(active_threads, static_cast<int>(q)));
  auto dot = [&](const T* left, const T* right) {
#if GRAM_X86 && (defined(__GNUC__) || defined(__clang__))
    if constexpr (std::is_same<T, float>::value) {
      if (isa == InstructionSet::avx512) return avx512_dot_f32(left, right, n);
      if (isa == InstructionSet::avx2) return avx2_dot_f32(left, right, n);
    } else {
      if (isa == InstructionSet::avx512) return avx512_dot_f64(left, right, n);
      if (isa == InstructionSet::avx2) return avx2_dot_f64(left, right, n);
    }
#endif
    return scalar_dot(left, right, n);
  };
  auto worker = [&](int thread) {
    for (std::size_t column = static_cast<std::size_t>(thread);
         column < q; column += static_cast<std::size_t>(threads)) {
      const T* left = y + column * ldy;
      for (std::size_t row = column; row < q; ++row) {
        gram[row + column * ldg] = dot(left, y + row * ldy);
      }
    }
  };
  if (threads == 1) {
    worker(0);
    return;
  }
  std::vector<std::thread> workers;
  workers.reserve(static_cast<std::size_t>(threads));
  for (int thread = 0; thread < threads; ++thread) {
    workers.emplace_back(worker, thread);
  }
  for (auto& worker_thread : workers) worker_thread.join();
}

}  // namespace

BackendInfo backend_info() {
  return {"custom_simd", "fastPLS experimental kernel", active_instruction_set,
          false, true};
}

void backend_set_threads(int threads) {
  active_threads = std::max(1, threads);
}

void backend_gram_f32(const float* y, std::size_t n, std::size_t q,
                      std::size_t ldy, float* gram, std::size_t ldg) {
  run_custom(y, n, q, ldy, gram, ldg);
}

void backend_gram_f64(const double* y, std::size_t n, std::size_t q,
                      std::size_t ldy, double* gram, std::size_t ldg) {
  run_custom(y, n, q, ldy, gram, ldg);
}

void backend_crossprod_f32(const float* y, std::size_t n, std::size_t q,
                           std::size_t ldy, float* gram, std::size_t ldg) {
  run_crossprod(y, n, q, ldy, gram, ldg);
}

void backend_crossprod_f64(const double* y, std::size_t n, std::size_t q,
                           std::size_t ldy, double* gram, std::size_t ldg) {
  run_crossprod(y, n, q, ldy, gram, ldg);
}

}  // namespace gram_bench
