#!/bin/bash
# =============================================================================
# fetch-patches.sh — Download Cygwin LLVM/Clang/LLD patches from Cygwin repos
# =============================================================================
# This script fetches patches from Cygwin's official packaging repositories.
# Sources:
#   https://cygwin.com/git/cygwin-packages/llvm.git   (LLVM + runtimes)
#   https://cygwin.com/git/cygwin-packages/clang.git  (Clang)
#   https://cygwin.com/git/cygwin-packages/lld.git    (LLD)
#
# Alternative: download -src.tar.xz from a Cygwin mirror and extract patches.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
PATCHES_DIR="$PROJECT_DIR/patches"
CYGWIN_GIT="${CYGWIN_GIT_URL:-https://cygwin.com/git/cygwin-packages}"

# Cygwin mirror for source package download (fallback method)
CYGWIN_MIRROR="${CYGWIN_MIRROR:-https://mirrors.kernel.org/sourceware/cygwin}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
step()  { echo -e "\n${GREEN}=== $1 ===${NC}"; }
info()  { echo -e "${YELLOW}  $1${NC}"; }
err()   { echo -e "${RED}ERROR: $1${NC}" >&2; }

usage() {
    cat << 'EOF'
Usage: fetch-patches.sh [--method=git|srcpkg] [--version=LLVM_VER]

Fetches Cygwin patches for LLVM/Clang/LLD from Cygwin repos.

Options:
  --method=git       Clone cygwin-packages git repos (default, lightweight)
  --method=srcpkg    Download -src.tar.xz from Cygwin mirror
  --version=VER      LLVM version (e.g. 20.1.8), used for srcpkg method

Environment:
  CYGWIN_GIT_URL     Base URL for cygwin-packages git repos
  CYGWIN_MIRROR      Cygwin mirror base URL
  http_proxy / https_proxy   Proxy for downloads
EOF
    exit 0
}

