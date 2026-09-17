#include "cuda_resident_rsvd.cuh"
#include <vector>
#include <cstdio>
#include <cstdlib>
#include <cmath>
using namespace fastpls_device;
template<class T> T* device(size_t n){T* p;require_cuda(cudaMalloc(&p,n*sizeof(T)));return p;}
template<class T> void test(int p,int q,int k,int extra,int power,unsigned seed){
    const int rank=std::min(p,q);
    std::vector<T> A(size_t(p)*q,0),U(size_t(p)*k),V(size_t(q)*k),D(k);
    const double pi=std::acos(-1.0);
    for(int j=0;j<rank;++j)for(int i=0;i<p;++i)
        A[size_t(j)*p+i]=T(std::pow(.65,j)*std::sqrt((j?2.:1.)/p)*std::cos(pi*(i+.5)*j/p));
    cudaStream_t stream;require_cuda(cudaStreamCreateWithFlags(&stream,cudaStreamNonBlocking));
    T *a=device<T>(A.size()),*u=device<T>(U.size()),*v=device<T>(V.size()),*d=device<T>(k);
    int* status=device<int>(1);
    require_cuda(cudaMemcpyAsync(a,A.data(),A.size()*sizeof(T),cudaMemcpyHostToDevice,stream));
    require_cuda(cudaMemsetAsync(status,0,sizeof(int),stream));
    {
        RsvdWorkspace<T> ws(p,q,k,extra,power,stream);
        // Reuse allocations and RNG state; identical seeds must replay.
        ws.solve(a,seed,u,v,d,status);
        require_cuda(cudaMemcpyAsync(D.data(),d,k*sizeof(T),cudaMemcpyDeviceToHost,stream));
        require_cuda(cudaStreamSynchronize(stream));auto first=D;
        ws.solve(a,seed,u,v,d,status);
        require_cuda(cudaMemcpyAsync(U.data(),u,U.size()*sizeof(T),cudaMemcpyDeviceToHost,stream));
        require_cuda(cudaMemcpyAsync(V.data(),v,V.size()*sizeof(T),cudaMemcpyDeviceToHost,stream));
        require_cuda(cudaMemcpyAsync(D.data(),d,k*sizeof(T),cudaMemcpyDeviceToHost,stream));
        int bad=0;require_cuda(cudaMemcpyAsync(&bad,status,sizeof(int),cudaMemcpyDeviceToHost,stream));
        require_cuda(cudaStreamSynchronize(stream));if(bad)std::exit(2);
        double singular_error=0,orthogonality=0,residual=0,optimal=0,replay=0;
        for(int j=0;j<k;++j){
            singular_error=std::fmax(singular_error,std::fabs(double(D[j])-std::pow(.65,j)));
            replay=std::fmax(replay,std::fabs(double(D[j]-first[j])));
            for(int z=0;z<k;++z){
                double x=0,y=0;for(int i=0;i<p;++i)x+=double(U[j*p+i])*U[z*p+i];
                for(int i=0;i<q;++i)y+=double(V[j*q+i])*V[z*q+i];
                orthogonality=std::fmax(orthogonality,std::fmax(std::fabs(x-(j==z)),std::fabs(y-(j==z))));
            }
        }
        for(int j=k;j<rank;++j)optimal+=std::pow(.65,2*j);
        for(int j=0;j<q;++j)for(int i=0;i<p;++i){
            double x=0;for(int z=0;z<k;++z)x+=double(U[z*p+i])*D[z]*V[z*q+j];
            residual+=std::pow(x-double(A[j*p+i]),2);
        }
        const double gap=std::fabs(residual-optimal),tol=sizeof(T)==4?2e-5:1e-9;
        bool ok=singular_error<tol&&orthogonality<tol&&gap<tol&&replay==0;
        std::printf("%s %dx%d k=%d extra=%d power=%d seed=%u sv_error=%.9g orth=%.9g residual_gap=%.9g replay=%.9g %s\n",sizeof(T)==4?"float32":"float64",p,q,k,extra,power,seed,singular_error,orthogonality,gap,replay,ok?"PASS":"FAIL");
        if(!ok)std::exit(3);
    }
    for(void* x:{(void*)a,(void*)u,(void*)v,(void*)d,(void*)status})require_cuda(cudaFree(x));
    require_cuda(cudaStreamDestroy(stream));
}
int main(){for(unsigned seed:{7,11}){
    test<float>(13,7,3,4,2,seed);test<double>(13,7,3,4,2,seed);
    test<float>(7,13,3,4,2,seed);test<double>(7,13,3,4,2,seed);
    test<float>(60,40,3,10,3,seed);test<double>(60,40,3,10,3,seed);
    test<float>(7,1,1,0,0,seed);test<double>(7,1,1,0,0,seed);
}}
