#include "cuda_resident_component.cuh"
#include <vector>
#include <cstdio>
#include <cstdlib>
#include <cmath>
using namespace fastpls_device;
template<class T> using Vec=std::vector<T>;
template<class T> T* allocate(size_t n){T* p;require_cuda(cudaMalloc(&p,n*sizeof(T)));return p;}
template<class T> T length(const Vec<T>& x){T v=0;for(T a:x)v+=a*a;return std::sqrt(v);}
template<class T> Vec<T> transpose(const Vec<T>& M,int rows,int cols,const Vec<T>& x){
    Vec<T> out(cols,0);for(int j=0;j<cols;++j)for(int i=0;i<rows;++i)out[j]+=M[size_t(j)*rows+i]*x[i];return out;
}
template<class T> void subtract(Vec<T>& x,const Vec<T>& M,int cols,const Vec<T>& coefficients){
    for(size_t i=0;i<x.size();++i){T v=0;for(int j=0;j<cols;++j)v+=M[size_t(j)*x.size()+i]*coefficients[j];x[i]-=v;}
}
template<class T> void run(int n,int p,int q,int a,bool classification){
    Vec<T> X(n*p),Y(n*q),S(p*q,0),R(p*a),scores(n*a),V(p*a),Q(q*a),candidates(p*a);
    for(size_t i=0;i<X.size();++i)X[i]=T(std::sin(double(i)*.31)+std::cos(double(i)*.057));
    for(size_t i=0;i<Y.size();++i)Y[i]=T(std::cos(double(i)*.73));
    std::vector<int> labels(n),counts(q,0);
    for(int i=0;i<n;++i){labels[i]=i<q?i+1:1+i%q;++counts[labels[i]-1];}
    if(classification)for(int j=0;j<q;++j)for(int i=0;i<n;++i)
        Y[j*n+i]=T(labels[i]==j+1)-T(counts[j])/T(n);
    for(size_t i=0;i<candidates.size();++i)candidates[i]=T(std::sin(double(i)*.97)+std::cos(double(i)*.43));
    for(int j=0;j<q;++j)for(int k=0;k<p;++k)for(int i=0;i<n;++i)S[j*p+k]+=X[k*n+i]*Y[j*n+i];
    cudaStream_t stream;require_cuda(cudaStreamCreateWithFlags(&stream,cudaStreamNonBlocking));
    T *dx=allocate<T>(X.size()),*dy=allocate<T>(Y.size()),*ds=allocate<T>(S.size()),*dr=allocate<T>(R.size()),
      *dt=allocate<T>(scores.size()),*dv=allocate<T>(V.size()),*dq=allocate<T>(Q.size()),*dc=allocate<T>(candidates.size());
    int* invalid=allocate<int>(1);require_cuda(cudaMemsetAsync(invalid,0,sizeof(int),stream));
    int *dylabel=allocate<int>(n),*keys=allocate<int>(n),*rows=allocate<int>(n),*offsets=allocate<int>(q+1);
    T* priors=allocate<T>(q);
    if(classification){
        require_cuda(cudaMemcpyAsync(dylabel,labels.data(),n*sizeof(int),cudaMemcpyHostToDevice,stream));
        require_cuda(prepare_labels(dylabel,n,q,keys,rows,offsets,priors,invalid,stream));
    }
    auto put=[&](T* d,const Vec<T>& v){require_cuda(cudaMemcpyAsync(d,v.data(),v.size()*sizeof(T),cudaMemcpyHostToDevice,stream));};
    put(dx,X);put(dy,Y);put(ds,S);put(dc,candidates);
    {
        ComponentWorkspace<T> work(n,p,q,a,stream);
        for(int used=0;used<a;++used){
            work.step(dx,classification?nullptr:dy,ds,dc+used*p,used,dr,dt,dv,dq,invalid,rows,offsets,priors);
            Vec<T> r(candidates.begin()+used*p,candidates.begin()+(used+1)*p),t(n,0);
            if(used){
                auto pr=transpose(V,p,used,r);
                if(length(pr)>T(32)*std::numeric_limits<T>::epsilon()*length(r))
                    for(int pass=0;pass<2;++pass){subtract(r,V,used,pr);pr=transpose(V,p,used,r);}
            }
            for(int i=0;i<n;++i)for(int j=0;j<p;++j)t[i]+=X[j*n+i]*r[j];
            if(used){
                auto pr=transpose(scores,n,used,t);
                if(length(pr)>T(32)*std::numeric_limits<T>::epsilon()*length(t))
                    for(int pass=0;pass<2;++pass){subtract(t,scores,used,pr);subtract(r,R,used,pr);pr=transpose(scores,n,used,t);}
            }
            T norm=length(t);for(T& x:t)x/=norm;for(T& x:r)x/=norm;
            auto v=transpose(X,n,p,t),response=transpose(Y,n,q,t);
            for(int pass=0;pass<2&&used;++pass){auto pr=transpose(V,p,used,v);subtract(v,V,used,pr);}
            norm=length(v);for(T& x:v)x/=norm;
            auto row=transpose(S,p,q,v);
            for(int j=0;j<q;++j)for(int i=0;i<p;++i)S[j*p+i]-=v[i]*row[j];
            std::copy(r.begin(),r.end(),R.begin()+used*p);std::copy(t.begin(),t.end(),scores.begin()+used*n);
            std::copy(v.begin(),v.end(),V.begin()+used*p);std::copy(response.begin(),response.end(),Q.begin()+used*q);
        }
        int bad;require_cuda(cudaMemcpyAsync(&bad,invalid,sizeof(int),cudaMemcpyDeviceToHost,stream));
        require_cuda(cudaStreamSynchronize(stream));if(bad)std::exit(2);
        double worst=0;
        auto compare=[&](T* d,const Vec<T>& expected){
            Vec<T> got(expected.size());require_cuda(cudaMemcpy(got.data(),d,got.size()*sizeof(T),cudaMemcpyDeviceToHost));
            double error=0,denom=0;for(size_t i=0;i<got.size();++i){error=std::fmax(error,std::fabs(double(got[i]-expected[i])));denom=std::fmax(denom,std::fabs(double(expected[i])));}
            worst=std::fmax(worst,error/std::fmax(1.0,denom));
        };
        compare(dr,R);compare(dt,scores);compare(dv,V);compare(dq,Q);compare(ds,S);
        std::printf("%s %s n=%d p=%d q=%d a=%d maximum_scaled_error=%.9g %s\n",sizeof(T)==4?"float32":"float64",classification?"classification":"regression",n,p,q,a,worst,worst<(sizeof(T)==4?2e-4:1e-11)?"PASS":"FAIL");
        if(worst>=(sizeof(T)==4?2e-4:1e-11))std::exit(3);
    }
    for(void* d:{(void*)dx,(void*)dy,(void*)ds,(void*)dr,(void*)dt,(void*)dv,(void*)dq,(void*)dc,(void*)invalid})require_cuda(cudaFree(d));
    for(void* d:{(void*)dylabel,(void*)keys,(void*)rows,(void*)offsets,(void*)priors})require_cuda(cudaFree(d));
    require_cuda(cudaStreamDestroy(stream));
}
int main(){for(int n:{17,257})for(int p:{7,23})for(bool cls:{false,true}){run<float>(n,p,3,4,cls);run<double>(n,p,3,4,cls);}}