# =============================================================================
# Method 1: Clone cygwin-packages git repos
# =============================================================================
fetch_via_git() {
    step "Fetching patches via cygwin-packages git repos"

    local tmpdir
    tmpdir="$(mktemp -d)"

    # ------------------------------------------------------------------
    # Main packages (their patches go directly into matching dirs)
    # ------------------------------------------------------------------
    for pkg in llvm clang lld compiler-rt; do
        info "Cloning cygwin-packages/$pkg.git ..."
        git clone --depth 1 "$CYGWIN_GIT/$pkg.git" "$tmpdir/$pkg" 2>&1 | tail -1

        local target="$PATCHES_DIR/$pkg"
        mkdir -p "$target"

        local count=0
        for f in "$tmpdir/$pkg"/*.patch; do
            [ -f "$f" ] || continue
            cp "$f" "$target/"
            count=$((count + 1))
        done
        info "  $pkg: $count patches copied"
    done

    # ------------------------------------------------------------------
    # libcxx repo — contains patches for libcxx, libcxxabi, and libunwind
    # all mixed together.  Split by naming convention (from cygport):
    #   0302-*, 0304-*, 0305-*, 0306-*  →  libcxx
    #   0402-*, 0403-*, 0404-*          →  libcxxabi
    #   20.1.2-*                        →  libunwind
    #   (anything else falls through to libcxx)
    # ------------------------------------------------------------------
    info "Cloning cygwin-packages/libcxx.git ..."
    git clone --depth 1 "$CYGWIN_GIT/libcxx.git" "$tmpdir/libcxx" 2>&1 | tail -1

    for d in libcxx libcxxabi libunwind; do
        mkdir -p "$PATCHES_DIR/$d"
    done

    local counted_xx=0 counted_abi=0 counted_unwind=0
    for f in "$tmpdir/libcxx"/*.patch; do
        [ -f "$f" ] || continue
        local base
        base="$(basename "$f")"
        case "$base" in
            0402-*|0403-*|0404-*)
                cp "$f" "$PATCHES_DIR/libcxxabi/"
                counted_abi=$((counted_abi + 1))
                ;;
            20.1.2-*)
                cp "$f" "$PATCHES_DIR/libunwind/"
                counted_unwind=$((counted_unwind + 1))
                ;;
            *)
                cp "$f" "$PATCHES_DIR/libcxx/"
                counted_xx=$((counted_xx + 1))
                ;;
        esac
    done
    info "  libcxx: $counted_xx patches"
    info "  libcxxabi: $counted_abi patches (from libcxx repo)"
    info "  libunwind: $counted_unwind patches (from libcxx repo)"

    rm -rf "$tmpdir"

    info "Patches fetched to $PATCHES_DIR/"
    local total
    total="$(find "$PATCHES_DIR/llvm" "$PATCHES_DIR/clang" "$PATCHES_DIR/lld" \
        "$PATCHES_DIR/libcxx" "$PATCHES_DIR/libcxxabi" \
        "$PATCHES_DIR/libunwind" "$PATCHES_DIR/compiler-rt" \
        -maxdepth 1 -name '*.patch' -type f 2>/dev/null | wc -l)"
    info "  Total: $total patch files"
}

# =============================================================================
# Method 2: Download source packages from Cygwin mirror
# =============================================================================
fetch_via_srcpkg() {
    local LLVM_VER="${1:-20.1.8}"
    step "Fetching patches via Cygwin source packages (LLVM $LLVM_VER)"

    # Cygwin package versions (check setup.ini for current versions)
    local tmpdir
    tmpdir="$(mktemp -d)"

    download_and_extract() {
        local pkg="$1"
        local ver="$2"
        local rel="${3:-1}"
        local url="${CYGWIN_MIRROR}/x86_64/release/${pkg}/${pkg}-${ver}-${rel}-src.tar.xz"

        info "Downloading $url ..."
        if wget -q --show-progress "$url" -O "$tmpdir/${pkg}-src.tar.xz" 2>/dev/null; then
            info "Extracting..."
            mkdir -p "$tmpdir/$pkg"
            tar -xJf "$tmpdir/${pkg}-src.tar.xz" -C "$tmpdir/$pkg" --strip-components=0 2>/dev/null || true

            local target="$PATCHES_DIR/$pkg"
            mkdir -p "$target"

            # Find and copy .patch files
            local count=0
            while IFS= read -r -d '' f; do
                cp "$f" "$target/"
                count=$((count + 1))
            done < <(find "$tmpdir/$pkg" -name "*.patch" -print0 2>/dev/null)
            info "  $pkg: $count patches"
        else
            err "Failed to download $url"
            err "Check CYGWIN_MIRROR and package version."
        fi
    }

    # These exact version numbers need to match what's on the mirror
    download_and_extract "llvm"   "$LLVM_VER"
    download_and_extract "clang"  "$LLVM_VER"
    download_and_extract "lld"    "$LLVM_VER"

    rm -rf "$tmpdir"
}

# =============================================================================
# Main
# =============================================================================
METHOD="git"
LLVM_VER="20.1.8"

for arg in "$@"; do
    case "$arg" in
        --method=*)    METHOD="${arg#*=}" ;;
        --version=*)   LLVM_VER="${arg#*=}" ;;
        --help|-h)     usage ;;
    esac
done

echo "================================================================"
echo " Fetching Cygwin Patches"
echo " Method : $METHOD"
echo " Target : $PATCHES_DIR"
echo "================================================================"

# Ensure patch directories exist
mkdir -p "$PATCHES_DIR"/{llvm,clang,lld,libcxx,libcxxabi,libunwind,compiler-rt}

case "$METHOD" in
    git)
        if ! command -v git &>/dev/null; then
            err "git not found. Install git or use --method=srcpkg"
            exit 1
        fi
        fetch_via_git
        ;;
    srcpkg)
        if ! command -v wget &>/dev/null; then
            err "wget not found. Install wget."
            exit 1
        fi
        fetch_via_srcpkg "$LLVM_VER"
        ;;
    *)
        err "Unknown method: $METHOD (use git or srcpkg)"
        exit 1
        ;;
esac

echo ""
echo -e "${GREEN}Done. Patches are in $PATCHES_DIR/${NC}"
