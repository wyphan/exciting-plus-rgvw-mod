#include <stdio.h>
#include "cublas_v2.h"

extern "C" int f_cublasCreate(cublasHandle_t **handle)
{
    *handle = (cublasHandle_t*)malloc(sizeof(cublasHandle_t));
    return cublasCreate(*handle);
}

extern "C" int f_cublasZgemm(cublasHandle_t *handle,
               cublasOperation_t transa, cublasOperation_t transb, 
              int m, int n, int k, 
              const cuDoubleComplex *alpha,
              const cuDoubleComplex *A, int lda, 
              const cuDoubleComplex *B, int ldb,
              const cuDoubleComplex *beta, 
              cuDoubleComplex *C, int ldc)
{
    return cublasZgemm(*handle,transa,transb,m,n,k,alpha,A,lda,B,ldb,beta,C,ldc);
}

extern "C" int f_cublasZgemmBatched(cublasHandle_t *handle,
               cublasOperation_t transa, cublasOperation_t transb,
              int m, int n, int k,
              const cuDoubleComplex *alpha,
              const cuDoubleComplex **A, int lda,
              const cuDoubleComplex **B, int ldb,
              const cuDoubleComplex *beta,
              cuDoubleComplex **C, int ldc,
              int batch_count)
{
    return cublasZgemmBatched(*handle,transa,transb,m,n,k,alpha,A,lda,B,ldb,beta,C,ldc,batch_count);
}

extern "C" void f_cublasDestroy(cublasHandle_t *handle)
{
    cublasDestroy(*handle);
    free(handle);
}

extern "C" int f_cudaStreamCreate(cudaStream_t **stream)
{
    *stream = (cudaStream_t *) malloc(sizeof(cudaStream_t));
    return cudaStreamCreate(*stream);
}

extern "C" int f_cublasSetStream(cublasHandle_t *handle, cudaStream_t *streamid)
{
    return cublasSetStream(*handle, *streamid);
}

extern "C" void f_cudaStreamDestroy(cudaStream_t *stream)
{
    cudaStreamDestroy(*stream);
}
