#include "cuda_resident_preprocess.cuh"
#include <cstdio>
#include <vector>
#include <cstdlib>

void check(cudaError_t x) {
    if (x != cudaSuccess) { std::fprintf(stderr, "%s\n", cudaGetErrorString(x)); std::exit(1); }
}
template<class T> void test(int n, int mode) {
    std::vector<T> x(n * 3), expected(n * 3);
    for (int j = 0; j < 3; ++j)
        for (int i = 0; i < n; ++i)
            x[j*n+i] = j == 2 ? T(7) : T((i%17)-8) + T(j)*T(0.25);
    for (int j = 0; j < 3; ++j) {
        double mean = 0, var = 0;
        for (int i = 0; i < n; ++i) mean += x[j*n+i];
        mean /= n;
        for (int i = 0; i < n; ++i) var += std::pow(double(x[j*n+i])-mean, 2);
        double sd = mode == 2 && n > 1 ? std::sqrt(var/(n-1)) : 1;
        if (!(sd > 0)) sd = 1;
        for (int i = 0; i < n; ++i) expected[j*n+i] = (x[j*n+i] - (mode<3?mean:0))/sd;
    }
    T *dx, *dm, *ds; cudaStream_t stream;
    check(cudaStreamCreate(&stream));
    check(cudaMalloc(&dx,x.size()*sizeof(T))); check(cudaMalloc(&dm,3*sizeof(T))); check(cudaMalloc(&ds,3*sizeof(T)));
    check(cudaMemcpyAsync(dx,x.data(),x.size()*sizeof(T),cudaMemcpyHostToDevice,stream));
    check(fastpls_device::preprocess(dx,n,3,mode,dm,ds,stream));
    check(cudaMemcpyAsync(x.data(),dx,x.size()*sizeof(T),cudaMemcpyDeviceToHost,stream));
    check(cudaStreamSynchronize(stream));
    double error = 0;
    for (size_t i=0;i<x.size();++i) error=std::fmax(error,std::fabs(double(x[i]-expected[i])));
    if (error > (sizeof(T)==4 ? 2e-5 : 1e-12)) std::exit(2);
    std::printf("%s n=%d scaling=%d max_error=%.9g PASS\n",sizeof(T)==4?"float32":"float64",n,mode,error);
    check(cudaFree(dx)); check(cudaFree(dm)); check(cudaFree(ds)); check(cudaStreamDestroy(stream));
}
int main() {
    for (int n : {1,17,257,5000}) for (int mode : {1,2,3}) {
        test<float>(n,mode);test<double>(n,mode);
    }
}
