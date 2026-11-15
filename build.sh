#!/bin/bash
# =============================================================================
# build.sh — All-in-one build script for llvm-cygwin cross-compiler toolchain
# =============================================================================
# Usage:
#   ./build.sh                    # Build (resumes where it left off) + package
#   ./build.sh --build-only       # Build only, don't package
#   ./build.sh --package-only     # Package existing toolchain
#   ./build.sh --clean            # Force a clean reconfigure of build dirs
#
# The script is RESUME-friendly: existing build/llvm-project, build/llvm-build
# and build/runtime-build directories are reused and ninja only rebuilds what
# actually changed, so an interrupted build can simply be continued by running
# ./build.sh again. Use --clean to force a full reconfigure from scratch.
#
# Quick start (first time):
#   1. ./scripts/fetch-patches.sh
#   2. ./scripts/fetch-sysroot.sh
#   3. ./build.sh
#
# Environment:
#   JOBS         Parallel build jobs (default: nproc --all)
#   PROXY        HTTP proxy (default: http://127.0.0.1:7897)
#   SKIP_CLONE   Skip LLVM clone step (for dev iteration)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"

PATCH_DIR="$PROJECT_DIR/patches"
INSTALL_PREFIX="$PROJECT_DIR/toolchain"
# llvm-mingw-style single root: the Cygwin headers/libs live *inside* the
# toolchain tree (generic-pc-cygwin/, x86_64-pc-cygwin/, ...) instead of a
# separate sysroot/ directory, so the whole thing ships as one folder.
SYSROOT="$INSTALL_PREFIX"
BUILD_DIR="$PROJECT_DIR/build"
# Baked into the driver as the default sysroot and resolved relative to
# <root>/bin, so the tree stays relocatable: <root>/bin/.. == <root>.
DEFAULT_SYSROOT=".."
# Default parallelism: every installed CPU (nproc --all ignores affinity
# masks / cgroup limits). Lower it on memory-limited hosts: JOBS=8 ./build.sh
NPROC="$(nproc --all 2>/dev/null || echo 4)"
JOBS="${JOBS:-$NPROC}"
LLVM_VERSION="23.1.1"
# PROXY: set to empty string to disable (e.g. in CI)
PROXY=""

TRIPLE="x86_64-pc-cygwin"
GCCVER=14

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

    if [ ! -d "$SYSROOT/usr/include" ] && [ ! -d "$SYSROOT/generic-pc-cygwin/include" ]; then
        err "Sysroot not found at $SYSROOT"
        err "Run: ./scripts/fetch-sysroot.sh"
        exit 1
    fi
}

