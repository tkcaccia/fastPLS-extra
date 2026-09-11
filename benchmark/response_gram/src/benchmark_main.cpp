#include "backend.hpp"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstdio>
#include <cstring>
#include <iomanip>
#include <iostream>
#include <limits>
#include <numeric>
#include <stdexcept>
#include <string>
#include <type_traits>
#include <vector>

#if defined(_WIN32)
#include <windows.h>
#include <psapi.h>
#elif defined(__APPLE__)
#include <mach/mach.h>
#include <sys/resource.h>
#else
#include <sys/resource.h>
#include <unistd.h>
#endif

namespace {

struct Options {
  std::size_t n = 100;
  std::size_t q = 1000;
  std::size_t pad_to = 1;
  int threads = 1;
  int repetitions = 7;
  int warmups = 2;
  double minimum_sample_seconds = 0.01;
  bool full = false;
  bool crossprod = false;
  bool use_float = true;
  std::uint64_t seed = 20260911ULL;
};

template<class T, std::size_t Alignment>
class AlignedAllocator {
 public:
  using value_type = T;
  AlignedAllocator() noexcept = default;
  template<class U> AlignedAllocator(const AlignedAllocator<U, Alignment>&) noexcept {}
  T* allocate(std::size_t count) {
    if (count > std::numeric_limits<std::size_t>::max() / sizeof(T)) {
      throw std::bad_alloc();
    }
#if defined(_WIN32)
    void* pointer = _aligned_malloc(count * sizeof(T), Alignment);
    if (pointer == nullptr) throw std::bad_alloc();
    return static_cast<T*>(pointer);
#else
    void* pointer = nullptr;
    if (posix_memalign(&pointer, Alignment, count * sizeof(T)) != 0) {
      throw std::bad_alloc();
    }
    return static_cast<T*>(pointer);
#endif
  }
  void deallocate(T* pointer, std::size_t) noexcept {
#if defined(_WIN32)
    _aligned_free(pointer);
#else
    std::free(pointer);
#endif
  }
  template<class U> struct rebind { using other = AlignedAllocator<U, Alignment>; };
};

template<class T, class U, std::size_t A>
bool operator==(const AlignedAllocator<T, A>&, const AlignedAllocator<U, A>&) {
  return true;
}
template<class T, class U, std::size_t A>
bool operator!=(const AlignedAllocator<T, A>&, const AlignedAllocator<U, A>&) {
  return false;
}

std::uint64_t splitmix64(std::uint64_t& state) {
  std::uint64_t z = (state += 0x9e3779b97f4a7c15ULL);
  z = (z ^ (z >> 30U)) * 0xbf58476d1ce4e5b9ULL;
  z = (z ^ (z >> 27U)) * 0x94d049bb133111ebULL;
  return z ^ (z >> 31U);
}

template<class T>
void fill_input(T* values, std::size_t rows, std::size_t columns,
                std::size_t leading_dimension, std::uint64_t seed) {
  constexpr long double denominator = 9007199254740992.0L;
  std::fill_n(values, leading_dimension * columns, T(0));
  for (std::size_t column = 0; column < columns; ++column) {
    for (std::size_t row = 0; row < rows; ++row) {
      const std::uint64_t bits = splitmix64(seed) >> 11U;
      const long double unit = static_cast<long double>(bits) / denominator;
      values[row + column * leading_dimension] =
        static_cast<T>(2.0L * unit - 1.0L);
    }
  }
}

std::size_t current_rss_bytes() {
#if defined(_WIN32)
  PROCESS_MEMORY_COUNTERS counters{};
  if (GetProcessMemoryInfo(GetCurrentProcess(), &counters, sizeof(counters))) {
    return static_cast<std::size_t>(counters.WorkingSetSize);
  }
  return 0;
#elif defined(__APPLE__)
  mach_task_basic_info information{};
  mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
  if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO,
                reinterpret_cast<task_info_t>(&information), &count) == KERN_SUCCESS) {
    return static_cast<std::size_t>(information.resident_size);
  }
  return 0;
