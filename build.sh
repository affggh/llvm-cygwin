#!/bin/bash
# =============================================================================
# build.sh — All-in-one build script for llvm-cygwin cross-compiler toolchain
# =============================================================================
# Usage:
#   ./build.sh                    # Full build + package
#   ./build.sh --build-only       # Build only, don't package
#   ./build.sh --package-only     # Package existing toolchain
#
# Quick start (first time):
#   1. ./scripts/fetch-patches.sh
#   2. ./scripts/fetch-sysroot.sh
#   3. ./build.sh
#
# Environment:
#   JOBS         Parallel build jobs (default: nproc)
#   PROXY        HTTP proxy (default: http://127.0.0.1:7897)
#   SKIP_CLONE   Skip LLVM clone step (for dev iteration)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"

PATCH_DIR="$PROJECT_DIR/patches"
INSTALL_PREFIX="$PROJECT_DIR/toolchain"
SYSROOT="$PROJECT_DIR/sysroot"
BUILD_DIR="$PROJECT_DIR/build"
JOBS="${JOBS:-$(nproc)}"
LLVM_VERSION="20.1.8"
# PROXY: set to empty string to disable (e.g. in CI)
PROXY="${PROXY-http://127.0.0.1:7897}"

TRIPLE="x86_64-pc-cygwin"
GCCVER=13

PACKAGE_NAME="llvm-cygwin-${LLVM_VERSION}-x86_64-linux"
PACKAGE_FILE="${PACKAGE_NAME}.tar.xz"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
step() { echo -e "\n${GREEN}=== $1 ===${NC}"; }
info() { echo -e "${YELLOW}  $1${NC}"; }
err()  { echo -e "${RED}ERROR: $1${NC}" >&2; }

# =============================================================================
# Pre-flight checks
# =============================================================================
check_prereqs() {
    local missing=0
    for tool in cmake ninja git wget gcc g++; do
        if ! command -v "$tool" &>/dev/null; then
            err "Missing: $tool"
            missing=1
        fi
    done
    if [ "$missing" -eq 1 ]; then
        err "Install the missing tools and try again."
        exit 1
    fi
    info "All build tools found."

    if [ ! -d "$SYSROOT/usr/include" ]; then
        err "Sysroot not found at $SYSROOT"
        err "Run: ./scripts/fetch-sysroot.sh"
        exit 1
    fi
}

# =============================================================================
# Clone LLVM
# =============================================================================
clone_llvm() {
    step "Step 1: Clone LLVM ${LLVM_VERSION}"

    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"

    if [ -d llvm-project ]; then
        if [ "${SKIP_CLONE:-0}" = "1" ]; then
            info "SKIP_CLONE=1, using existing llvm-project"
            return
        fi
        info "Removing existing llvm-project..."
        rm -rf llvm-project
    fi

    if [ -n "$PROXY" ]; then
        info "Cloning via proxy ${PROXY}..."
        export http_proxy="$PROXY"
        export https_proxy="$PROXY"
    else
        info "Cloning directly (no proxy)..."
    fi
    git clone --depth 1 --branch "llvmorg-${LLVM_VERSION}" \
        https://github.com/llvm/llvm-project.git
}

