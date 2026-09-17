# Sample-space response Gram benchmark

This benchmark compares dedicated compiled implementations of `G = Y Y^T`
for column-major `n x q` response matrices. Input generation and optional
triangle mirroring are outside the reported kernel time. Each executable is
linked directly to one numerical library; the benchmark does not switch BLAS
implementations at runtime.

The same executables accept `--operation crossprod` to measure `X^T X` on the
original column-major input layout. This companion path checks whether the
chosen symmetric-kernel policy also benefits predictor and score Gram matrices;
it is not inferred by transposing sample-Gram timings.

Implemented targets are:

- `gram_accelerate_syrk`: Apple Accelerate `SSYRK`/`DSYRK`;
- `gram_accelerate_gemm`: Apple Accelerate `SGEMM`/`DGEMM` control;
- `gram_openblas_gemm`: OpenBLAS `SGEMM`/`DGEMM` control;
- `gram_openblas_syrk`: OpenBLAS `SSYRK`/`DSYRK`;
- `gram_mkl_syrk`: oneMKL `SSYRK`/`DSYRK` when `MKLROOT` is set;
- `gram_blis_syrk`: BLIS or AOCL-BLAS `SSYRK`/`DSYRK` when `BLIS_ROOT` is set;
- `gram_custom`: portable C++ with safe AVX2/AVX-512 runtime dispatch on x86.

BLASFEO and LIBXSMM are optional research targets. They require explicit
packing or tiled JIT kernels because neither is a drop-in replacement for the
column-major large-rank `SYRK` contract. Their timings must include packing.

Every result reports sampled numerical error against compensated long-double
dot products. The componentwise maximum is accompanied by a sampled relative
L2 error so near-zero reference entries do not inflate the only agreement
measure. `useful_gflops` counts only the requested symmetric triangle;
`executed_gflops` also reflects redundant upper-triangle work in GEMM controls.
Kernel, mirroring, and total latency are reported separately. Peak RSS is
complete-process memory; baseline and incremental peak RSS distinguish the
benchmark process from allocations made after entering the timed program.

Build on macOS:

```sh
cmake -S . -B build-macos -DCMAKE_BUILD_TYPE=Release
cmake --build build-macos --parallel
```

Build on Linux with a private OpenBLAS installation:

```sh
export OPENBLAS_ROOT=/absolute/path/to/openblas
cmake -S . -B build-linux -DCMAKE_BUILD_TYPE=Release
cmake --build build-linux --parallel
```

Optional Linux libraries are enabled by setting `MKLROOT`, `BLIS_ROOT`,
`BLASFEO_ROOT`, or `LIBXSMM_ROOT` before configuration. Each resulting target
is linked directly to that library. An upstream BLIS build is a valid BLIS
comparison but must not be labelled AOCL unless it was built from AMD AOCL.

Build on Windows with Rtools and private OpenBLAS/oneMKL prefixes:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/build_windows.ps1 `
  -SourceArchive C:\bench\response-gram.tar.gz `
  -Destination C:\bench\response-gram-build `
  -OpenBlasRoot C:\bench\openblas `
  -MklRoot C:\bench\onemkl\Library
```

The script creates a new destination and refuses to overwrite an existing
one. OpenBLAS and oneMKL DLL directories must remain on `PATH` while running
their executables.

Run selected shapes:

```sh
python3 scripts/run_matrix.py \
  --build-dir build-linux \
  --output /absolute/private/results/response_gram.csv \
  --threads 1,2,4,8 \
  --physical-cores 16 \
  --shape 100x1000 \
  --shape 500x28355
```

For stable short-duration measurements, combine several inner repetitions with
fresh-process repetitions. On heterogeneous Intel processors, an optional JSON
affinity map can pin one worker to each physical core and avoid sibling-thread
oversubscription:

```sh
python3 scripts/run_matrix.py \
  --build-dir build-linux \
  --output /absolute/private/results/response_gram_full.csv \
  --threads 1,2,4,8 --physical-cores 16 \
  --process-repetitions 5 --repetitions 11 --full \
  --affinity-map scripts/intel_8p8e_affinity.json
```

Use `--full` only when downstream code requires both triangles. Unsupported
libraries are omitted at configuration time and must not be relabelled as a
different backend.

Benchmark predictor-space cross-products independently rather than inferring
them from response-Gram results:

```sh
python3 scripts/run_matrix.py \
  --build-dir build-linux \
  --output /absolute/private/results/crossprod.csv \
  --operation crossprod --full \
  --threads 1,2,4,8 --physical-cores 16 \
  --shape 1200x512 --shape 50000x768
```

Accelerate controls its own worker pool and therefore has no externally
enforceable thread-count setting in this harness. The tested BLASFEO and
LIBXSMM builds are also single-threaded. Their results are recorded once,
whereas OpenBLAS, oneMKL, BLIS, and the custom kernel are tested at every
requested thread count. Do not interpret a requested thread count as evidence
of active parallel execution; verify it from the linked library and host.
