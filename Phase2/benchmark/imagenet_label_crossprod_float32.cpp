#include <Rcpp.h>
#include <cstdint>
#include <cstring>
#include <vector>

#ifdef _OPENMP
#include <omp.h>
#endif

// [[Rcpp::plugins(cpp17)]]
// [[Rcpp::plugins(openmp)]]

inline float int_bits_to_float(const int value) {
  const std::uint32_t bits = static_cast<std::uint32_t>(value);
  float result;
  std::memcpy(&result, &bits, sizeof(float));
  return result;
}

inline int float_to_int_bits(const float value) {
  std::uint32_t bits;
  std::memcpy(&bits, &value, sizeof(float));
  return static_cast<int>(bits);
}

// [[Rcpp::export]]
Rcpp::NumericVector imagenet_float32_column_means(const Rcpp::S4& x) {
  if (!x.is("float32")) {
    Rcpp::stop("x must inherit from float32");
  }
  const Rcpp::IntegerMatrix data = x.slot("Data");
  const int n = data.nrow();
  const int p = data.ncol();
  Rcpp::NumericVector center(p);
#ifdef _OPENMP
#pragma omp parallel for schedule(static)
#endif
  for (int j = 0; j < p; ++j) {
    float total = 0.0f;
    for (int i = 0; i < n; ++i) {
      total += int_bits_to_float(data(i, j));
    }
    center[j] = static_cast<double>(total / static_cast<float>(n));
  }
  return center;
}

// Mutates only the benchmark-local object loaded from RDS; the source file is
// never modified.
// [[Rcpp::export]]
void imagenet_center_float32_in_place(
    Rcpp::S4 x,
    const Rcpp::NumericVector& center) {
  if (!x.is("float32")) {
    Rcpp::stop("x must inherit from float32");
  }
  Rcpp::IntegerMatrix data = x.slot("Data");
  const int n = data.nrow();
  const int p = data.ncol();
  if (center.size() != p) {
    Rcpp::stop("center length does not match x");
  }
#ifdef _OPENMP
#pragma omp parallel for schedule(static)
#endif
  for (int j = 0; j < p; ++j) {
    const float offset = static_cast<float>(center[j]);
    for (int i = 0; i < n; ++i) {
      data(i, j) = float_to_int_bits(int_bits_to_float(data(i, j)) - offset);
    }
  }
}

// Computes X'Y for centred X and one-hot class labels without constructing Y.
// X is the integer-bit storage used by the float package's float32 class.
// [[Rcpp::export]]
Rcpp::List imagenet_label_crossprod_float32(
    const Rcpp::S4& x,
    const Rcpp::IntegerVector& labels,
    const int n_classes) {
  if (!x.is("float32")) {
    Rcpp::stop("x must inherit from float32");
  }
  const Rcpp::IntegerMatrix data = x.slot("Data");
  const int n = data.nrow();
  const int p = data.ncol();
  if (labels.size() != n || n_classes < 2) {
    Rcpp::stop("labels and class count do not match x");
  }

  std::vector<int> counts(static_cast<std::size_t>(n_classes), 0);
  for (int i = 0; i < n; ++i) {
    const int code = labels[i] - 1;
    if (code < 0 || code >= n_classes) {
      Rcpp::stop("labels must be compact one-based class codes");
    }
    ++counts[static_cast<std::size_t>(code)];
  }

  Rcpp::NumericMatrix crosscov(p, n_classes);
  Rcpp::NumericVector center(p);

#ifdef _OPENMP
#pragma omp parallel for schedule(static)
#endif
  for (int j = 0; j < p; ++j) {
    std::vector<float> class_sums(static_cast<std::size_t>(n_classes), 0.0f);
    float total = 0.0f;
    for (int i = 0; i < n; ++i) {
      const float value = int_bits_to_float(data(i, j));
      total += value;
      class_sums[static_cast<std::size_t>(labels[i] - 1)] += value;
    }
    const float mean = total / static_cast<float>(n);
    center[j] = static_cast<double>(mean);
    for (int class_index = 0; class_index < n_classes; ++class_index) {
      const float value =
          class_sums[static_cast<std::size_t>(class_index)] -
          static_cast<float>(counts[static_cast<std::size_t>(class_index)]) * mean;
      crosscov(j, class_index) = static_cast<double>(value);
    }
  }

  return Rcpp::List::create(
      Rcpp::Named("crosscov") = crosscov,
      Rcpp::Named("center") = center,
      Rcpp::Named("counts") = Rcpp::wrap(counts));
}