# =============================================================================
# Apply patches
# =============================================================================
apply_patches() {
    step "Step 2: Apply Patches"

    cd "$BUILD_DIR/llvm-project"

    apply_patch_dir() {
        local dir="$1"
        local label="$2"
        local patch_d="$PATCH_DIR/$dir"

        if [ ! -d "$patch_d" ] || [ -z "$(ls -A "$patch_d"/*.patch 2>/dev/null)" ]; then
            info "No ${label} patches found, skipping"
            return
        fi

        info "Applying ${label} patches..."
        for patch in "$patch_d"/*.patch; do
            local pname
            pname="$(basename "$patch")"
            echo -n "    $pname ... "
            if patch -p1 -N --batch --dry-run < "$patch" 2>/dev/null; then
                patch -p1 -N --batch < "$patch" >/dev/null 2>&1
                echo "OK"
            elif patch -p2 -N --batch --dry-run < "$patch" 2>/dev/null; then
                patch -p2 -N --batch < "$patch" >/dev/null 2>&1
                echo "OK (p2)"
            else
                echo "skipped (already applied)"
            fi
        done
    }

    # Main patches (from Cygwin official repos, fetched via fetch-patches.sh)
    apply_patch_dir "llvm" "LLVM"
    apply_patch_dir "clang" "Clang"
    apply_patch_dir "lld"  "LLD"

    # Subproject patches — need to apply from within the subdirectory
    # because Cygwin patches use origsrc/libunwind-X.Y.Z.src/src/... paths
    # that map to subdir/src/... when -p2 is applied inside the subdir.
    apply_subdir_patch() {
        local subdir="$1"
        local label="$2"
        local patch_d="$PATCH_DIR/$subdir"

        if [ ! -d "$patch_d" ] || [ -z "$(ls -A "$patch_d"/*.patch 2>/dev/null)" ]; then
            info "No ${label} patches found, skipping"
            return
        fi

        if [ ! -d "$BUILD_DIR/llvm-project/$subdir" ]; then
            info "${label} subdirectory not found, skipping"
            return
        fi

        info "Applying ${label} patches..."
        pushd "$BUILD_DIR/llvm-project/$subdir" > /dev/null
        for patch in "$patch_d"/*.patch; do
            local pname
            pname="$(basename "$patch")"
            echo -n "    $pname ... "
            if patch -p2 -N --batch --dry-run < "$patch" 2>/dev/null; then
                patch -p2 -N --batch < "$patch" >/dev/null 2>&1
                echo "OK"
            elif patch -p1 -N --batch --dry-run < "$patch" 2>/dev/null; then
                patch -p1 -N --batch < "$patch" >/dev/null 2>&1
                echo "OK (p1)"
            else
                echo "skipped"
            fi
        done
        popd > /dev/null
    }

    apply_subdir_patch "libunwind" "libunwind"
    apply_subdir_patch "libcxxabi" "libcxxabi"
    apply_subdir_patch "libcxx"    "libcxx"
    apply_subdir_patch "compiler-rt" "compiler-rt"

    # Our custom patches (e.g. direct lld linker)
    apply_patch_dir "custom" "Custom"
}

# =============================================================================
# Build LLVM/Clang/LLD
# =============================================================================
build_llvm() {
    step "Step 3: Configure LLVM"

    cd "$BUILD_DIR"
    rm -rf llvm-build

    cmake -G Ninja \
        -S llvm-project/llvm \
        -B llvm-build \
        -DCMAKE_BUILD_TYPE=Release \
        -DLLVM_ENABLE_PROJECTS="clang;lld" \
        -DLLVM_TARGETS_TO_BUILD=X86 \
        -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX" \
        -DLLVM_INSTALL_TOOLCHAIN_ONLY=ON \
        -DLLVM_ENABLE_ASSERTIONS=OFF \
        -DLLVM_OPTIMIZED_TABLEGEN=ON \
        -DLLVM_DEFAULT_TARGET_TRIPLE=x86_64-pc-windows-cygnus \
        -DDEFAULT_SYSROOT="$SYSROOT" \
        -DLLVM_ENABLE_THREADS=ON \
        -DLLVM_ENABLE_LLD=ON \
        -DCLANG_DEFAULT_LINKER=lld

    step "Step 4: Build LLVM (${JOBS} jobs)"
    ninja -C llvm-build -j"$JOBS"

    step "Step 5: Install to $INSTALL_PREFIX"
    rm -rf "$INSTALL_PREFIX"
    ninja -C llvm-build install
}

# =============================================================================
# Build libc++ / libc++abi / libunwind for Cygwin target
# =============================================================================
build_runtimes() {
    step "Step 6: Build libc++ + libc++abi + libunwind for Cygwin"

    local RT_BUILD="$BUILD_DIR/runtime-build"
    rm -rf "$RT_BUILD"

    cat > "$BUILD_DIR/toolchain-cygwin.cmake" << 'TCEOF'
set(CMAKE_SYSTEM_NAME Cygwin)
set(CMAKE_SYSTEM_PROCESSOR x86_64)
set(triple x86_64-pc-cygwin)

set(CMAKE_C_COMPILER @CC@)
set(CMAKE_CXX_COMPILER @CXX@)
set(CMAKE_C_COMPILER_TARGET ${triple})
set(CMAKE_CXX_COMPILER_TARGET ${triple})
set(CMAKE_SYSROOT @SYSROOT@)

set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)

set(CMAKE_C_FLAGS "-fuse-ld=lld" CACHE STRING "")
set(CMAKE_CXX_FLAGS "-fuse-ld=lld" CACHE STRING "")
set(CMAKE_EXE_LINKER_FLAGS "-fuse-ld=lld" CACHE STRING "")
set(CMAKE_SHARED_LINKER_FLAGS "-fuse-ld=lld" CACHE STRING "")

set(UNIX 1 CACHE BOOL "")
set(LLVM_ON_UNIX 1 CACHE BOOL "")
set(LLVM_ON_WIN32 0 CACHE BOOL "")
TCEOF

    sed -i "s|@CC@|$INSTALL_PREFIX/bin/clang|g"     "$BUILD_DIR/toolchain-cygwin.cmake"
    sed -i "s|@CXX@|$INSTALL_PREFIX/bin/clang++|g"   "$BUILD_DIR/toolchain-cygwin.cmake"
    sed -i "s|@SYSROOT@|$SYSROOT|g"                  "$BUILD_DIR/toolchain-cygwin.cmake"

    cmake -G Ninja \
        -S "$BUILD_DIR/llvm-project/runtimes" \
        -B "$RT_BUILD" \
        -DCMAKE_TOOLCHAIN_FILE="$BUILD_DIR/toolchain-cygwin.cmake" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$SYSROOT/usr" \
        -DLLVM_ENABLE_RUNTIMES="libcxx;libcxxabi;libunwind" \
        -DLLVM_DEFAULT_TARGET_TRIPLE="$TRIPLE" \
        -DLIBCXX_ENABLE_STATIC=ON \
        -DLIBCXX_ENABLE_SHARED=OFF \
        -DLIBCXX_ENABLE_STATIC_ABI_LIBRARY=ON \
        -DLIBCXXABI_ENABLE_STATIC=ON \
        -DLIBCXXABI_ENABLE_SHARED=OFF \
        -DLIBUNWIND_ENABLE_STATIC=ON \
        -DLIBUNWIND_ENABLE_SHARED=OFF \
        -DLIBCXX_CXX_ABI=libcxxabi \
        -DLIBCXXABI_USE_LLVM_UNWINDER=ON \
        -DLIBCXX_USE_COMPILER_RT=OFF \
        -DLIBCXXABI_USE_COMPILER_RT=OFF \
        -DLIBUNWIND_USE_COMPILER_RT=OFF \
        -DLIBCXX_INCLUDE_BENCHMARKS=OFF \
        -DLIBCXX_ENABLE_ABI_LINKER_SCRIPT=OFF \
        -DLIBCXX_HAS_ATOMIC_LIB=OFF

    ninja -C "$RT_BUILD" -j"$JOBS" cxx cxxabi unwind
    ninja -C "$RT_BUILD" install
    info "libc++, libc++abi, libunwind installed to sysroot"
}

# =============================================================================
# Post-install: symlinks, cfg, ldd wrapper
# =============================================================================
post_install() {
    step "Step 7: Create wrappers and symlinks"

    local BIN="$INSTALL_PREFIX/bin"

    # --- llvm tool triple-prefixed symlinks ---
    for tool in ar ranlib nm objcopy objdump strip readelf size strings addr2line; do
        [ -f "$BIN/llvm-$tool" ] && ln -sf "llvm-$tool" "$BIN/$TRIPLE-$tool" 2>/dev/null || true
    done

    # --- clang triple-prefixed symlinks ---
    for tool in clang clang++; do
        ln -sf clang "$BIN/$TRIPLE-$tool" 2>/dev/null || true
    done

    # --- ldd-like tool for PE/COFF DLL dependencies ---
    cat > "$BIN/$TRIPLE-ldd" << 'LDDEOF'
#!/bin/bash
# Show DLL dependencies of PE/COFF executables
BINDIR="$(cd "$(dirname "$0")" && pwd)"
for f in "$@"; do
    echo "$f:"
    "$BINDIR/llvm-readobj" --needed-libs "$f" 2>/dev/null \
        | grep -E '^\s+\S+\.dll' | sed 's/^\s*/    /'
done
LDDEOF
    chmod +x "$BIN/$TRIPLE-ldd"

    # --- cfg file for auto-detection ---
    # Placed alongside clang; auto-loaded when x86_64-pc-cygwin-clang runs.
    cat > "$BIN/x86_64-pc-windows-cygnus.cfg" << 'CFGEOF'
--stdlib=libc++
--unwindlib=libunwind
-fuse-ld=lld
CFGEOF

    # --- Wine wrapper ---
    cp "$SCRIPT_DIR/scripts/wine-cygwin.sh" "$BIN/wine-cygwin" 2>/dev/null || true
    chmod +x "$BIN/wine-cygwin" 2>/dev/null || true

    info "Symlinks, cfg, and ldd created"
}

# =============================================================================
# Clean up unnecessary files
# =============================================================================
cleanup() {
    step "Step 8: Cleanup"

    # Remove GCC .exe from sysroot (we use Clang + ld.lld only)
    info "Removing .exe files from sysroot..."
    find "$SYSROOT" -name "*.exe" -type f -delete 2>/dev/null || true
    rm -rf "$SYSROOT/usr/lib/gcc/$TRIPLE/$GCCVER/install-tools" 2>/dev/null || true
    rm -rf "$SYSROOT/usr/sbin" 2>/dev/null || true

    # Remove unnecessary Clang/LLVM tools
    info "Removing unnecessary tools..."
    local BIN_DIR="$INSTALL_PREFIX/bin"
    cd "$BIN_DIR"
    rm -f amdgpu-arch nvptx-arch clang-cl clang-cpp \
          clang-check clang-extdef-mapping clang-format clang-installapi \
          clang-linker-wrapper clang-nvlink-wrapper \
          clang-offload-bundler clang-offload-packager \
          clang-refactor clang-repl clang-scan-deps clang-sycl-linker \
          diagtool git-clang-format hmaptool \
          scan-build scan-build-py analyze-build intercept-build scan-view \
          llvm-cov llvm-cxxfilt llvm-dwp llvm-mca llvm-ml \
          llvm-pdbutil llvm-profdata llvm-profgen llvm-symbolizer \
          lld-link ld64.lld wasm-ld \
          2>/dev/null || true

    rm -rf "$INSTALL_PREFIX/libexec" \
           "$INSTALL_PREFIX/share/scan-build" \
           "$INSTALL_PREFIX/share/scan-view" \
           "$INSTALL_PREFIX/share/opt-viewer" \
           2>/dev/null || true

    info "Cleanup done"
}

# =============================================================================
# Package
# =============================================================================
do_package() {
    step "Packaging toolchain..."

    local out_dir="$PROJECT_DIR"
    local pkg_dir="$out_dir/$PACKAGE_NAME"

    rm -rf "$pkg_dir"
    mkdir -p "$pkg_dir"

    cp -a "$INSTALL_PREFIX" "$pkg_dir/toolchain"
    cp -a "$SYSROOT" "$pkg_dir/sysroot"

    # README
    cat > "$pkg_dir/README.txt" << EOF
llvm-cygwin ${LLVM_VERSION} — Cross-compiler for Cygwin (Pure LLVM)
=====================================================================
Linux host → Cygwin/Windows PE target

Includes:
  Clang ${LLVM_VERSION}  — C/C++ compiler with Cygwin driver patches
  LLD ${LLVM_VERSION}    — COFF linker (no GCC needed)
  libc++ + libc++abi + libunwind ${LLVM_VERSION} — default C++ stdlib
  Cygwin sysroot — headers, libraries, w32api

Usage:
  source env.sh
  x86_64-pc-cygwin-clang++ -static hello.cpp -o hello.exe

Test with Wine:
  wine-cygwin hello.exe
EOF

    # env setup
    cat > "$pkg_dir/env.sh" << 'ENVEOF'
#!/bin/bash
TC="$(cd "$(dirname "$0")" && pwd)"
export PATH="$TC/toolchain/bin:$PATH"
echo "llvm-cygwin ready. Try: x86_64-pc-cygwin-clang++ -static test.cpp -o test.exe"
ENVEOF
    chmod +x "$pkg_dir/env.sh"

    # Package
    cd "$out_dir"
    tar -cJf "$PACKAGE_FILE" "$PACKAGE_NAME"
    rm -rf "$pkg_dir"

    echo ""
    echo -e "${GREEN}Package: $PACKAGE_FILE ($(du -h "$PACKAGE_FILE" | cut -f1))${NC}"
    echo "  $(tar -tJf "$PACKAGE_FILE" | wc -l) files"
}

# =============================================================================
# Main
# =============================================================================
DO_BUILD=1
DO_PACKAGE=1
for arg in "$@"; do
    case "$arg" in
        --build-only)   DO_PACKAGE=0 ;;
        --package-only) DO_BUILD=0 ;;
        --help|-h)
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --build-only     Build toolchain, skip packaging"
            echo "  --package-only   Package existing toolchain"
            echo ""
            echo "Environment:"
            echo "  JOBS             Parallel jobs (default: nproc)"
            echo "  PROXY            HTTP proxy (default: http://127.0.0.1:7897)"
            echo "  SKIP_CLONE=1     Skip LLVM clone step"
            exit 0
            ;;
    esac
done

echo "================================================================"
echo " llvm-cygwin ${LLVM_VERSION} Build"
echo " Install : $INSTALL_PREFIX"
echo " Sysroot : $SYSROOT"
echo " Build   : $BUILD_DIR"
echo " Jobs    : $JOBS"
echo "================================================================"

if [ "$DO_BUILD" -eq 1 ]; then
    check_prereqs
    clone_llvm
    apply_patches
    build_llvm
    build_runtimes
    post_install
    cleanup

    step "Build Complete!"
    echo ""
    echo "  Toolchain: $INSTALL_PREFIX"
    echo "  Sysroot:   $SYSROOT"
    echo ""
    echo "  Usage:"
    echo "    export PATH=$INSTALL_PREFIX/bin:\$PATH"
    echo "    x86_64-pc-cygwin-clang++ -static hello.cpp -o hello.exe"
    echo ""
fi

if [ "$DO_PACKAGE" -eq 1 ]; then
    do_package
fi

echo -e "${GREEN}Done.${NC}"
