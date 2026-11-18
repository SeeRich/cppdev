# C++ Docker Container Development with recent GCC + LLVM

A development image for trying the newest C++ compiler features. GCC, LLVM and the
analysis tools are built from source in a multi-stage Docker build. Only the installed
results are copied into a slim Ubuntu Noble image: about 1.24 GB on disk and 319 MB
compressed (amd64).

## What's in the image

| Tool | Version | Notes |
| --- | --- | --- |
| Ubuntu | `noble-20261110` | base image |
| GCC | 16.2.0 | C and C++; `gcc`/`g++` symlink to `gcc-16`/`g++-16` |
| LLVM | 23.1.6 | clang, lld, clang-tidy, clang-format, clangd, clang-scan-deps, llvm-ar/nm/objdump/symbolizer/cov/profdata |
| libc++ / compiler-rt | 23.1.6 | ASan, UBSan, TSan, MSan, LSan, RTSan, libFuzzer, profile runtime, OpenMP (libomp) |
| include-what-you-use | 0.27 | |
| CMake | 4.4.5 | official release binaries |
| Ninja | 1.13.2 | official release binary |
| mold | 3.0.0 | official release binary |
| Valgrind | 3.28.0 | |
| Cppcheck | 2.22.0 | |

Clang is the default compiler (`CC=clang`, `CXX=clang++`, and `cc`/`c++` point at it). It
uses libc++, compiler-rt, libunwind and lld by default. Use GCC with `CC=gcc CXX=g++`, or
`-DCMAKE_CXX_COMPILER=g++`. Clang can also build against GCC's libstdc++ with
`-stdlib=libstdc++`.

GCC's runtime libraries (`/usr/local/lib64`) and clang's runtime directory are registered
with `ldconfig`, so binaries built by either compiler run without `LD_LIBRARY_PATH`.

### Notes on the newest features

* **GCC 16 static reflection** needs `-freflection`. **GCC 16 contracts** work with
  `-std=c++26` alone, but the default violation handler lives in `libstdc++exp`, so link
  with `-lstdc++exp`. The example's `CMakeLists.txt` does both.
* **`import std;`** works with both compilers through CMake 4.4. It is still experimental
  there, so set this before `project()`:
  ```cmake
  set(CMAKE_EXPERIMENTAL_CXX_IMPORT_STD "f35a9ac6-8463-4d38-8eec-5d6008153e7d")  # CMake 4.4
  set(CMAKE_CXX_MODULE_STD ON)
  ```
* **Clang's ThreadSanitizer** needs to disable ASLR on kernels with high mmap entropy.
  Docker's default seccomp profile blocks that, so run with
  `--security-opt seccomp=unconfined` (GCC's TSan works either way).

### Left out to keep the image small

* Fortran (gfortran, flang) and lldb.
* Python and Conan. CMake now comes from the official binary release instead of pip.
  Without Python, `run-clang-tidy` and `git-clang-format` are installed but won't run, and
  IWYU's `iwyu_tool.py` isn't installed at all. Use CMake's `CMAKE_CXX_CLANG_TIDY` /
  `CMAKE_CXX_INCLUDE_WHAT_YOU_USE` instead.
* GCC's `lto-dump`, GCC plugin headers, and Valgrind's static tool-building libraries.
* The LLVM/Clang development headers and CMake packages. The image is for compiling C++,
  not for building tools against LLVM.

## Building

```sh
just docker-build                          # tags cppdev:latest, logs to build.log
just docker-build --build-arg JOBS=8       # cap parallel compile jobs (low-memory hosts)
```

The GCC, LLVM, Valgrind and Cppcheck stages are independent, so BuildKit builds them in
parallel. Each stage limits itself by load average, so together they don't oversubscribe
the CPU. The LLVM stage is split in two layers: the compilers, then the runtimes
(libc++, compiler-rt, ...). Changing a runtime flag only rebuilds the second layer.

Versions are `ARG`s at the top of each stage, e.g.
`--build-arg GCC_VERSION=16.2.0 --build-arg LLVM_VERSION=23.1.6`.

## Example project

[`example/`](example/) is a small CMake project that pulls the image, builds a C++26
program with GCC and with Clang (plus a Clang ASan/UBSan build), runs it, and runs
valgrind memcheck and cppcheck through `ctest`.

```sh
just example                              # uses the local cppdev:latest
./example/run.sh                          # uses seerich/cppdev:latest (pulled if missing)
CPPDEV_IMAGE=cppdev:latest ./example/run.sh gcc clang
```

`example/src/main.cpp` covers two groups of C++26 features. The first group works in
both GCC 16 and Clang 23, and the build fails if any of them break: pack indexing,
`#embed`, `= delete("reason")`, structured bindings as conditions, constexpr placement new,
variadic friends, saturation arithmetic, `std::span::at` and `std::dynamic_format`. The
second group is newer features such as reflection, contracts and `std::inplace_vector`.
Each one is compiled in only if the toolchain supports it, and the output lists which
ones each compiler has.
