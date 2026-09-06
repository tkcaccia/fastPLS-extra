#ifndef FASTPLS_IRLBA_WORKSPACE_H
#define FASTPLS_IRLBA_WORKSPACE_H

#include <RcppArmadillo.h>

extern "C" {
#include "irlba.h"
}

namespace fastpls_svd {

// Owned by a fit, not a global cache: reuse allocations across fresh solves
// without retaining either a starting direction or a fitted Lanczos basis.
struct IrlbaWorkspace {
  arma::vec s, F, BS, BW, residual, T, svratio;
  arma::mat U, V, V1, U1, W, B, BU, BV;
  int iterations = 0;
  int products = 0;
  int status = 0;

  void solve(double* matrix, fastpls_irlba_operator* op,
             int rows, int columns, int rank, int work, int maxit,
             double tol, double eps, double svtol) {
    const int lwork = 7 * work * (1 + work);
    // Preserve the original random draws and their order, even for buffers
    // whose initial contents the solver subsequently overwrites.
    s.randn(rank);
    U.randn(rows, work);
    V.randn(columns, work);
    V1.zeros(columns, work);
    U1.zeros(rows, work);
    W.zeros(rows, work);
    F.zeros(columns);
    B.zeros(work, work);
    BU.zeros(work, work);
    BV.set_size(work, work);
    BS.zeros(work);
    BW.zeros(lwork);
    residual.zeros(work);
    T.zeros(lwork);
    svratio.zeros(work);
    iterations = 0;
    products = 0;
    status = irlb(
      matrix, op, op == nullptr ? 0 : 2, rows, columns, rank, work,
      maxit, 0, tol, nullptr, nullptr, nullptr,
      s.memptr(), U.memptr(), V.memptr(), &iterations, &products,
      eps, lwork, V1.memptr(), U1.memptr(), W.memptr(), F.memptr(),
      B.memptr(), BU.memptr(), BV.memptr(), BS.memptr(), BW.memptr(),
      residual.memptr(), T.memptr(), svtol, svratio.memptr()
    );
  }
};

} // namespace fastpls_svd

#endif
