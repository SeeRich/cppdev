# syntax=docker/dockerfile:1
#
# C++ development image with GCC and LLVM built from source.
#
# Stages:
#   base      minimal Ubuntu shared by every stage
#   prebuilt  upstream release binaries: CMake, Ninja, mold
#   builder   distro toolchain used to compile everything below (never shipped)
#   gcc       GCC (C, C++)                                   -> /staging/usr/local
#   llvm      Clang, lld, clang-tools, libc++, compiler-rt   -> /staging/usr/local
#   valgrind  Valgrind                                       -> /staging/usr/local
#   cppcheck  Cppcheck                                       -> /staging/usr/local
#   dev       final image: base + the staged installs above (default target)
#
# gcc, llvm, valgrind and cppcheck don't depend on each other, so BuildKit builds them
# in parallel. Pass --build-arg JOBS=N to cap parallelism on memory-constrained hosts.

ARG UBUNTU_TAG=noble-20261110

######################## base ########################
FROM ubuntu:${UBUNTU_TAG} AS base

######################## prebuilt ########################
FROM base AS prebuilt
ARG TARGETARCH
ARG CMAKE_VERSION=4.4.5
ARG NINJA_VERSION=1.13.2
ARG MOLD_VERSION=3.0.0
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates curl unzip && \
    rm -rf /var/lib/apt/lists/*
RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) arch=x86_64;  ninja_zip=ninja-linux.zip ;; \
      arm64) arch=aarch64; ninja_zip=ninja-linux-aarch64.zip ;; \
      *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    dest=/staging/usr/local; \
    mkdir -p "${dest}/bin"; \
    # CMake: only the CLI tools and modules (no cmake-gui/ccmake/docs).
    curl -fsSL "https://github.com/Kitware/CMake/releases/download/v${CMAKE_VERSION}/cmake-${CMAKE_VERSION}-linux-${arch}.tar.gz" \
      | tar -xz -C "${dest}" --strip-components=1 --wildcards \
          '*/bin/cmake' '*/bin/ctest' '*/bin/cpack' '*/share/cmake-*' '*/share/aclocal' '*/share/bash-completion'; \
    curl -fsSL -o /tmp/ninja.zip "https://github.com/ninja-build/ninja/releases/download/v${NINJA_VERSION}/${ninja_zip}"; \
    unzip -q /tmp/ninja.zip -d "${dest}/bin"; \
    # mold 3.x is written in Rust and built with Cargo; use the official static release.
    curl -fsSL "https://github.com/rui314/mold/releases/download/v${MOLD_VERSION}/mold-${MOLD_VERSION}-${arch}-linux.tar.gz" \
      | tar -xz -C "${dest}" --strip-components=1 --wildcards '*/bin' '*/lib' '*/libexec'; \
    "${dest}/bin/cmake" --version; "${dest}/bin/ninja" --version; "${dest}/bin/mold" --version

######################## builder ########################
FROM base AS builder
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        gcc g++ make libc6-dev binutils \
        flex bzip2 file \
        curl ca-certificates \
        python3 \
        libzstd-dev && \
    rm -rf /var/lib/apt/lists/*
COPY --link --from=prebuilt /staging/usr/local/ /usr/local/

######################## GCC ########################
FROM builder AS gcc
ARG JOBS
ARG GCC_VERSION=16.2.0
ADD https://github.com/gcc-mirror/gcc.git#releases/gcc-${GCC_VERSION} /src/gcc
RUN set -eux; \
    major="${GCC_VERSION%%.*}"; \
    cd /src/gcc && ./contrib/download_prerequisites; \
    mkdir -p /build/gcc && cd /build/gcc; \
    /src/gcc/configure \
        --prefix=/usr/local \
        --program-suffix="-${major}" \
        --enable-languages=c,c++ \
        --enable-checking=release \
        --disable-multilib \
        --disable-nls; \
    make -j"${JOBS:-$(nproc)}" -l"$(nproc)"; \
    make install-strip DESTDIR=/staging; \
    rm -rf /staging/usr/local/share/info /staging/usr/local/share/man; \
    find /staging/usr/local -name '*.la' -delete; \
    # Unsuffixed names (gcc, g++, ...) for the -16 binaries.
    cd /staging/usr/local/bin; \
    for tool in gcc g++ cpp gcov gcov-dump gcov-tool gcc-ar gcc-nm gcc-ranlib lto-dump; do \
      if [ -e "${tool}-${major}" ]; then ln -sf "${tool}-${major}" "${tool}"; fi; \
    done
# Trim what a compile-only image doesn't need (kept as its own layer so changing this
# list doesn't rebuild GCC): lto-dump (~45MB LTO bytecode inspector), plugin
# development headers, and libcc1 (only used by GDB's `compile` command).
RUN rm -rf /staging/usr/local/bin/lto-dump* \
           /staging/usr/local/lib/gcc/*/*/plugin \
           /staging/usr/local/lib64/libcc1.so*

