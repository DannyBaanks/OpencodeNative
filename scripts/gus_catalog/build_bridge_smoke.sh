#!/usr/bin/env bash
# Build the desktop bridge harness against a llama.cpp checkout that has been
# built as static libraries (cmake -DBUILD_SHARED_LIBS=OFF --target llama).
#   scripts/gus_catalog/build_bridge_smoke.sh <llama.cpp dir> [output]
set -euo pipefail
LLAMA="${1:?llama.cpp directory}"
OUT="${2:-build/bridge_smoke}"
HERE="$(cd "$(dirname "$0")" && pwd)"
SHIM="$(mktemp -d)"
trap 'rm -rf "$SHIM"' EXIT
# The app includes <llama/llama.h> (xcframework layout); mirror it.
mkdir -p "$SHIM/llama" "$(dirname "$OUT")"
ln -s "$LLAMA/include/llama.h" "$SHIM/llama/llama.h"
libs=("$LLAMA/build/src/libllama.a")
for lib in "$LLAMA"/build/ggml/src/libggml.a "$LLAMA"/build/ggml/src/libggml-cpu.a "$LLAMA"/build/ggml/src/libggml-base.a; do
  [ -f "$lib" ] && libs+=("$lib")
done
cc -std=c11 -O2 -Wall -Wextra -Werror -Wno-unused-parameter -D_GNU_SOURCE \
  -I"$SHIM" -I"$LLAMA/include" -I"$LLAMA/ggml/include" \
  "$HERE/bridge_smoke.c" -o "$OUT" \
  -Wl,--start-group "${libs[@]}" -Wl,--end-group -lstdc++ -lm -lpthread -fopenmp
echo "built $OUT"
