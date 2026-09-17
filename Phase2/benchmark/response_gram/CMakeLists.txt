cmake_minimum_required(VERSION 3.18)
project(fastpls_response_gram_benchmark LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

option(GRAM_ENABLE_OPENBLAS "Build OpenBLAS executables" ON)
option(GRAM_ENABLE_MKL "Build oneMKL executable" ON)
option(GRAM_ENABLE_BLIS "Build BLIS/AOCL executable" ON)
option(GRAM_ENABLE_LIBXSMM "Build LIBXSMM executable" ON)
option(GRAM_ENABLE_BLASFEO "Build BLASFEO executable" ON)

find_package(Threads REQUIRED)

add_library(gram_benchmark_common OBJECT src/benchmark_main.cpp)
target_include_directories(gram_benchmark_common PRIVATE include)
target_compile_options(gram_benchmark_common PRIVATE -O3)

function(add_gram_executable target backend_source)
  add_executable(${target} $<TARGET_OBJECTS:gram_benchmark_common> ${backend_source})
  target_include_directories(${target} PRIVATE include)
  target_compile_options(${target} PRIVATE -O3)
  target_link_libraries(${target} PRIVATE Threads::Threads ${ARGN})
endfunction()

add_gram_executable(gram_custom src/backend_custom.cpp)

if(APPLE)
  add_gram_executable(gram_accelerate_gemm src/backend_accelerate_gemm.cpp
    "-framework Accelerate")
  add_gram_executable(gram_accelerate_syrk src/backend_accelerate_syrk.cpp
    "-framework Accelerate")
endif()

if(GRAM_ENABLE_OPENBLAS)
  if(DEFINED ENV{OPENBLAS_ROOT})
    set(GRAM_OPENBLAS_ROOT "$ENV{OPENBLAS_ROOT}")
  elseif(APPLE AND EXISTS /opt/homebrew/opt/openblas)
    set(GRAM_OPENBLAS_ROOT /opt/homebrew/opt/openblas)
  endif()
  if(GRAM_OPENBLAS_ROOT)
    find_path(OPENBLAS_INCLUDE_DIR openblas_config.h
      PATHS "${GRAM_OPENBLAS_ROOT}/include" NO_DEFAULT_PATH)
    find_library(OPENBLAS_LIBRARY NAMES openblas openblasp
      PATHS "${GRAM_OPENBLAS_ROOT}/lib" NO_DEFAULT_PATH)
  else()
    find_path(OPENBLAS_INCLUDE_DIR openblas_config.h)
    find_library(OPENBLAS_LIBRARY NAMES openblas openblasp)
  endif()
  if(OPENBLAS_INCLUDE_DIR AND OPENBLAS_LIBRARY)
    add_gram_executable(gram_openblas_gemm src/backend_openblas_gemm.cpp
      ${OPENBLAS_LIBRARY})
    add_gram_executable(gram_openblas_syrk src/backend_openblas_syrk.cpp
      ${OPENBLAS_LIBRARY})
    add_gram_executable(gram_openblas_syrk_upper src/backend_openblas_syrk_upper.cpp
      ${OPENBLAS_LIBRARY})
    target_include_directories(gram_openblas_gemm PRIVATE ${OPENBLAS_INCLUDE_DIR})
    target_include_directories(gram_openblas_syrk PRIVATE ${OPENBLAS_INCLUDE_DIR})
    target_include_directories(gram_openblas_syrk_upper PRIVATE ${OPENBLAS_INCLUDE_DIR})
  else()
    message(STATUS "OpenBLAS not found; OpenBLAS executables disabled")
  endif()
endif()

if(GRAM_ENABLE_MKL AND DEFINED ENV{MKLROOT})
  find_path(MKL_INCLUDE_DIR mkl.h HINTS "$ENV{MKLROOT}/include")
  if(DEFINED ENV{MKL_LIBRARY_ROOT})
    set(GRAM_MKL_LIBRARY_HINT "$ENV{MKL_LIBRARY_ROOT}")
  else()
    set(GRAM_MKL_LIBRARY_HINT "$ENV{MKLROOT}")
  endif()
  find_library(MKL_RT_LIBRARY NAMES mkl_rt
    HINTS "${GRAM_MKL_LIBRARY_HINT}/lib/intel64"
          "${GRAM_MKL_LIBRARY_HINT}/lib")
  if(MKL_INCLUDE_DIR AND MKL_RT_LIBRARY)
    add_gram_executable(gram_mkl_syrk src/backend_mkl_syrk.cpp
      ${MKL_RT_LIBRARY} ${CMAKE_DL_LIBS})
    target_include_directories(gram_mkl_syrk PRIVATE ${MKL_INCLUDE_DIR})
  else()
    message(STATUS "MKLROOT is set but oneMKL headers/runtime were not found")
  endif()
endif()

if(GRAM_ENABLE_BLIS AND DEFINED ENV{BLIS_ROOT})
  find_path(BLIS_INCLUDE_DIR cblas.h
    HINTS "$ENV{BLIS_ROOT}/include" "$ENV{BLIS_ROOT}/include/blis")
  find_library(BLIS_LIBRARY NAMES blis HINTS "$ENV{BLIS_ROOT}/lib")
  if(BLIS_INCLUDE_DIR AND BLIS_LIBRARY)
    add_gram_executable(gram_blis_syrk src/backend_blis_syrk.cpp ${BLIS_LIBRARY})
    target_include_directories(gram_blis_syrk PRIVATE ${BLIS_INCLUDE_DIR})
  else()
    message(STATUS "BLIS_ROOT is set but BLIS/AOCL CBLAS was not found")
  endif()
endif()

if(GRAM_ENABLE_LIBXSMM AND DEFINED ENV{LIBXSMM_ROOT})
  find_path(LIBXSMM_INCLUDE_DIR libxsmm.h
    HINTS "$ENV{LIBXSMM_ROOT}/include" PATH_SUFFIXES libxsmm)
  find_library(LIBXSMM_LIBRARY NAMES xsmm HINTS "$ENV{LIBXSMM_ROOT}/lib")
  if(LIBXSMM_INCLUDE_DIR AND LIBXSMM_LIBRARY)
    add_gram_executable(gram_libxsmm src/backend_libxsmm.cpp ${LIBXSMM_LIBRARY})
    target_include_directories(gram_libxsmm PRIVATE ${LIBXSMM_INCLUDE_DIR})
  else()
    message(STATUS "LIBXSMM_ROOT is set but LIBXSMM was not found")
  endif()
endif()

if(GRAM_ENABLE_BLASFEO AND DEFINED ENV{BLASFEO_ROOT})
  find_path(BLASFEO_INCLUDE_DIR blasfeo_target.h
    HINTS "$ENV{BLASFEO_ROOT}/include" "$ENV{BLASFEO_ROOT}/blasfeo/include")
  find_library(BLASFEO_LIBRARY NAMES blasfeo
    HINTS "$ENV{BLASFEO_ROOT}/lib" "$ENV{BLASFEO_ROOT}/blasfeo/lib")
  if(BLASFEO_INCLUDE_DIR AND BLASFEO_LIBRARY)
    add_gram_executable(gram_blasfeo src/backend_blasfeo.cpp
      ${BLASFEO_LIBRARY} ${CMAKE_DL_LIBS} m)
    target_include_directories(gram_blasfeo PRIVATE ${BLASFEO_INCLUDE_DIR})
  else()
    message(STATUS "BLASFEO_ROOT is set but BLASFEO was not found")
  endif()
endif()