######################## LLVM ########################
FROM builder AS llvm
ARG JOBS

# Static, PIC zlib so libLLVM doesn't pick up a runtime dependency on the distro zlib-dev.
ARG ZLIB_VERSION=1.4
ADD https://github.com/madler/zlib.git#v${ZLIB_VERSION} /src/zlib
RUN cmake -S /src/zlib -B /build/zlib -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DZLIB_BUILD_SHARED=OFF \
        -DZLIB_BUILD_TESTING=OFF && \
    cmake --build /build/zlib --target install

ARG IWYU_VERSION=0.27
ADD https://github.com/include-what-you-use/include-what-you-use.git#${IWYU_VERSION} /src/iwyu
ARG LLVM_VERSION=23.1.6
ADD https://github.com/llvm/llvm-project.git#llvmorg-${LLVM_VERSION} /src/llvm-project
# SEE: https://github.com/dslm4515/CMLFS/issues/12
# https://github.com/llvm/llvm-project/commit/e0184357fc781e939f4e4368fc8aff692ce227ed
RUN sed -i '/check_library_exists(atomic __atomic_fetch_add_8 "" LIBCXX_HAS_ATOMIC_LIB)/d' \
    /src/llvm-project/libcxx/cmake/config-ix.cmake

# Executables that end up in the image. Everything links against the shared libLLVM and
# libclang-cpp, which keeps each tool small (static linking would cost ~100MB per tool).
ARG LLVM_TOOLS="clang lld clang-format clang-tidy clangd clang-scan-deps \
llvm-ar llvm-nm llvm-objcopy llvm-objdump llvm-symbolizer llvm-cov llvm-profdata llvm-cxxfilt"

# Step 1: configure and build the compiler and tools (the slow part).
RUN set -eux; \
    components="${LLVM_TOOLS} clang-resource-headers LLVM clang-cpp llvm-ranlib llvm-strip builtins runtimes"; \
    cmake -S /src/llvm-project/llvm -B /build/llvm -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DCMAKE_C_COMPILER=gcc \
        -DCMAKE_CXX_COMPILER=g++ \
        -DLLVM_USE_LINKER=mold \
        -DLLVM_PARALLEL_LINK_JOBS=2 \
        -DLLVM_ENABLE_PROJECTS="clang;clang-tools-extra;lld" \
        -DLLVM_ENABLE_RUNTIMES="libcxx;libcxxabi;libunwind;compiler-rt;openmp" \
        -DLLVM_EXTERNAL_PROJECTS=iwyu \
        -DLLVM_EXTERNAL_IWYU_SOURCE_DIR=/src/iwyu \
        `# Resolve the clang resource dir relative to the installed IWYU binary, not the build tree.` \
        -DIWYU_RESOURCE_RELATIVE_TO=iwyu \
        -DLLVM_TARGETS_TO_BUILD=host \
        -DLLVM_BUILD_LLVM_DYLIB=ON \
        -DLLVM_LINK_LLVM_DYLIB=ON \
        -DCLANG_LINK_CLANG_DYLIB=ON \
        -DLLVM_ENABLE_ZLIB=FORCE_ON \
        -DLLVM_ENABLE_ZSTD=FORCE_ON \
        -DLLVM_ENABLE_LIBXML2=OFF \
        -DLLVM_ENABLE_LIBEDIT=OFF \
        -DLLVM_ENABLE_LIBPFM=OFF \
        -DLLVM_INCLUDE_TESTS=OFF \
        -DLLVM_INCLUDE_BENCHMARKS=OFF \
        -DLLVM_INCLUDE_EXAMPLES=OFF \
        -DLLVM_INCLUDE_DOCS=OFF \
        -DCLANG_DEFAULT_LINKER=lld \
        -DCLANG_DEFAULT_CXX_STDLIB=libc++ \
        -DCLANG_DEFAULT_RTLIB=compiler-rt \
        -DCLANG_DEFAULT_UNWINDLIB=libunwind \
        -DLLVM_DISTRIBUTION_COMPONENTS="$(echo ${components} | tr ' ' ';')"; \
    ninja -C /build/llvm -j"${JOBS:-$(nproc)}" -l"$(nproc)" ${LLVM_TOOLS} include-what-you-use