#else
  long resident_pages = 0;
  FILE* input = std::fopen("/proc/self/statm", "r");
  if (input != nullptr) {
    long total_pages = 0;
    if (std::fscanf(input, "%ld %ld", &total_pages, &resident_pages) != 2) {
      resident_pages = 0;
    }
    std::fclose(input);
  }
  return static_cast<std::size_t>(resident_pages) *
    static_cast<std::size_t>(sysconf(_SC_PAGESIZE));
#endif
}

std::size_t peak_rss_bytes() {
#if defined(_WIN32)
  PROCESS_MEMORY_COUNTERS counters{};
  if (GetProcessMemoryInfo(GetCurrentProcess(), &counters, sizeof(counters))) {
    return static_cast<std::size_t>(counters.PeakWorkingSetSize);
  }
  return 0;
#else
  rusage usage{};
  if (getrusage(RUSAGE_SELF, &usage) != 0) return 0;
#if defined(__APPLE__)
  return static_cast<std::size_t>(usage.ru_maxrss);
#else
  return static_cast<std::size_t>(usage.ru_maxrss) * 1024ULL;
#endif
#endif
}

Options parse_options(int argc, char** argv) {
  Options options;
  for (int index = 1; index < argc; ++index) {
    const std::string argument(argv[index]);
    const auto value = [&](const char* name) -> const char* {
      if (index + 1 >= argc) throw std::invalid_argument(std::string("missing value for ") + name);
      return argv[++index];
    };
    if (argument == "--n") options.n = std::stoull(value("--n"));
    else if (argument == "--q") options.q = std::stoull(value("--q"));
    else if (argument == "--pad-to") {
      options.pad_to = std::stoull(value("--pad-to"));
    }
    else if (argument == "--threads") options.threads = std::stoi(value("--threads"));
    else if (argument == "--repetitions") options.repetitions = std::stoi(value("--repetitions"));
    else if (argument == "--warmups") options.warmups = std::stoi(value("--warmups"));
    else if (argument == "--minimum-sample-seconds") {
      options.minimum_sample_seconds = std::stod(value("--minimum-sample-seconds"));
    }
    else if (argument == "--precision") {
      const std::string precision(value("--precision"));
      if (precision == "float32") options.use_float = true;
      else if (precision == "float64") options.use_float = false;
      else throw std::invalid_argument("precision must be float32 or float64");
    } else if (argument == "--output") {
      const std::string output(value("--output"));
      if (output == "full") options.full = true;
      else if (output == "triangle") options.full = false;
      else throw std::invalid_argument("output must be triangle or full");
    } else if (argument == "--operation") {
      const std::string operation(value("--operation"));
      if (operation == "sample_gram") options.crossprod = false;
      else if (operation == "crossprod") options.crossprod = true;
      else throw std::invalid_argument(
        "operation must be sample_gram or crossprod"
      );
    } else if (argument == "--seed") options.seed = std::stoull(value("--seed"));
    else throw std::invalid_argument("unknown argument: " + argument);
  }
  if (options.n == 0 || options.q == 0 || options.pad_to == 0 ||
      options.threads < 1 ||
      options.repetitions < 1 || options.warmups < 0 ||
      options.minimum_sample_seconds < 0.0) {
    throw std::invalid_argument("matrix dimensions, threads and repetitions must be positive");
  }
  return options;
}

template<class T>
void mirror_lower(T* gram, std::size_t n) {
  constexpr std::size_t block_size = 32;
  for (std::size_t column_block = 0; column_block < n;
       column_block += block_size) {
    const std::size_t column_end = std::min(n, column_block + block_size);
    for (std::size_t row_block = column_block; row_block < n;
         row_block += block_size) {
      const std::size_t row_end = std::min(n, row_block + block_size);
      for (std::size_t column = column_block; column < column_end; ++column) {
        const std::size_t first_row = std::max(row_block, column + 1);
        for (std::size_t row = first_row; row < row_end; ++row) {
          gram[column + row * n] = gram[row + column * n];
        }
      }
    }
  }
}

