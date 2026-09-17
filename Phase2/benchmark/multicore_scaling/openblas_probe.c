#include <R.h>
#include <Rinternals.h>

extern int openblas_get_num_threads(void);

SEXP fastpls_openblas_threads(void) {
    return ScalarInteger(openblas_get_num_threads());
}
