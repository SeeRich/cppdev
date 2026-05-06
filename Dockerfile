FROM ubuntu:24.04

# TODO: CONVERT TO MULTI-STAGE BUILD

RUN apt-get update && apt-get upgrade -y && apt-get install -y \
    gcc \
    g++ \
    make \
    libc6-dev \
    binutils \
    binutils-dev \
    git \
    zstd \
    bzip2 \
    autoconf \
    automake \
    libtool \
    python3 \
    python3-pip \
    python3-venv && \
    rm -rf /var/lib/apt/lists/*

# Use python to install common c++ tools inside venv
RUN python3 -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"
RUN python3 -m pip install -U pip && \
    python3 -m pip install cmake==4.3.1 ninja==1.13.0 conan==2.27.1

# Build static zlib
ARG ZLIB_VERSION=1.3.2
ADD https://github.com/madler/zlib.git#v${ZLIB_VERSION} /tmp/zlib
RUN cd /tmp/zlib && \
    cmake -B build -S . -G Ninja \
        -DCMAKE_INSTALL_PREFIX=/usr \
        -DZLIB_BUILD_SHARED=OFF \
        -DZLIB_BUILD_TESTING=OFF \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DCMAKE_INSTALL_LIBDIR=lib && \
    cmake --build build --config Release --target install --verbose && \
    rm -rf /tmp/zlib

######################## GCC ########################
# Build and install GCC 15.x from source to get the most updated libstdc++
RUN apt update && apt install -y \
    libgmp-dev \
    libmpfr-dev \
    libmpc-dev \
    libisl-dev \
    libzstd-dev \
    flex \
    curl && \
    rm -rf /var/lib/apt/lists/*
ARG GCC_VERSION="releases/gcc-16.1.0"
ARG GCC_MAJOR_VER="16"
ADD https://github.com/gcc-mirror/gcc.git#${GCC_VERSION} /tmp/gcc-${GCC_VERSION}
RUN cd /tmp/gcc-${GCC_VERSION} && \
    ./contrib/download_prerequisites && \
    mkdir -p build && \
    cd build && \
    ../configure --disable-multilib --enable-languages=c,c++,fortran --enable-checking=release --prefix=/usr/local --program-suffix=-${GCC_MAJOR_VER} && \
    make -j$(nproc) && \
    make install && \
    rm -rf /tmp/gcc-${GCC_VERSION}
# Add updated libstdc++ directory to ldconf so libstdc++.so.6 resolves to /usr/local/lib64
RUN echo "/usr/local/lib64" >> /etc/ld.so.conf.d/gcc.conf && ldconfig
# Ensure the new gcc libs are picked up at runtime
ENV LD_LIBRARY_PATH=/usr/local/lib64
# Symbolic link gcc and g++ so they are found first on the path
RUN ln -s /usr/local/bin/gcc-${GCC_MAJOR_VER} /usr/local/bin/gcc && \
    ln -s /usr/local/bin/g++-${GCC_MAJOR_VER} /usr/local/bin/g++ && \
    ln -s /usr/local/bin/gfortran-${GCC_MAJOR_VER} /usr/local/bin/gfortran
# Update alternatives for gcc, g++, and gfortran
RUN update-alternatives --install /usr/bin/gcc gcc /usr/local/bin/gcc 100 \
    --slave /usr/bin/g++ g++ /usr/local/bin/g++ \
    --slave /usr/bin/gfortran gfortran /usr/local/bin/gfortran

# Purge the distro toolchain now that the source-built GCC and LLVM are installed.
# Keep libstdc++6 (runtime) since dpkg/apt/git depend on it; ldconfig below
# points libstdc++.so.6 resolution at /usr/local/lib64.
RUN apt-get purge -y --auto-remove \
    gcc g++ cpp \
    gcc-13 g++-13 cpp-13 \
    libgcc-13-dev libstdc++-13-dev && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

######################## LLVM ########################
# IWYU (include-what-you-use)
ARG IWYU_VERSION=clang_22
ADD https://github.com/include-what-you-use/include-what-you-use.git#${IWYU_VERSION} /tmp/include-what-you-use

ARG LLVM_VERSION=22.1.4
ADD https://github.com/llvm/llvm-project.git#llvmorg-${LLVM_VERSION} /tmp/llvm-project
# SEE: https://github.com/dslm4515/CMLFS/issues/12
# https://github.com/llvm/llvm-project/commit/e0184357fc781e939f4e4368fc8aff692ce227ed
RUN sed -i '/check_library_exists(atomic __atomic_fetch_add_8 "" LIBCXX_HAS_ATOMIC_LIB)/d' \
    /tmp/llvm-project/libcxx/cmake/config-ix.cmake
RUN cd /tmp/llvm-project && \
    cmake -B build -S llvm -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DLLVM_ENABLE_PROJECTS="clang;clang-tools-extra;lld;lldb;flang" \
        -DLLVM_ENABLE_RUNTIMES="libcxx;libcxxabi;libunwind;compiler-rt;flang-rt;openmp" \
        -DLLVM_ENABLE_ZSTD=ON \
        -DLLVM_ENABLE_ZLIB=ON \
        -DLLVM_EXTERNAL_PROJECTS=iwyu \
        -DLLVM_EXTERNAL_IWYU_SOURCE_DIR=/tmp/include-what-you-use \
        -DCMAKE_PREFIX_PATH=/usr/lib \
        -DCOMPILER_RT_BUILD_BUILTINS=ON \
        -DCOMPILER_RT_USE_BUILTINS_LIBRARY=ON \
        -DCOMPILER_RT_USE_ATOMIC_LIBRARY=ON \
        -DCOMPILER_RT_BUILD_SANITIZERS=ON \
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
        -DCLANG_DEFAULT_LINKER=lld \
        -DCLANG_DEFAULT_CXX_STDLIB=libc++ \
        -DCLANG_DEFAULT_RTLIB=compiler-rt \
        -DCLANG_DEFAULT_UNWINDLIB=libunwind \
        -DLLVM_BINUTILS_INCDIR=/usr/include \
        -DLLVM_TARGETS_TO_BUILD=host \
        -DLLVM_INCLUDE_DOCS=OFF \
        -DLLVM_INCLUDE_TESTS=OFF && \
    cmake --build build --target install --parallel && \
    rm -rf /tmp/llvm-project
# Put libc++ on the LD_LIBRARY_PATH
ENV LD_LIBRARY_PATH=/usr/local/lib/aarch64-unknown-linux-gnu:$LD_LIBRARY_PATH
# Update alternatives for clang, clang++, clang-format, clang-tidy, run-clang-tidy, and include-what-you-use
RUN update-alternatives --install /usr/bin/clang clang /usr/local/bin/clang 100 \
    --slave /usr/bin/clang++ clang++ /usr/local/bin/clang++ \
    --slave /usr/bin/flang flang /usr/local/bin/flang \
    --slave /usr/bin/clang-format clang-format /usr/local/bin/clang-format \
    --slave /usr/bin/clang-tidy clang-tidy /usr/local/bin/clang-tidy \
    --slave /usr/bin/run-clang-tidy run-clang-tidy /usr/local/bin/run-clang-tidy \
    --slave /usr/bin/include-what-you-use include-what-you-use /usr/local/bin/include-what-you-use

# Default to using clang compiler (we build tools using this)
ENV CC=/usr/local/bin/clang CXX=/usr/local/bin/clang++ FC=/usr/local/bin/flang
# OR GCC
# ENV CC=/usr/local/bin/gcc CXX=/usr/local/bin/g++ FC=/usr/local/bin/gfortran

# Valgrind
ARG VALGRIND_VERSION="3.26.0"
ADD https://sourceware.org/pub/valgrind/valgrind-${VALGRIND_VERSION}.tar.bz2 /tmp/valgrind-${VALGRIND_VERSION}.tar.bz2    
RUN cd /tmp && \
    mkdir valgrind && \
    tar -xjf valgrind-${VALGRIND_VERSION}.tar.bz2 -C valgrind --strip-components=1 && \
    cd valgrind && \
    ./autogen.sh && \
    ./configure && \
    make -j$(nproc) && \
    make install && \
    rm -rf /tmp/valgrind

# CppCheck
ARG CPPCHECK_VERSION=2.20.0
ADD https://github.com/danmar/cppcheck.git#${CPPCHECK_VERSION} /tmp/cppcheck
RUN cd /tmp/cppcheck && \
    cmake -B build -S . -DCMAKE_BUILD_TYPE=Release -G Ninja && \
    cmake --build build --parallel && \
    cmake --install build && \
    cd .. && \
    rm -rf cppcheck

# Mold Linker
ARG MOLD_VERSION=2.41.0
ADD https://github.com/rui314/mold.git#v${MOLD_VERSION} /tmp/mold
RUN cd /tmp/mold && \
    cmake -DCMAKE_BUILD_TYPE=Release -S . -B build -G Ninja && \
    cmake --build build --parallel && \
    cmake --install build && \
    cd .. && \
    rm -rf mold