#include "cuda_resident_variance.cuh"
#include <vector>
#include <iostream>
#include <cmath>
#include <algorithm>

template<class T> void run(bool zero) {
    const int n=37,p=13,a=4;
    std::vector<T> x(n*p),scores(n*a),reference(p*a),ss(a+1),residual;
    for(int j=0;j<p;++j)for(int i=0;i<n;++i)x[i+j*n]=T(std::sin(.17*i+.31*j));
    for(int j=0;j<a;++j)for(int i=0;i<n;++i)
        scores[i+j*n]=(zero&&j==1)?T(0):T(std::cos(.11*i*(j+1))+.1*j);
    residual=x;
    for(T v:x)ss[a]+=v*v;
    for(int j=0;j<a;++j) {
        T denom=0,before=0,after=0;
        for(int i=0;i<n;++i)denom+=scores[i+j*n]*scores[i+j*n];
        for(T v:residual)before+=v*v;
        if(denom>0)for(int f=0;f<p;++f) {
            T raw=0,adjusted=0;
            for(int i=0;i<n;++i){raw+=x[i+f*n]*scores[i+j*n];adjusted+=residual[i+f*n]*scores[i+j*n];}
            reference[f+j*p]=raw/denom;
            for(int i=0;i<n;++i)residual[i+f*n]-=scores[i+j*n]*adjusted/denom;
        }
        for(T v:residual)after+=v*v;
        ss[j]=std::max(T(0),before-after);
    }
    cudaStream_t stream;fastpls_device::require_cuda(cudaStreamCreate(&stream));
    T *dx,*dt;cudaMalloc(&dx,x.size()*sizeof(T));cudaMalloc(&dt,scores.size()*sizeof(T));
    cudaMemcpyAsync(dx,x.data(),x.size()*sizeof(T),cudaMemcpyHostToDevice,stream);
    cudaMemcpyAsync(dt,scores.data(),scores.size()*sizeof(T),cudaMemcpyHostToDevice,stream);
    double error=0;
    {
        fastpls_device::VarianceWorkspace<T> w(n,p,a,stream);w.compute(dx,dt);
        std::vector<T> actual(p*a),actual_ss(a+1);
        cudaMemcpyAsync(actual.data(),w.predictor_loadings(),actual.size()*sizeof(T),cudaMemcpyDeviceToHost,stream);
        cudaMemcpyAsync(actual_ss.data(),w.sums_of_squares(),actual_ss.size()*sizeof(T),cudaMemcpyDeviceToHost,stream);
        fastpls_device::require_cuda(cudaStreamSynchronize(stream));
        for(size_t i=0;i<actual.size();++i)error=std::max(error,std::abs(double(actual[i]-reference[i]))/(1+std::abs(double(reference[i]))));
        for(int j=0;j<=a;++j)error=std::max(error,std::abs(double(actual_ss[j]-ss[j]))/(1+std::abs(double(ss[j]))));
    }
    cudaFree(dx);cudaFree(dt);cudaStreamDestroy(stream);
    std::cout<<"precision="<<8*sizeof(T)<<" zero_score="<<zero<<" error="<<error<<"\n";
    if(!std::isfinite(error)||error>(sizeof(T)==4?2e-4:1e-11))throw std::runtime_error("variance oracle mismatch");
}
int main(){run<float>(false);run<float>(true);run<double>(false);run<double>(true);}