# Step 2: configure the runtimes (built by the clang from step 1) and install. Runtime
# flags live here so tweaking them doesn't invalidate the step 1 layer.
RUN set -eux; \
    cmake -S /src/llvm-project/llvm -B /build/llvm \
        -DCOMPILER_RT_BUILD_BUILTINS=ON \
        -DCOMPILER_RT_USE_BUILTINS_LIBRARY=ON \
        -DCOMPILER_RT_USE_ATOMIC_LIBRARY=ON \
        -DCOMPILER_RT_BUILD_SANITIZERS=ON \
        `# Without this, compiler-rt probes each arch by linking a C++ test program. That fails here` \
        `# (clang defaults to libc++/libunwind, which aren't built yet), so compiler-rt silently` \
        `# decides it can't target x86_64/aarch64 and builds no sanitizers at all.` \
        -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON \
        `# lsan and ubsan are always built alongside these.` \
        -DCOMPILER_RT_SANITIZERS_TO_BUILD="asan;msan;tsan;rtsan;ubsan_minimal" \
        -DCOMPILER_RT_BUILD_LIBFUZZER=ON \
        -DCOMPILER_RT_BUILD_PROFILE=ON \
        -DCOMPILER_RT_BUILD_XRAY=OFF \
        -DCOMPILER_RT_BUILD_MEMPROF=OFF \
        -DCOMPILER_RT_BUILD_ORC=OFF \
        -DCOMPILER_RT_BUILD_CTX_PROFILE=OFF \
        -DCOMPILER_RT_BUILD_GWP_ASAN=OFF \
        -DCOMPILER_RT_USE_LLVM_UNWINDER=ON \
        -DSANITIZER_USE_STATIC_LLVM_UNWINDER=ON \
        -DLIBUNWIND_ENABLE_SHARED=OFF \
        -DLIBUNWIND_ENABLE_STATIC=ON \
        -DLIBUNWIND_USE_COMPILER_RT=ON \
        -DLIBCXXABI_ENABLE_SHARED=OFF \
        -DLIBCXXABI_ENABLE_STATIC=ON \
        -DLIBCXXABI_USE_COMPILER_RT=ON \
        -DLIBCXXABI_USE_LLVM_UNWINDER=ON \
        -DLIBCXXABI_ENABLE_STATIC_UNWINDER=ON \
        -DLIBCXX_ENABLE_SHARED=ON \
        -DLIBCXX_ENABLE_STATIC=OFF \
        -DLIBCXX_ENABLE_STATIC_ABI_LIBRARY=ON \
        -DLIBCXX_USE_COMPILER_RT=ON \
        -DLIBCXX_INSTALL_MODULES=ON \
        `# Suppress the implicit -l:libunwind.a that CLANG_DEFAULT_UNWINDLIB=libunwind injects into libomp.so. ` \
        `# libomp has no CMake dep on libunwind, so ninja can link libomp before libunwind.a is archived.` \
        -DLIBOMP_LDFLAGS=--unwindlib=none \
        `# Don't install libgomp.so/libiomp5.so aliases; they would shadow GCC's real libgomp.` \
        -DLIBOMP_INSTALL_ALIASES=OFF \
        `# libompd (debugger interface) and the OMPT tools (archer) are C++ libraries that link` \
        `# -lc++ with no CMake dependency on it, so they race the libc++ build. Not needed for -fopenmp.` \
        -DLIBOMP_OMPD_SUPPORT=OFF \
        -DOPENMP_ENABLE_OMPT_TOOLS=OFF; \
    DESTDIR=/staging ninja -C /build/llvm -j"${JOBS:-$(nproc)}" -l"$(nproc)" install-distribution-stripped; \
    # IWYU has no install component of its own; install the binary and mapping files by hand.
    install -D -m 0755 -s /build/llvm/bin/include-what-you-use /staging/usr/local/bin/include-what-you-use; \
    install -D -m 0644 -t /staging/usr/local/share/include-what-you-use /src/iwyu/*.imp

######################## Valgrind ########################
FROM builder AS valgrind
ARG JOBS
ARG VALGRIND_VERSION=3.28.0
ADD https://sourceware.org/pub/valgrind/valgrind-${VALGRIND_VERSION}.tar.bz2 /src/
RUN set -eux; \
    mkdir -p /build/valgrind; \
    tar -xjf /src/valgrind-${VALGRIND_VERSION}.tar.bz2 -C /build/valgrind --strip-components=1; \
    cd /build/valgrind; \
    ./configure --prefix=/usr/local; \
    make -j"${JOBS:-$(nproc)}" -l"$(nproc)"; \
    make install DESTDIR=/staging; \
    # Drop the static libs in lib/valgrind (~65MB, only needed to write new Valgrind
    # tools), docs and pkg-config.
    rm -rf /staging/usr/local/lib /staging/usr/local/share/man /staging/usr/local/share/doc; \
    # Strip debug info from the tool executables; leave the vgpreload_*.so objects alone.
    find /staging/usr/local/libexec/valgrind -type f -name '*-linux' -exec strip --strip-debug {} +

######################## Cppcheck ########################
FROM builder AS cppcheck
ARG JOBS
ARG CPPCHECK_VERSION=2.22.0
ADD https://github.com/danmar/cppcheck.git#${CPPCHECK_VERSION} /src/cppcheck
RUN set -eux; \
    cmake -S /src/cppcheck -B /build/cppcheck -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DBUILD_GUI=OFF \
        -DBUILD_TESTS=OFF \
        -DHAVE_RULES=OFF; \
    cmake --build /build/cppcheck -j"${JOBS:-$(nproc)}"; \
    DESTDIR=/staging cmake --install /build/cppcheck --strip

######################## dev (final image) ########################
FROM base AS dev
# binutils: as/ld for GCC. libc6-dev: libc headers and crt objects for both compilers.
# libc6-dbg: Ubuntu's ld.so is stripped, and Valgrind refuses to start without its
# symbols ("a function redirection which is mandatory ... cannot be set up").
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        binutils \
        libc6-dev \
        libc6-dbg \
        make \
        git \
        ca-certificates && \
    rm -rf /var/lib/apt/lists/*

COPY --link --from=prebuilt /staging/usr/local/ /usr/local/
COPY --link --from=gcc      /staging/usr/local/ /usr/local/
COPY --link --from=llvm     /staging/usr/local/ /usr/local/
COPY --link --from=valgrind /staging/usr/local/ /usr/local/
COPY --link --from=cppcheck /staging/usr/local/ /usr/local/

# Make the new runtimes resolvable without LD_LIBRARY_PATH:
#  - GCC's libstdc++/libgomp in /usr/local/lib64 must win over the distro's older copies.
#  - libc++/libomp live in clang's per-target runtime dir.
RUN set -eux; \
    echo /usr/local/lib64 > /etc/ld.so.conf.d/00-gcc.conf; \
    echo "/usr/local/lib/$(/usr/local/bin/clang -print-target-triple)" > /etc/ld.so.conf.d/01-llvm-runtimes.conf; \
    ldconfig; \
    ln -s clang   /usr/local/bin/cc; \
    ln -s clang++ /usr/local/bin/c++; \
    gcc --version; clang --version; cmake --version; cppcheck --version; valgrind --version

# Clang is the default compiler; override with CC=gcc CXX=g++ (or CMAKE_CXX_COMPILER).
ENV CC=/usr/local/bin/clang CXX=/usr/local/bin/clang++
CMD ["bash"]
