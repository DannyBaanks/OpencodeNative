# Native side of iSyCode Móvil for Android.
#
# It compiles the SAME C files the iOS app ships (Sources/Model/GUSLlamaBridge.c
# and Sources/Diagnostics/GUSSignalTrap.c) against llama.cpp pinned to the same
# commit as scripts/build-llama-xcframework.sh, plus a thin JNI layer.
cmake_minimum_required(VERSION 3.22.1)
project(gus_android C CXX)

set(REPO_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../../../../..")
file(READ "${REPO_ROOT}/scripts/build-llama-xcframework.sh" _build_script)
string(REGEX MATCH "LLAMA_COMMIT=\"([0-9a-f]+)\"" _m "${_build_script}")
set(LLAMA_COMMIT "${CMAKE_MATCH_1}")
if(NOT LLAMA_COMMIT)
  message(FATAL_ERROR "Could not read LLAMA_COMMIT from build-llama-xcframework.sh")
endif()
message(STATUS "llama.cpp commit: ${LLAMA_COMMIT}")

include(FetchContent)
set(LLAMA_BUILD_COMMON OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_SERVER OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TOOLS OFF CACHE BOOL "" FORCE)
set(LLAMA_CURL OFF CACHE BOOL "" FORCE)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
# No libomp on Android; ggml falls back to its own thread pool.
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)
# (No DOWNLOAD_EXTRACT_TIMESTAMP: the SDK's CMake 3.22 predates it.)
FetchContent_Declare(llama
  URL "https://github.com/ggml-org/llama.cpp/archive/${LLAMA_COMMIT}.tar.gz")
FetchContent_MakeAvailable(llama)

# The bridge includes <llama/llama.h> (xcframework layout); mirror it.
configure_file("${llama_SOURCE_DIR}/include/llama.h" "${CMAKE_BINARY_DIR}/shim/llama/llama.h" COPYONLY)

add_library(gus_jni SHARED
  gus_jni.c
  "${REPO_ROOT}/Sources/Model/GUSLlamaBridge.c"
  "${REPO_ROOT}/Sources/Diagnostics/GUSSignalTrap.c")
target_include_directories(gus_jni PRIVATE
  "${CMAKE_BINARY_DIR}/shim"
  "${REPO_ROOT}/Sources/Model"
  "${REPO_ROOT}/Sources/Diagnostics")
target_compile_options(gus_jni PRIVATE -O2 -Wall)
target_link_libraries(gus_jni PRIVATE llama log android)
# 16 KB page alignment (required by newer Android releases for native libs).
target_link_options(gus_jni PRIVATE "-Wl,-z,max-page-size=16384")
