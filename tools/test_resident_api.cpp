#include "cuda_resident_api.h"
#include <vector>
#include <cmath>
#include <cstdio>
#include <cstdlib>
template<class T> void test(bool classification){
    const int n=64,p=7,q=3,a=4;
    std::vector<T> x(n*p),y(n*q),pred(n*q),again(n*q);
    std::vector<int> labels(n);
    for(size_t i=0;i<x.size();++i)x[i]=T(std::sin(i*.173+i*i*.007));
    for(size_t i=0;i<y.size();++i)y[i]=T(std::cos(i*.271));
    for(int i=0;i<n;++i)labels[i]=1+i%q;
    char error[512];
    void* model=fastpls_resident_simpls_create(x.data(),classification?nullptr:y.data(),classification?labels.data():nullptr,
        sizeof(T)==4?32:64,n,p,q,a,2,3,2,123,error,sizeof(error));
    if(!model){std::fprintf(stderr,"%s\n",error);std::exit(1);}
    for(int k=1;k<=a;++k){
        if(fastpls_resident_simpls_predict(model,x.data(),n,k,pred.data(),error,sizeof(error)) ||
           fastpls_resident_simpls_predict(model,x.data(),n,k,again.data(),error,sizeof(error))){std::fprintf(stderr,"%s\n",error);std::exit(2);}
        for(size_t i=0;i<pred.size();++i)if(!std::isfinite(pred[i])||pred[i]!=again[i])std::exit(3);
    }
    if(!fastpls_resident_simpls_predict(model,x.data(),n,a+1,pred.data(),error,sizeof(error)))std::exit(4);
    fastpls_resident_simpls_destroy(model);
    std::printf("float%d %s C interface: four prefixes, repeat predictions and invalid-prefix rejection PASS\n",int(sizeof(T)*8),classification?"classification":"regression");
}
int main(){test<float>(false);test<double>(false);test<float>(true);test<double>(true);}
