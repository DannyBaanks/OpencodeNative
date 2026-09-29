#!/usr/bin/env bash
set -euo pipefail

readonly LLAMA_REPOSITORY="https://github.com/ggml-org/llama.cpp.git"
readonly LLAMA_COMMIT="842b1880415d6f508f03b789e5ce70194def7bfd"
readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly BUILD_ROOT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/isycode-llama.cpp"
readonly OUTPUT_DIR="${ROOT_DIR}/.build/llama"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This framework must be built by macOS/Xcode; no local fallback is supported." >&2
  exit 2
fi
command -v cmake >/dev/null || { echo "cmake 3.28+ is required" >&2; exit 2; }
command -v xcrun >/dev/null || { echo "Xcode Command Line Tools are required" >&2; exit 2; }

rm -rf "${BUILD_ROOT}"
git clone --filter=blob:none --no-checkout "${LLAMA_REPOSITORY}" "${BUILD_ROOT}"
git -C "${BUILD_ROOT}" checkout --detach "${LLAMA_COMMIT}"
actual="$(git -C "${BUILD_ROOT}" rev-parse HEAD)"
[[ "${actual}" == "${LLAMA_COMMIT}" ]] || { echo "Unexpected llama.cpp revision: ${actual}" >&2; exit 1; }

cd "${BUILD_ROOT}"
./build-xcframework.sh ios-device ios-sim
mkdir -p "${OUTPUT_DIR}"
rm -rf "${OUTPUT_DIR}/llama.xcframework"
cp -R build-apple/llama.xcframework "${OUTPUT_DIR}/llama.xcframework"
printf '%s\n' "${actual}" > "${OUTPUT_DIR}/SOURCE_COMMIT"
test -d "${OUTPUT_DIR}/llama.xcframework"
