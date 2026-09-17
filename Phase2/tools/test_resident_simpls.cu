#include "cuda_resident_simpls.cuh"
#include <vector>
#include <random>
#include <cstdio>
#include <cstdlib>
using namespace fastpls_device;
template<class T> T* alloc(size_t n){T* p;require_cuda(cudaMalloc(&p,n*sizeof(T)));return p;}
template<class T> void test(bool classification) {
    const int n=64,p=7,q=3,a=4,nt=11;
    std::mt19937 rng(19);std::normal_distribution<double> normal;
    std::vector<T> X(n*p),Y(n*q),Xt(nt*p),pred(nt*q),R(p*a),Q(q*a);
    std::vector<int> labels(n);for(int i=0;i<n;++i)labels[i]=1+i%q;
    for(T& v:X)v=T(normal(rng));for(T& v:Y)v=T(normal(rng));for(T& v:Xt)v=T(normal(rng));
    cudaStream_t stream;require_cuda(cudaStreamCreateWithFlags(&stream,cudaStreamNonBlocking));
    T *dx=alloc<T>(Xt.size()),*dt=alloc<T>(nt*a),*dy=alloc<T>(pred.size());
    {
        ResidentSimpls<T> model(n,p,q,a,3,2,stream);
        model.fit(X.data(),classification?nullptr:Y.data(),classification?labels.data():nullptr,2,123);
        require_cuda(cudaMemcpyAsync(dx,Xt.data(),Xt.size()*sizeof(T),cudaMemcpyHostToDevice,stream));
        model.predict_device(dx,nt,a,dt,dy);
        require_cuda(cudaMemcpyAsync(pred.data(),dy,pred.size()*sizeof(T),cudaMemcpyDeviceToHost,stream));
        require_cuda(cudaMemcpyAsync(R.data(),model.weights(),R.size()*sizeof(T),cudaMemcpyDeviceToHost,stream));
        require_cuda(cudaMemcpyAsync(Q.data(),model.loadings(),Q.size()*sizeof(T),cudaMemcpyDeviceToHost,stream));
        require_cuda(cudaStreamSynchronize(stream));
        double worst=0;
        for(int j=0;j<q;++j)for(int i=0;i<nt;++i) {
            double expected=0;
            for(int r=0;r<n;++r)expected+=classification?double(labels[r]==j+1):double(Y[j*n+r]);
            expected/=n;
            for(int c=0;c<a;++c) {
                double score=0;
                for(int k=0;k<p;++k) {
                    double mean=0,var=0;for(int r=0;r<n;++r)mean+=X[k*n+r];mean/=n;
                    for(int r=0;r<n;++r)var+=std::pow(double(X[k*n+r])-mean,2);
                    score+=(double(Xt[k*nt+i])-mean)/std::sqrt(var/(n-1))*R[c*p+k];
                }
                expected+=score*Q[c*q+j];
            }
            if(!std::isfinite(expected)||!std::isfinite(double(pred[j*nt+i])))std::exit(3);
            worst=std::fmax(worst,std::fabs(expected-double(pred[j*nt+i])));
        }
        const bool ok=std::isfinite(worst)&&worst<(sizeof(T)==4?2e-5:1e-11);
        std::printf("%s %s complete resident fit/prediction consistency error=%.9g %s\n",sizeof(T)==4?"float32":"float64",classification?"classification":"regression",worst,ok?"PASS":"FAIL");
        if(!ok)std::exit(2);
    }
    require_cuda(cudaFree(dx));require_cuda(cudaFree(dt));require_cuda(cudaFree(dy));require_cuda(cudaStreamDestroy(stream));
}
int main(){test<float>(false);test<double>(false);test<float>(true);test<double>(true);}
