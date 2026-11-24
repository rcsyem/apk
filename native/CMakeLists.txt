# Shared by (a) the Android Gradle build and (b) the standalone PoC script.
cmake_minimum_required(VERSION 3.22)
project(lai_bridge LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(LLAMA_DIR "${CMAKE_CURRENT_LIST_DIR}/../third_party/llama.cpp" CACHE PATH "llama.cpp checkout")
if(NOT EXISTS "${LLAMA_DIR}/CMakeLists.txt")
  message(FATAL_ERROR "llama.cpp not found at ${LLAMA_DIR}. See third_party/README.md")
endif()

# Baseline ARM64 by default. CPU-specific flags are strictly opt-in, because a
# forced -march can crash (SIGILL) on devices lacking those extensions.
set(LAI_EXTRA_ARCH_FLAGS "" CACHE STRING "Optional extra C/C++ arch flags, e.g. -march=armv8.2-a+dotprod")
if(LAI_EXTRA_ARCH_FLAGS)
  add_compile_options(${LAI_EXTRA_ARCH_FLAGS})
endif()

# CPU only. No Vulkan/OpenCL/CUDA. No curl. No tests/examples/server.
set(GGML_VULKAN OFF CACHE BOOL "" FORCE)
set(GGML_OPENCL OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)
# llama.cpp v1.0.0: LLAMA_CURL no longer exists; HTTPS support is LLAMA_OPENSSL (default ON).
# We only need libllama (no common/tools/server/app), so everything optional is OFF.
set(LLAMA_OPENSSL OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_COMMON OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TOOLS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_SERVER OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_APP OFF CACHE BOOL "" FORCE)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
# libllama/ggml are static and get linked into the SHARED liblai_bridge.so: they must be PIC
# (found by the real host link: "relocation R_X86_64_PC32 ... recompile with -fPIC").
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

add_subdirectory("${LLAMA_DIR}" llama_build)

add_library(lai_bridge SHARED src/lai_bridge.cpp)
target_include_directories(lai_bridge PUBLIC include PRIVATE src)
target_link_libraries(lai_bridge PRIVATE llama)
set_target_properties(lai_bridge PROPERTIES CXX_VISIBILITY_PRESET hidden)
# Static libllama/ggml are not built with hidden visibility: stop their symbols leaking out of the .so
# (observed with `nm -D`: thousands of llama/ggml internals exported). Keeps only lai_* public.
if(NOT APPLE)
  target_link_options(lai_bridge PRIVATE -Wl,--exclude-libs,ALL
                      -Wl,--version-script=${CMAKE_CURRENT_SOURCE_DIR}/lai_exports.map)
  set_target_properties(lai_bridge PROPERTIES LINK_DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/lai_exports.map)
endif()
if(ANDROID)
  # Android 15+ devices with 16 KB pages (unverified here; needs a real build).
  target_link_options(lai_bridge PRIVATE -Wl,-z,max-page-size=16384)
endif()

option(LAI_BUILD_POC "Build standalone PoC executable" OFF)
if(LAI_BUILD_POC)
  add_executable(lai_poc poc/poc_main.cpp)
  target_link_libraries(lai_poc PRIVATE lai_bridge)
  add_executable(lai_real_test tests/real_engine_test.cpp)
  target_link_libraries(lai_real_test PRIVATE lai_bridge)
endif()
