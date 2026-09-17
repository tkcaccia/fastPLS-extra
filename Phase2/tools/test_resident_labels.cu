#include "cuda_resident_labels.cuh"
#include <vector>
#include <cstdio>
#include <cstdlib>
#include <cmath>

void ck(cudaError_t e) {
    if(e!=cudaSuccess) { std::fprintf(stderr,"%s\n",cudaGetErrorString(e));std::exit(1); }
}
template<class T> T* alloc(size_t n) { T* p;ck(cudaMalloc(&p,n*sizeof(T)));return p; }
template<class T> void test(int n,int p,int classes,int bad) {
    cudaStream_t stream;ck(cudaStreamCreateWithFlags(&stream,cudaStreamNonBlocking));
    std::vector<int> y(n), count(classes);
    std::vector<T> x(size_t(n)*p), actual(size_t(p)*classes), expected(actual.size());
    for(int i=0;i<n;++i) { y[i]=i<classes?i+1:(i%7==0?classes:1);++count[y[i]-1]; }
    if(bad==1)y[0]=0;
    if(bad==2)for(int& c:y)if(c==classes)c=1;
    for(int j=0;j<p;++j) for(int i=0;i<n;++i) x[size_t(j)*n+i]=T((i*3+j*5)%23-11)/T(8);
    int *dy=alloc<int>(n),*keys=alloc<int>(n),*rows=alloc<int>(n),*offsets=alloc<int>(classes+1),*invalid=alloc<int>(1);
    T *dx=alloc<T>(x.size()),*prior=alloc<T>(classes),*out=alloc<T>(actual.size());
    ck(cudaMemcpyAsync(dy,y.data(),n*sizeof(int),cudaMemcpyHostToDevice,stream));
    ck(cudaMemcpyAsync(dx,x.data(),x.size()*sizeof(T),cudaMemcpyHostToDevice,stream));
    ck(fastpls_device::prepare_labels(dy,n,classes,keys,rows,offsets,prior,invalid,stream));
    int error=0;ck(cudaMemcpyAsync(&error,invalid,sizeof(int),cudaMemcpyDeviceToHost,stream));
    ck(cudaStreamSynchronize(stream));
    if(bool(error)!=bool(bad))std::exit(2);
    double maxerror=0;
    if(!bad) {
        ck(fastpls_device::class_product(dx,n,p,classes,rows,offsets,prior,out,stream));
        ck(cudaMemcpyAsync(actual.data(),out,actual.size()*sizeof(T),cudaMemcpyDeviceToHost,stream));
        ck(cudaStreamSynchronize(stream));
        for(int j=0;j<p;++j) for(int c=0;c<classes;++c) {
            double sum=0,total=0;
            for(int i=0;i<n;++i) {total+=x[size_t(j)*n+i];if(y[i]==c+1)sum+=x[size_t(j)*n+i];}
            expected[size_t(c)*p+j]=T(sum-total*double(count[c])/n);
        }
        for(size_t i=0;i<actual.size();++i)maxerror=std::fmax(maxerror,std::fabs(double(actual[i]-expected[i])));
        if(maxerror>(sizeof(T)==4?2e-4:1e-11))std::exit(3);
    }
    std::printf("%s n=%d p=%d classes=%d invalid_case=%d max_error=%.9g PASS\n",sizeof(T)==4?"float32":"float64",n,p,classes,bad,maxerror);
    for(void* q:{(void*)dy,(void*)keys,(void*)rows,(void*)offsets,(void*)invalid,(void*)dx,(void*)prior,(void*)out})ck(cudaFree(q));
    ck(cudaStreamDestroy(stream));
}
int main() {
    for(int n:{17,257,5000}) for(int p:{1,13}) for(int bad:{0,1,2}) {
        test<float>(n,p,7,bad);test<double>(n,p,7,bad);
    }
}
