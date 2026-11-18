#!/usr/bin/env bash
# Build, test and run this C++26 example with GCC and Clang inside the cppdev image.
#
#   ./run.sh                              # all presets: gcc, clang, clang-asan
#   ./run.sh gcc                          # just the given presets
#   CPPDEV_IMAGE=cppdev:latest ./run.sh   # use a locally built image
#   PULL=always ./run.sh                  # pull the newest image before running
#
# Each preset runs a CMake workflow (configure, build, ctest), then runs the binary.
# The ctest step covers the program itself, valgrind memcheck and cppcheck.
set -euo pipefail

image="${CPPDEV_IMAGE:-seerich/cppdev:latest}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
presets=("$@")
if [[ ${#presets[@]} -eq 0 ]]; then
  presets=(gcc clang clang-asan)
fi

# --pull=missing (the default) pulls the image only if it isn't present locally.
docker run --rm --pull="${PULL:-missing}" \
  --user "$(id -u):$(id -g)" -e HOME=/tmp \
  -v "${here}:/src" -w /src \
  "${image}" \
  bash -euo pipefail -c '
    for preset in "$@"; do
      printf "\n========== %s ==========\n" "${preset}"
      cmake --workflow --preset "${preset}" --fresh
      printf "\n---------- ./build/%s/cpp26_demo ----------\n" "${preset}"
      "./build/${preset}/cpp26_demo"
    done
  ' bash "${presets[@]}"
