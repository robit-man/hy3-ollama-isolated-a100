#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
LLAMA_CPP_DIR="${LLAMA_CPP_DIR:-${REPO_DIR}/../llama.cpp}"
LLAMA_CPP_REPO="${LLAMA_CPP_REPO:-https://github.com/satindergrewal/llama.cpp.git}"
LLAMA_CPP_BRANCH="${LLAMA_CPP_BRANCH:-hy3-mtp}"
BUILD_DIR="${LLAMA_BUILD_DIR:-${LLAMA_CPP_DIR}/build}"
BUILD_JOBS="${BUILD_JOBS:-$(nproc)}"
UPDATE_SOURCE="${UPDATE_SOURCE:-0}"
CUDA_ARCHITECTURES="${CUDA_ARCHITECTURES:-80}"
REQUIRE_NCCL="${REQUIRE_NCCL:-0}"

if ! command -v cmake >/dev/null 2>&1; then
  echo "ERROR: cmake is required"
  exit 1
fi
if ! command -v nvcc >/dev/null 2>&1; then
  echo "ERROR: nvcc is required for the CUDA build"
  exit 1
fi

if [[ ! -d "${LLAMA_CPP_DIR}/.git" ]]; then
  mkdir -p "$(dirname "$LLAMA_CPP_DIR")"
  git clone --branch "$LLAMA_CPP_BRANCH" --depth 5 "$LLAMA_CPP_REPO" "$LLAMA_CPP_DIR"
elif [[ "$UPDATE_SOURCE" == "1" ]]; then
  git -C "$LLAMA_CPP_DIR" fetch origin "$LLAMA_CPP_BRANCH"
  git -C "$LLAMA_CPP_DIR" checkout "$LLAMA_CPP_BRANCH"
  git -C "$LLAMA_CPP_DIR" pull --ff-only origin "$LLAMA_CPP_BRANCH"
fi

if [[ -n "$(git -C "$LLAMA_CPP_DIR" status --short)" ]]; then
  echo "ERROR: ${LLAMA_CPP_DIR} has uncommitted changes; refusing to reconfigure it."
  git -C "$LLAMA_CPP_DIR" status --short
  exit 1
fi

cmake -S "$LLAMA_CPP_DIR" -B "$BUILD_DIR" \
  -DGGML_CUDA=ON \
  -DGGML_CUDA_NCCL=ON \
  -DGGML_CUDA_FA_ALL_QUANTS=ON \
  -DGGML_CUDA_GRAPHS=ON \
  -DCMAKE_CUDA_ARCHITECTURES="$CUDA_ARCHITECTURES" \
  -DCMAKE_BUILD_TYPE=Release

cmake --build "$BUILD_DIR" --target llama-server llama-bench -j"$BUILD_JOBS"

if ! rg -q '^GGML_CUDA_FA_ALL_QUANTS:BOOL=ON$' "${BUILD_DIR}/CMakeCache.txt"; then
  echo "ERROR: build cache did not enable GGML_CUDA_FA_ALL_QUANTS=ON"
  exit 1
fi
if ! rg -q '^GGML_CUDA_NCCL:BOOL=ON$' "${BUILD_DIR}/CMakeCache.txt"; then
  echo "ERROR: build cache did not enable GGML_CUDA_NCCL=ON"
  exit 1
fi

NCCL_STATUS=available
if rg -q 'NCCL_(LIBRARY|INCLUDE_DIR):.*NOTFOUND' "${BUILD_DIR}/CMakeCache.txt"; then
  NCCL_STATUS=missing
fi
if [[ "$REQUIRE_NCCL" == "1" && "$NCCL_STATUS" != "available" ]]; then
  echo "ERROR: NCCL was required but CMake could not find its library and headers"
  exit 1
fi

echo "Hy3 llama.cpp build ready:"
echo "  source: ${LLAMA_CPP_DIR}"
echo "  branch: ${LLAMA_CPP_BRANCH}"
echo "  server: ${BUILD_DIR}/bin/llama-server"
echo "  bench: ${BUILD_DIR}/bin/llama-bench"
echo "  FA_ALL_QUANTS: ON"
echo "  NCCL option: ON"
echo "  NCCL detected: ${NCCL_STATUS}"
echo "  CUDA architecture: ${CUDA_ARCHITECTURES}"
