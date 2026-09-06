#include "cuda_resident_lda.cuh"
#include <vector>
#include <random>
#include <cstdio>
#include <cstdlib>
using namespace fastpls_device;
template<class T> T* alloc(size_t n){T* p;require_cuda(cudaMalloc(&p,n*sizeof(T)));return p;}
template<class T> void test(int kind){
    const int n=67,a=4,c=3,nt=9;
    std::vector<T> train(n*a),test(nt*a),result(nt*c),priors(c);
    std::vector<int> labels(n),count(c,0),pred(nt);
    std::mt19937 rng(7);std::normal_distribution<double> normal;
    for(int i=0;i<n;++i){labels[i]=i<3?i+1:1+i%3;++count[labels[i]-1];}
    for(int j=0;j<a;++j){for(int i=0;i<n;++i)train[j*n+i]=T(normal(rng)+.25*labels[i]);for(int i=0;i<nt;++i)test[j*nt+i]=T(normal(rng));}
    if(kind==1){for(T& v:train)v=0;for(T& v:test)v=0;}
    if(kind==2){for(int i=0;i<n;++i)train[3*n+i]=train[i];for(int i=0;i<nt;++i)test[3*nt+i]=test[i];}
    cudaStream_t s;require_cuda(cudaStreamCreateWithFlags(&s,cudaStreamNonBlocking));
    T *dt=alloc<T>(train.size()),*dx=alloc<T>(test.size()),*out=alloc<T>(result.size()),*prior=alloc<T>(c);
    int *lab=alloc<int>(n),*keys=alloc<int>(n),*rows=alloc<int>(n),*offsets=alloc<int>(c+1),*invalid=alloc<int>(1),*decoded=alloc<int>(nt);
    require_cuda(cudaMemcpyAsync(dt,train.data(),train.size()*sizeof(T),cudaMemcpyHostToDevice,s));
    require_cuda(cudaMemcpyAsync(dx,test.data(),test.size()*sizeof(T),cudaMemcpyHostToDevice,s));
    require_cuda(cudaMemcpyAsync(lab,labels.data(),n*sizeof(int),cudaMemcpyHostToDevice,s));
    require_cuda(prepare_labels(lab,n,c,keys,rows,offsets,prior,invalid,s));
    {
        ResidentLda<T> lda(dt,n,a,c,rows,offsets,prior,s);
        lda.predict(dx,nt,a,out,decoded);
        T ridge;require_cuda(cudaMemcpyAsync(&ridge,lda.ridge_value(),sizeof(T),cudaMemcpyDeviceToHost,s));
        require_cuda(cudaMemcpyAsync(result.data(),out,result.size()*sizeof(T),cudaMemcpyDeviceToHost,s));
        require_cuda(cudaMemcpyAsync(pred.data(),decoded,pred.size()*sizeof(int),cudaMemcpyDeviceToHost,s));
        require_cuda(cudaStreamSynchronize(s));
        std::vector<double> mean(a*c,0),cov(a*a,0),L(a*a,0),weights(a*c,0),reference(nt*c);
        for(int j=0;j<a;++j)for(int i=0;i<n;++i)mean[(labels[i]-1)*a+j]+=double(train[j*n+i])/count[labels[i]-1];
        for(int j=0;j<a;++j)for(int k=0;k<a;++k){
            for(int i=0;i<n;++i)cov[j*a+k]+=(double(train[j*n+i])-mean[(labels[i]-1)*a+j])*(double(train[k*n+i])-mean[(labels[i]-1)*a+k])/(n-c);
            if(j==k)cov[j*a+k]+=ridge;
        }
        for(int i=0;i<a;++i)for(int j=0;j<=i;++j){double sum=cov[i*a+j];for(int k=0;k<j;++k)sum-=L[i*a+k]*L[j*a+k];L[i*a+j]=i==j?std::sqrt(sum):sum/L[j*a+j];}
        for(int cls=0;cls<c;++cls){
            double b[a];for(int i=0;i<a;++i){double sum=mean[cls*a+i];for(int j=0;j<i;++j)sum-=L[i*a+j]*b[j];b[i]=sum/L[i*a+i];}
            for(int i=a-1;i>=0;--i){double sum=b[i];for(int j=i+1;j<a;++j)sum-=L[j*a+i]*weights[cls*a+j];weights[cls*a+i]=sum/L[i*a+i];}
            double constant=std::log(double(count[cls])/n);for(int j=0;j<a;++j)constant-=.5*mean[cls*a+j]*weights[cls*a+j];
            for(int i=0;i<nt;++i){double v=constant;for(int j=0;j<a;++j)v+=double(test[j*nt+i])*weights[cls*a+j];reference[cls*nt+i]=v;}
        }
        double error=0;int agreement=0;
        for(int i=0;i<nt;++i){int best=0;for(int cls=0;cls<c;++cls){
            if(!std::isfinite(result[cls*nt+i])||!std::isfinite(reference[cls*nt+i]))std::exit(2);
            error=std::fmax(error,std::fabs(double(result[cls*nt+i])-reference[cls*nt+i]));
            if(reference[cls*nt+i]>reference[best*nt+i])best=cls;
        }agreement+=pred[i]==best+1;}
        bool ok=error<(sizeof(T)==4?1e-3:1e-7)&&agreement==nt;
        std::printf("float%d covariance_case=%d ridge=%.9g score_error=%.9g labels=%d/%d %s\n",int(sizeof(T)*8),kind,double(ridge),error,agreement,nt,ok?"PASS":"FAIL");
        if(!ok)std::exit(3);
    }
    for(void* p:{(void*)dt,(void*)dx,(void*)out,(void*)prior,(void*)lab,(void*)keys,(void*)rows,(void*)offsets,(void*)invalid,(void*)decoded})require_cuda(cudaFree(p));
    require_cuda(cudaStreamDestroy(s));
}
int main(){for(int kind:{0,1,2}){test<float>(kind);test<double>(kind);}}
