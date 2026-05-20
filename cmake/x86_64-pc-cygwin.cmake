# =============================================================================
# cmake/x86_64-pc-cygwin.cmake
#
# CMake toolchain file for cross-compiling to Cygwin with llvm-cygwin.
#
# Usage:
#   cmake -B build \
#     -DCMAKE_TOOLCHAIN_FILE=/path/to/llvm-cygwin/cmake/x86_64-pc-cygwin.cmake \
#     -S .
# =============================================================================

set(CMAKE_SYSTEM_NAME       Cygwin)
set(CMAKE_SYSTEM_VERSION    1)
set(CMAKE_SYSTEM_PROCESSOR  x86_64)

# --- Toolchain prefix (adjust to match your install location) ---
set(LLVM_CYGWIN_ROOT "$ENV{LLVM_CYGWIN_ROOT}" CACHE PATH "llvm-cygwin installation prefix")
if(NOT LLVM_CYGWIN_ROOT)
    message(FATAL_ERROR "Set LLVM_CYGWIN_ROOT to the llvm-cygwin install prefix, e.g. /opt/llvm-cygwin")
endif()

# --- Sysroot (Cygwin headers + libs) ---
set(CYGWIN_SYSROOT "$ENV{CYGWIN_SYSROOT}" CACHE PATH "Cygwin sysroot path")
if(NOT CYGWIN_SYSROOT)
    message(FATAL_ERROR "Set CYGWIN_SYSROOT to the Cygwin sysroot, e.g. /opt/cygwin-sysroot")
endif()

set(CMAKE_SYSROOT "${CYGWIN_SYSROOT}")

# --- Compilers ---
set(CMAKE_C_COMPILER            "${LLVM_CYGWIN_ROOT}/bin/clang")
set(CMAKE_CXX_COMPILER          "${LLVM_CYGWIN_ROOT}/bin/clang++")
set(CMAKE_ASM_COMPILER          "${LLVM_CYGWIN_ROOT}/bin/clang")
set(CMAKE_AR                    "${LLVM_CYGWIN_ROOT}/bin/llvm-ar"   CACHE FILEPATH "archiver")
set(CMAKE_RANLIB                "${LLVM_CYGWIN_ROOT}/bin/llvm-ranlib" CACHE FILEPATH "ranlib")
set(CMAKE_NM                    "${LLVM_CYGWIN_ROOT}/bin/llvm-nm"   CACHE FILEPATH "nm")
set(CMAKE_OBJCOPY               "${LLVM_CYGWIN_ROOT}/bin/llvm-objcopy" CACHE FILEPATH "objcopy")
set(CMAKE_OBJDUMP               "${LLVM_CYGWIN_ROOT}/bin/llvm-objdump" CACHE FILEPATH "objdump")
set(CMAKE_STRIP                 "${LLVM_CYGWIN_ROOT}/bin/llvm-strip" CACHE FILEPATH "strip")

# --- Linker ---
set(CMAKE_LINKER                "${LLVM_CYGWIN_ROOT}/bin/ld.lld"    CACHE FILEPATH "linker")

# --- Target flags ---
set(CMAKE_C_FLAGS_INIT           "--target=x86_64-pc-cygwin --sysroot=${CYGWIN_SYSROOT}" CACHE STRING "C flags")
set(CMAKE_CXX_FLAGS_INIT         "--target=x86_64-pc-cygwin --sysroot=${CYGWIN_SYSROOT}" CACHE STRING "CXX flags")
set(CMAKE_ASM_FLAGS_INIT         "--target=x86_64-pc-cygwin --sysroot=${CYGWIN_SYSROOT}" CACHE STRING "ASM flags")
set(CMAKE_EXE_LINKER_FLAGS_INIT  "-fuse-ld=lld --sysroot=${CYGWIN_SYSROOT}" CACHE STRING "linker flags")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "-fuse-ld=lld --sysroot=${CYGWIN_SYSROOT}" CACHE STRING "shared linker flags")
set(CMAKE_MODULE_LINKER_FLAGS_INIT "-fuse-ld=lld --sysroot=${CYGWIN_SYSROOT}" CACHE STRING "module linker flags")

# --- Find root paths ---
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

# --- Pkg-config ---
set(PKG_CONFIG_EXECUTABLE "${LLVM_CYGWIN_ROOT}/bin/${triple}-pkg-config" CACHE FILEPATH "pkg-config")