template<class T>
long double exact_entry(const T* y, std::size_t n, std::size_t q,
                        std::size_t row, std::size_t column,
                        std::size_t leading_dimension, bool crossprod) {
  long double sum = 0.0L;
  long double correction = 0.0L;
  const std::size_t rank = crossprod ? n : q;
  for (std::size_t index = 0; index < rank; ++index) {
    const std::size_t left_index = crossprod ?
      index + row * leading_dimension : row + index * leading_dimension;
    const std::size_t right_index = crossprod ?
      index + column * leading_dimension : column + index * leading_dimension;
    const long double product = static_cast<long double>(y[left_index]) *
      static_cast<long double>(y[right_index]);
    const long double adjusted = product - correction;
    const long double next = sum + adjusted;
    correction = (next - sum) - adjusted;
    sum = next;
  }
  return sum;
}

template<class T>
int run(const Options& options) {
  using Vector = std::vector<T, AlignedAllocator<T, 64>>;
  const std::size_t dimension = options.crossprod ? options.q : options.n;
  const std::size_t rank = options.crossprod ? options.n : options.q;
  if (options.n > std::numeric_limits<std::size_t>::max() -
      (options.pad_to - 1)) {
    throw std::overflow_error("padded leading dimension overflows size_t");
  }
  const std::size_t leading_dimension =
    ((options.n + options.pad_to - 1) / options.pad_to) * options.pad_to;
  if (leading_dimension >
      std::numeric_limits<std::size_t>::max() / options.q) {
    throw std::overflow_error("input dimensions overflow size_t");
  }
  const std::size_t input_elements = leading_dimension * options.q;
  if (input_elements > std::numeric_limits<std::size_t>::max() / sizeof(T)) {
    throw std::overflow_error("input allocation size overflows size_t");
  }
  if (dimension > std::numeric_limits<std::size_t>::max() / dimension) {
    throw std::overflow_error("Gram output dimensions overflow size_t");
  }
  const std::size_t output_elements = dimension * dimension;
  if (output_elements > std::numeric_limits<std::size_t>::max() / sizeof(T)) {
    throw std::overflow_error("Gram output allocation size overflows size_t");
  }
  const std::size_t baseline_rss = current_rss_bytes();
  Vector y(input_elements);
  Vector gram(output_elements, T(0));
  fill_input(
    y.data(), options.n, options.q, leading_dimension, options.seed
  );
  const std::size_t allocated_rss = current_rss_bytes();

  gram_bench::backend_set_threads(options.threads);
  const auto compute = [&]() {
    std::fill(gram.begin(), gram.end(), T(0));
    if constexpr (std::is_same<T, float>::value) {
      if (options.crossprod) {
        gram_bench::backend_crossprod_f32(
          y.data(), options.n, options.q, leading_dimension,
          gram.data(), dimension);
      } else {
        gram_bench::backend_gram_f32(
          y.data(), options.n, options.q, leading_dimension,
          gram.data(), dimension);
      }
    } else {
      if (options.crossprod) {
        gram_bench::backend_crossprod_f64(
          y.data(), options.n, options.q, leading_dimension,
          gram.data(), dimension);
      } else {
        gram_bench::backend_gram_f64(
          y.data(), options.n, options.q, leading_dimension,
          gram.data(), dimension);
      }
    }
  };
  for (int warmup = 0; warmup < options.warmups; ++warmup) compute();

  const auto calibration_start = std::chrono::steady_clock::now();
  compute();
  if (options.full && !gram_bench::backend_info().computes_full_matrix) {
    mirror_lower(gram.data(), dimension);
  }
  const auto calibration_finish = std::chrono::steady_clock::now();
  const double calibration_seconds = std::max(
    std::chrono::duration<double>(calibration_finish - calibration_start).count(),
    1.0e-9);
  const std::size_t batch_iterations = std::max<std::size_t>(
    1, std::min<std::size_t>(
      1000000, static_cast<std::size_t>(std::ceil(
        options.minimum_sample_seconds / calibration_seconds))));

  std::vector<double> elapsed;
  std::vector<double> mirror_elapsed;
  elapsed.reserve(options.repetitions);
  mirror_elapsed.reserve(options.repetitions);
  for (int repetition = 0; repetition < options.repetitions; ++repetition) {
    const auto start = std::chrono::steady_clock::now();
    for (std::size_t iteration = 0; iteration < batch_iterations; ++iteration) {
      compute();
    }
    const auto finish = std::chrono::steady_clock::now();
    elapsed.push_back(
      std::chrono::duration<double>(finish - start).count() /
      static_cast<double>(batch_iterations));
    if (options.full && !gram_bench::backend_info().computes_full_matrix) {
      const auto mirror_start = std::chrono::steady_clock::now();
      for (std::size_t iteration = 0; iteration < batch_iterations; ++iteration) {
        mirror_lower(gram.data(), dimension);
      }
      const auto mirror_finish = std::chrono::steady_clock::now();
      mirror_elapsed.push_back(
        std::chrono::duration<double>(mirror_finish - mirror_start).count() /
        static_cast<double>(batch_iterations));
    } else {
      mirror_elapsed.push_back(0.0);
    }
  }

  const auto quantile = [](std::vector<double> values, double probability) {
    std::sort(values.begin(), values.end());
    const double position = probability * static_cast<double>(values.size() - 1);
    const std::size_t lower = static_cast<std::size_t>(position);
    const std::size_t upper = std::min(lower + 1, values.size() - 1);
    const double weight = position - static_cast<double>(lower);
    return values[lower] * (1.0 - weight) + values[upper] * weight;
  };
  std::vector<double> total_elapsed(elapsed.size());
  std::transform(elapsed.begin(), elapsed.end(), mirror_elapsed.begin(),
                 total_elapsed.begin(), std::plus<double>());
  const double seconds = quantile(elapsed, 0.5);
  const double q1_seconds = quantile(elapsed, 0.25);
  const double q3_seconds = quantile(elapsed, 0.75);
  const double minimum_seconds = *std::min_element(elapsed.begin(), elapsed.end());
  const double maximum_seconds = *std::max_element(elapsed.begin(), elapsed.end());
  const double mirror_seconds = quantile(mirror_elapsed, 0.5);
  const double total_seconds = quantile(total_elapsed, 0.5);

  long double maximum_absolute_error = 0.0L;
  long double maximum_relative_error = 0.0L;
  long double sampled_squared_error = 0.0L;
  long double sampled_squared_reference = 0.0L;
  long double checksum = 0.0L;
  const std::size_t sample_count = std::min<std::size_t>(
    64, dimension * (dimension + 1) / 2
  );
  std::uint64_t state = options.seed ^ 0xd1b54a32d192ed03ULL;
  for (std::size_t sample = 0; sample < sample_count; ++sample) {
    std::size_t row = splitmix64(state) % dimension;
    std::size_t column = splitmix64(state) % dimension;
    if (row < column) std::swap(row, column);
    const long double observed = gram[row + column * dimension];
    const long double expected = exact_entry(
      y.data(), options.n, options.q, row, column, leading_dimension,
      options.crossprod
    );
    const long double absolute_error = std::fabs(observed - expected);
    const long double relative_error = absolute_error /
      std::max(std::fabs(expected), 1.0e-18L);
    maximum_absolute_error = std::max(maximum_absolute_error, absolute_error);
    maximum_relative_error = std::max(maximum_relative_error, relative_error);
    sampled_squared_error += absolute_error * absolute_error;
    sampled_squared_reference += expected * expected;
    checksum += observed * static_cast<long double>(sample + 1);
  }
  const long double sampled_relative_l2_error = std::sqrt(sampled_squared_error) /
    std::max(std::sqrt(sampled_squared_reference), 1.0e-18L);
  long double maximum_symmetry_error = 0.0L;
  if (options.full) {
    for (std::size_t column = 0; column < dimension; ++column) {
      for (std::size_t row = column + 1; row < dimension; ++row) {
        maximum_symmetry_error = std::max(
          maximum_symmetry_error,
          std::fabs(static_cast<long double>(gram[row + column * dimension]) -
                    static_cast<long double>(gram[column + row * dimension])));
      }
    }
  }

  const gram_bench::BackendInfo info = gram_bench::backend_info();
  const long double useful_flops = static_cast<long double>(dimension) *
    static_cast<long double>(dimension + 1) * static_cast<long double>(rank);
  const long double executed_flops = info.native_symmetric_kernel ? useful_flops :
    2.0L * dimension * dimension * rank;
  const std::size_t final_rss = current_rss_bytes();
  const std::size_t peak_rss = std::max(
    {peak_rss_bytes(), baseline_rss, allocated_rss, final_rss});
  const std::size_t incremental_peak_rss = peak_rss > baseline_rss ?
    peak_rss - baseline_rss : 0;

  std::cout << std::setprecision(12)
    << "backend,operation,n,q,leading_dimension,pad_to,precision,threads,output,repetitions,warmups,batch_iterations,median_seconds,"
       "q1_seconds,q3_seconds,min_seconds,max_seconds,mirror_seconds,total_seconds,"
       "useful_gflops,executed_gflops,total_useful_gflops,baseline_rss_bytes,"
       "allocated_rss_bytes,final_rss_bytes,peak_rss_bytes,incremental_peak_rss_bytes,"
       "max_abs_error,max_rel_error,sampled_rel_l2_error,max_symmetry_error,"
       "checksum,library_version,"
       "instruction_set,native_symmetric\n"
    << info.name << ',' << (options.crossprod ? "crossprod" : "sample_gram")
    << ',' << options.n << ',' << options.q << ',' << leading_dimension << ','
    << options.pad_to << ','
    << (options.use_float ? "float32" : "float64") << ',' << options.threads << ','
    << (options.full ? "full" : "triangle") << ',' << options.repetitions << ','
    << options.warmups << ',' << batch_iterations << ',' << seconds << ','
    << q1_seconds << ',' << q3_seconds << ','
    << minimum_seconds << ',' << maximum_seconds << ',' << mirror_seconds << ','
    << total_seconds << ','
    << static_cast<double>(useful_flops / seconds / 1.0e9L) << ','
    << static_cast<double>(executed_flops / seconds / 1.0e9L) << ','
    << static_cast<double>(useful_flops / total_seconds / 1.0e9L) << ','
    << baseline_rss << ',' << allocated_rss << ',' << final_rss << ',' << peak_rss << ','
    << incremental_peak_rss << ','
    << static_cast<double>(maximum_absolute_error) << ','
    << static_cast<double>(maximum_relative_error) << ','
    << static_cast<double>(sampled_relative_l2_error) << ','
    << static_cast<double>(maximum_symmetry_error) << ','
    << static_cast<double>(checksum) << ',' << info.library_version << ','
    << info.instruction_set << ',' << (info.native_symmetric_kernel ? "true" : "false")
    << '\n';
  return 0;
}

}  // namespace

int main(int argc, char** argv) {
  try {
    const Options options = parse_options(argc, argv);
    return options.use_float ? run<float>(options) : run<double>(options);
  } catch (const std::exception& error) {
    std::cerr << "response-Gram benchmark failed: " << error.what() << '\n';
    return 2;
  }
}