# =============================================================================
# Clone LLVM
# =============================================================================
clone_llvm() {
    step "Step 1: LLVM source (${LLVM_VERSION})"

    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"

    if [ -d llvm-project ]; then
        # Resume-friendly: reuse an existing checkout, but only if it is the
        # tag we build — otherwise the stale sources would silently be patched
        # and compiled under the new version number.
        local have
        have="$(git -C llvm-project describe --tags --exact-match 2>/dev/null || echo unknown)"
        if [ "$have" = "llvmorg-${LLVM_VERSION}" ]; then
            info "Using existing llvm-project ($have; delete it to force a fresh clone)"
            return
        fi
        info "Existing checkout is $have, want llvmorg-${LLVM_VERSION}: recloning"
        rm -rf llvm-project
        # Build caches and the patch stamp belong to the old version too. The
        # install root also holds the Cygwin headers/libs now, so only the
        # LLVM-owned subdirectories are removed.
        rm -rf llvm-build runtime-build "$BUILD_DIR/.patches-applied" \
               "$INSTALL_PREFIX/bin" "$INSTALL_PREFIX/lib" \
               "$INSTALL_PREFIX/share" "$INSTALL_PREFIX/include" \
               "$INSTALL_PREFIX/libexec"
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
# Cygwin patches are exported from source tarballs and therefore carry many
# different path prefixes (a/..., origsrc/llvm-X.src/..., origsrc/libcxx-X.src/...,
# origsrc/libcxxabi-X.src/..., origsrc/llvm-project-X.src/..., origsrc/runtimes/...).
# They can also target any directory of the monorepo — llvm, clang, lld,
# libcxx, libcxxabi, libunwind, compiler-rt AND runtimes/ (e.g. the
# runtimes-newlib-libc.patch that fixes HandleLibC.cmake).
#
# So instead of assuming a fixed base dir / strip level, each patch is tried
# against every candidate directory × strip level and is applied wherever a
# clean dry-run succeeds. Patches that are already applied or that don't match
# this LLVM version are skipped, which makes this step idempotent.
# =============================================================================
apply_patches() {
    step "Step 2: Apply Patches"

    local LLVM_SRC="$BUILD_DIR/llvm-project"
    cd "$LLVM_SRC"

    # Fast resume path: if no patch file is newer than the last successful run,
    # assume the tree is already patched and do not re-scan everything.
    local stamp="$BUILD_DIR/.patches-applied"
    if [ -f "$stamp" ]; then
        if ! find "$PATCH_DIR" -name '*.patch' -newer "$stamp" -print -quit 2>/dev/null | grep -q .; then
            info "Patches already applied (stamp $stamp); skipping"
            return 0
        fi
        info "Patch files changed since last apply; re-applying (idempotent)..."
    fi

    # Candidate base directories: the monorepo root first (covers a/… git-style
    # patches), then each project directory the Cygwin patches may touch.
    local bases=("$LLVM_SRC")
    local sub
    for sub in llvm clang lld libcxx libcxxabi libunwind compiler-rt runtimes cmake utils; do
        [ -d "$LLVM_SRC/$sub" ] && bases+=("$LLVM_SRC/$sub")
    done

    local total=0 applied=0 skipped=0
    local patch
    while IFS= read -r -d '' patch; do
        local pname base_dir p ok=0
        pname="$(basename "$patch")"
        total=$((total + 1))

        for base_dir in "${bases[@]}"; do
            for p in 1 2 3 4; do
                if ( cd "$base_dir" && patch -p"$p" -N --batch --dry-run < "$patch" >/dev/null 2>&1 ); then
                    if ( cd "$base_dir" && patch -p"$p" -N --batch --no-backup-if-mismatch < "$patch" >/dev/null 2>&1 ); then
                        echo "    $pname -> OK  (-p$p in $(basename "$base_dir"))"
                        applied=$((applied + 1))
                        ok=1
                        break 2
                    fi
                fi
            done
        done

        if [ "$ok" -eq 0 ]; then
            echo "    $pname -> skipped (already applied or does not match LLVM ${LLVM_VERSION})"
            skipped=$((skipped + 1))
        fi
    done < <(find "$PATCH_DIR" -name '*.patch' -print0 2>/dev/null | sort -z)

    echo ""
    info "Patches: $total total, $applied applied, $skipped skipped"

    # Only stamp if at least the tree is in a usable (patched or clean) state.
    if [ "$applied" -gt 0 ] || [ -f "$stamp" ]; then
        : > "$stamp"
    fi
}

# =============================================================================
# Build LLVM/Clang/LLD
# =============================================================================
build_llvm() {
    step "Step 3: Configure LLVM (if needed)"

    cd "$BUILD_DIR"

    local NEED_CONF=0
    if [ ! -f llvm-build/CMakeCache.txt ]; then
        NEED_CONF=1
    elif [ "$FORCE_RECONF" -eq 1 ]; then
        info "--clean: wiping llvm-build for a fresh configure"
        rm -rf llvm-build
        NEED_CONF=1
    elif ! grep -qxF "DEFAULT_SYSROOT:STRING=${DEFAULT_SYSROOT}" llvm-build/CMakeCache.txt; then
        info "llvm-build was configured for a different default sysroot; reconfiguring in place..."
        NEED_CONF=1
    else
        info "llvm-build already configured; resuming (use --clean to reconfigure)"
    fi

    if [ "$NEED_CONF" -eq 1 ]; then
        # Only the LLVM-owned subdirectories are wiped: this is also the root
        # that holds the Cygwin headers/libs (generic-pc-cygwin/, <triple>/,
        # usr/), which must survive a reconfigure.
        rm -rf "$INSTALL_PREFIX/bin" "$INSTALL_PREFIX/lib" \
               "$INSTALL_PREFIX/share" "$INSTALL_PREFIX/include" \
               "$INSTALL_PREFIX/libexec"

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
            -DDEFAULT_SYSROOT="$DEFAULT_SYSROOT" \
            -DLLVM_ENABLE_THREADS=ON \
            -DLLVM_ENABLE_LLD=ON \
            -DCLANG_DEFAULT_LINKER=lld
    fi

    step "Step 4: Build LLVM (${JOBS} jobs)"
    ninja -C llvm-build -j"$JOBS"

    step "Step 5: Install to $INSTALL_PREFIX"
    ninja -C llvm-build install
}

# =============================================================================
# Build libc++ / libc++abi / libunwind for Cygwin target
# =============================================================================
build_runtimes() {
    step "Step 6: Build libc++ + libc++abi + libunwind for Cygwin"

    local RT_BUILD="$BUILD_DIR/runtime-build"
    local RT_CONF_OK=0

    # Resume-friendly configure: only (re)configure when needed. The cache must
    # match the current root (CMAKE_SYSROOT / install prefix) and the Cygwin
    # requirements: RUNTIMES_USE_LIBC=newlib so libc++ takes the newlib ctype
    # rune table in <__locale>, and LIBCXXABI_HAS_CXA_THREAD_ATEXIT_IMPL off
    # (see the configure call below). Object files are kept, so reconfiguring
    # in place is cheap.
    if [ -f "$RT_BUILD/CMakeCache.txt" ]; then
        if grep -qxF "CMAKE_SYSROOT:PATH=$SYSROOT" "$RT_BUILD/CMakeCache.txt" &&
           grep -qxF "CMAKE_INSTALL_PREFIX:PATH=$SYSROOT/$TRIPLE" "$RT_BUILD/CMakeCache.txt" &&
           grep -q '^RUNTIMES_USE_LIBC:STRING=newlib$' "$RT_BUILD/CMakeCache.txt" &&
           ! grep -qE '^LIBCXXABI_HAS_CXA_THREAD_ATEXIT_IMPL:[A-Z]+=(1|ON|TRUE|YES)$' "$RT_BUILD/CMakeCache.txt"; then
            RT_CONF_OK=1
        else
            info "runtime-build cache needs reconfiguring (root paths / LIBC newlib / thread_local atexit); doing it in place..."
        fi
    fi
    if [ "$FORCE_RECONF" -eq 1 ]; then
        info "--clean: wiping runtime-build for a fresh configure"
        rm -rf "$RT_BUILD"
        RT_CONF_OK=0
    fi

    cat > "$BUILD_DIR/toolchain-cygwin.cmake" << 'TCEOF'
set(CMAKE_SYSTEM_NAME Cygwin)
set(CMAKE_SYSTEM_PROCESSOR x86_64)
set(triple x86_64-pc-cygwin)

set(CMAKE_C_COMPILER @CC@)
set(CMAKE_CXX_COMPILER @CXX@)
set(CMAKE_C_COMPILER_TARGET ${triple})
set(CMAKE_CXX_COMPILER_TARGET ${triple})
set(CMAKE_SYSROOT @SYSROOT@)
# llvm-mingw-style tree: headers/libs of the target live in <root>/<triple>
set(CMAKE_FIND_ROOT_PATH @SYSROOT@/@TRIPLE@)

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
    sed -i "s|@TRIPLE@|$TRIPLE|g"                    "$BUILD_DIR/toolchain-cygwin.cmake"

    if [ "$RT_CONF_OK" -eq 0 ]; then
        info "Configuring runtime build..."
        # LIBCXXABI_HAS_CXA_THREAD_ATEXIT_IMPL=OFF is required: the CMake probe
        # (check_library_exists) cannot link while cross-compiling
        # (CMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY), so it always reports
        # the symbol as present even though cygwin1.dll does not export
        # __cxa_thread_atexit_impl. Left on, libc++abi compiles
        # __cxa_thread_atexit() as a call through Cygwin's deliberately NULL
        # impl pointer, which the optimizer turns into a trap — every
        # non-trivially-constructed thread_local then aborts on first access.
        # With it off, libc++abi uses its own DtorsManager path instead.
        cmake -G Ninja \
            -S "$BUILD_DIR/llvm-project/runtimes" \
            -B "$RT_BUILD" \
            -DCMAKE_TOOLCHAIN_FILE="$BUILD_DIR/toolchain-cygwin.cmake" \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_INSTALL_PREFIX="$SYSROOT/$TRIPLE" \
            -DLLVM_ENABLE_RUNTIMES="libcxx;libcxxabi;libunwind" \
            -DLLVM_DEFAULT_TARGET_TRIPLE="$TRIPLE" \
            -DRUNTIMES_USE_LIBC=newlib \
            -DLIBCXXABI_HAS_CXA_THREAD_ATEXIT_IMPL=OFF \
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
    else
        info "runtime-build already configured correctly; resuming"
    fi

    ninja -C "$RT_BUILD" -j"$JOBS" cxx cxxabi unwind
    # Drop the previously installed libc++ header tree first: headers are fully
    # owned by this install, and a stale one (e.g. libc++ 22 shipped a ctype.h
    # that 23 no longer has) makes the new <cctype> fail with #error.
    rm -rf "$SYSROOT/$TRIPLE/include/c++/v1"
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

    # --- default flags, laid out like llvm-mingw ---
    # clang auto-loads <triple>.cfg from this directory, where <triple> is the
    # driver's target triple (--target=…-cygwin normalizes to
    # …-pc-windows-cygnus), so each triple gets a thin file that pins the
    # target and pulls in the flags shared by all Cygwin targets.
    #
    # NOTE: no --rtlib=compiler-rt / --unwindlib=libunwind here — this
    # toolchain does not build compiler-rt, and clang rejects
    # unwindlib=libunwind while rtlib defaults to libgcc (Cygwin). Cygwin's
    # static libgcc.a (kept in the sysroot) provides the runtime/unwind
    # symbols; ld.lld links it without needing the gcc driver.
    cat > "$BIN/cygwin-common.cfg" << 'CFGEOF'
-stdlib=libc++
-fuse-ld=lld
CFGEOF

    local t
    for t in x86_64-pc-windows-cygnus i686-pc-windows-cygnus; do
        cat > "$BIN/$t.cfg" << CFGEOF
-target $t
@cygwin-common.cfg
CFGEOF
    done

    # --- Wine wrapper ---
    cp "$SCRIPT_DIR/scripts/wine-cygwin.sh" "$BIN/wine-cygwin" 2>/dev/null || true
    chmod +x "$BIN/wine-cygwin" 2>/dev/null || true

    info "Symlinks, cfg, and ldd created"
}

# =============================================================================
# Step 8: arrange the sysroot the way llvm-mingw lays out its target trees
# =============================================================================
# clang's Cygwin driver only searches <sysroot>/usr/include, /usr/include/w32api
# and /usr/lib (+ /usr/lib/w32api, /usr/lib/gcc/<triple>/<ver>), while
# llvm-mingw keeps one shared header tree beside per-triple bin/lib/share dirs:
#
#   generic-pc-cygwin/include/          all headers (w32api/ and c++/v1 inside)
#   x86_64-pc-cygwin/include   -> ../generic-pc-cygwin/include
#   x86_64-pc-cygwin/{bin,lib,share}    the real payload
#   i686-pc-cygwin/include     -> ../generic-pc-cygwin/include
#   usr/{include,bin,lib,share}         compatibility symlinks for the driver
#
# All symlinks are relative, so the tarball stays relocatable. The function is
# idempotent: real directories are moved into place once, then symlinked over.
arrange_sysroot() {
    step "Step 8: Arrange sysroot (llvm-mingw-style triple trees)"

    local S="$SYSROOT"
    local GEN="$S/generic-pc-cygwin"
    local T="$S/$TRIPLE"
    local T32="i686-pc-cygwin"
    local part gccdir

    mkdir -p "$GEN" "$T" "$S/$T32" "$S/share"

    # --- one shared header tree ---
    if [ -d "$S/usr/include" ] && [ ! -L "$S/usr/include" ]; then
        rm -rf "$GEN/include"
        mv "$S/usr/include" "$GEN/include"
        info "  usr/include -> generic-pc-cygwin/include"
    fi
    # A previous run installed libc++ straight into <triple>/include; fold that
    # into the shared tree before it is replaced by the symlink below.
    if [ -d "$T/include" ] && [ ! -L "$T/include" ]; then
        mkdir -p "$GEN/include"
        cp -a "$T/include"/. "$GEN/include"/
        rm -rf "$T/include"
    fi
    mkdir -p "$GEN/include"

    # --- payload into the target tree (bin/lib, llvm-mingw style) ---
    for part in bin lib; do
        if [ -d "$S/usr/$part" ] && [ ! -L "$S/usr/$part" ]; then
            rm -rf "$T/$part"
            mv "$S/usr/$part" "$T/$part"
            info "  usr/$part -> $TRIPLE/$part"
        fi
        mkdir -p "$T/$part"
        rm -f "$S/usr/$part"
    done

    # --- flatten GCC's runtime directory into <triple>/lib ---
    # The driver no longer relies on GCCInstallation (no usr/lib/gcc/...), so
    # crt0.o/crtbegin.o/libgcc.a must sit next to the other libraries. GCC's
    # private headers are dropped: clang ships its own in the resource dir.
    for gccdir in "$T"/lib/gcc/*/*; do
        [ -d "$gccdir" ] || continue
        # GCC's private headers (omp.h, quadmath.h, gcov.h, ...) are merged into
        # the shared tree without overwriting anything Cygwin already provides;
        # clang's own headers in the resource dir are searched first anyway.
        if [ -d "$gccdir/include" ]; then
            mkdir -p "$GEN/include"
            cp -an "$gccdir/include"/. "$GEN/include"/
            rm -rf "$gccdir/include"
        fi
        cp -a "$gccdir"/. "$T/lib"/
    done
    rm -rf "$T/lib/gcc"

    # --- runtime data shared by every target goes to the top-level share/ ---
    if [ -d "$S/usr/share/cygwin" ]; then
        rm -rf "$S/share/cygwin"
        mv "$S/usr/share/cygwin" "$S/share/cygwin"
        info "  usr/share/cygwin -> share/cygwin"
    fi
    rm -rf "$T/share" "$S/usr/share"

    # --- per-triple headers are symlinks to the shared tree ---
    ln -sfn "../generic-pc-cygwin/include" "$T/include"
    ln -sfn "../generic-pc-cygwin/include" "$S/$T32/include"

    # Only the runtime DLL is useful in the target bin/; c89, cc,
    # cygserver-config, ... are host-side clutter.
    find "$T/bin" -mindepth 1 -maxdepth 1 ! -name cygwin1.dll \
        -exec rm -rf {} + 2>/dev/null || true

    # No usr/ or etc/ compatibility layer: the patched driver searches
    # <root>/<triple>/{include,lib} directly. etc/ only carries Cygwin's default
    # config templates (cygserver.conf) for a running Cygwin system.
    rm -rf "$S/usr" "$S/etc"

    info "  Headers: $(find "$GEN/include" -mindepth 1 -maxdepth 1 | wc -l) entries in generic-pc-cygwin/include"
}

# =============================================================================
# Clean up unnecessary files
# =============================================================================
cleanup() {
    step "Step 9: Cleanup"

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

    rm -rf "$INSTALL_PREFIX/libexec" 2>/dev/null || true

    # NOTE: do not trim $INSTALL_PREFIX/share — scan-build/scan-view/opt-viewer
    # are legitimate parts of the toolchain install. Only the sysroot gets its
    # share/ reduced (see arrange_sysroot).

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

    # Single llvm-mingw-style root: bin/, lib/clang/, share/ and the Cygwin
    # trees (generic-pc-cygwin/, x86_64-pc-cygwin/, i686-pc-cygwin/) all live
    # side by side, so there is no separate sysroot/ to point at.
    cp -a "$INSTALL_PREFIX/." "$pkg_dir/"

    # Sole metadata file, exactly like llvm-mingw: the LLVM project license
    # (Apache-2.0 WITH LLVM-exception). No README, no env script.
    cp "$BUILD_DIR/llvm-project/LICENSE.TXT" "$pkg_dir/LICENSES.txt"

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
FORCE_RECONF=0
for arg in "$@"; do
    case "$arg" in
        --build-only)   DO_PACKAGE=0 ;;
        --package-only) DO_BUILD=0 ;;
        --clean|--force) FORCE_RECONF=1 ;;
        --help|-h)
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --build-only     Build toolchain, skip packaging"
            echo "  --package-only   Package existing toolchain"
            echo "  --clean, --force Force a clean reconfigure of the build dirs"
            echo "                    (existing source clone is kept)"
            echo ""
            echo "The script resumes incremental builds by default; no need to"
            echo "re-run everything from scratch after an interruption."
            echo ""
            echo "Environment:"
            echo "  JOBS             Parallel jobs (default: nproc --all)"
            echo "  PROXY            HTTP proxy (default: http://127.0.0.1:7897)"
            echo "  SKIP_CLONE=1     Skip LLVM clone step (for dev iteration)"
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
    arrange_sysroot
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
