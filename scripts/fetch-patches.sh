#!/bin/bash
# =============================================================================
# fetch-patches.sh — Download Cygwin LLVM/Clang/LLD patches via setup.ini
# =============================================================================
# Fetches setup.ini from a Cygwin mirror, resolves the source package paths
# (and versions) for LLVM/Clang/LLD/compiler-rt/libc++/libc++abi/libunwind,
# downloads the -src.tar.xz archives, and extracts .patch files into patches/.
#
# Usage:
#   ./scripts/fetch-patches.sh
#   CYGWIN_MIRROR=https://... ./scripts/fetch-patches.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
PATCHES_DIR="$PROJECT_DIR/patches"

CYGWIN_MIRROR="${CYGWIN_MIRROR:-https://mirrors.kernel.org/sourceware/cygwin}"
ARCH="x86_64"

# Respect proxy from environment
export http_proxy="${http_proxy:-${HTTP_PROXY:-}}"
export https_proxy="${https_proxy:-${HTTPS_PROXY:-}}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
step()  { echo -e "\n${GREEN}=== $1 ===${NC}"; }
info()  { echo -e "${YELLOW}  $1${NC}"; }
err()   { echo -e "${RED}ERROR: $1${NC}" >&2; }

# =============================================================================
# Patch directory → Cygwin binary package name(s) to look up in setup.ini.
# Multiple candidates are tried in order; the first match wins.
# (Cygwin library packages are often prefixed with "lib" and version-suffixed.)
# =============================================================================
declare -a PATCH_PKGS=(
    "llvm:llvm"
    "clang:clang"
    "lld:lld"
    "compiler-rt:libcompiler-rt compiler-rt"
    "libcxx:libc++1 libc++"
    "libcxxabi:libc++abi1 libc++abi"
    "libunwind:libunwind1 libunwind"
)

# =============================================================================
# Check for required tools
# =============================================================================
check_tools() {
    local missing=0

    if ! command -v wget &>/dev/null && ! command -v curl &>/dev/null; then
        err "Neither wget nor curl found. Install one of them."
        missing=1
    fi

    if ! command -v xz &>/dev/null; then
        err "xz not found. Install xz-utils."
        missing=1
    fi

    if ! command -v bzcat &>/dev/null && ! command -v bzip2 &>/dev/null; then
        info "bzip2 not found — cannot use setup.bz2 (will try other formats)"
    fi

    if [ "$missing" -eq 1 ]; then
        exit 1
    fi
}

# =============================================================================
# Download a file (wget preferred, curl fallback)
# =============================================================================
download() {
    local url="$1"
    local dest="$2"
    local desc="${3:-$(basename "$dest")}"

    info "Downloading $desc ..."

    if command -v wget &>/dev/null; then
        wget -q --show-progress "$url" -O "$dest" 2>&1 && return 0
    fi

    if command -v curl &>/dev/null; then
        curl -sSfL "$url" -o "$dest" 2>&1 && return 0
    fi

    err "Failed to download $url"
    return 1
}

# =============================================================================
# Download setup.ini (try bz2 → zst → uncompressed)
# =============================================================================
download_setup_ini() {
    local ini="$1"

    # Try setup.bz2 (smallest, most common)
    if command -v bzcat &>/dev/null || command -v bzip2 &>/dev/null; then
        local url="${CYGWIN_MIRROR}/${ARCH}/setup.bz2"
        info "Fetching setup.bz2 ..."
        if download "$url" "${ini}.bz2"; then
            bzcat "${ini}.bz2" > "$ini" 2>/dev/null
            rm -f "${ini}.bz2"
            info "setup.bz2: OK ($(wc -c < "$ini") bytes)"
            return 0
        fi
    fi

    # Try setup.zst
    if command -v zstd &>/dev/null; then
        local url="${CYGWIN_MIRROR}/${ARCH}/setup.zst"
        info "Fetching setup.zst ..."
        if download "$url" "${ini}.zst"; then
            zstd -dc "${ini}.zst" > "$ini" 2>/dev/null
            rm -f "${ini}.zst"
            info "setup.zst: OK ($(wc -c < "$ini") bytes)"
            return 0
        fi
    fi

    # Try uncompressed setup.ini
    local url="${CYGWIN_MIRROR}/${ARCH}/setup.ini"
    info "Fetching setup.ini (uncompressed) ..."
    if download "$url" "$ini"; then
        info "setup.ini: OK ($(wc -c < "$ini") bytes)"
        return 0
    fi

    err "Cannot download setup.ini from $CYGWIN_MIRROR"
    err "Check CYGWIN_MIRROR and network/proxy settings."
    exit 1
}

# =============================================================================
# Parse a field from a package's section in setup.ini
#   $1 = field name (e.g. "source:", "version:", "install:")
#   $2 = package name
#   $3 = path to setup.ini
# =============================================================================
parse_field() {
    local field="$1"
    local pkg="$2"
    local ini="$3"

    awk -v pkg="@ $pkg" -v field="$field" '
        $0 == pkg { found=1; next }
        found && /^@ /   { exit }
        found && /^\[/   { exit }
        found && index($0, field) == 1 {
            sub("^" field "[ \t]*", "")
            print $1
            exit
        }
    ' "$ini"
}

# =============================================================================
# Resolve which package name (from a space-separated candidate list) exists
# in setup.ini. Echoes the matched name, or empty if none found.
# =============================================================================
resolve_pkg_name() {
    local candidates="$1"
    local ini="$2"

    for cand in $candidates; do
        if grep -q "^@ $cand$" "$ini"; then
            echo "$cand"
            return 0
        fi
    done
}

# =============================================================================
# Download a source package, extract, and copy .patch files to target dir(s)
#   $1 = relative source path (from setup.ini "source:" field)
#   $2 = space-separated list of target patch directories
# =============================================================================
fetch_source_pkg() {
    local relpath="$1"
    local target_dirs="$2"

    local url="${CYGWIN_MIRROR}/${relpath}"
    local fname
    fname="$(basename "$relpath")"
    local tmpfile
    tmpfile="$(mktemp /tmp/cygwin-src-XXXXXX-"$fname")"

    info "  $url"
    if ! download "$url" "$tmpfile" "$fname"; then
        rm -f "$tmpfile"
        return 1
    fi

    local tmpdir
    tmpdir="$(mktemp -d /tmp/cygwin-src-XXXXXX)"
    info "  Extracting..."
    if ! tar -xJf "$tmpfile" -C "$tmpdir" 2>/dev/null; then
        err "  Extraction failed for $fname"
        rm -rf "$tmpdir" "$tmpfile"
        return 1
    fi
    rm -f "$tmpfile"

    # Copy all .patch files into each target directory
    local total_patches=0
    local patch_list=()
    while IFS= read -r -d '' f; do
        patch_list+=("$f")
        total_patches=$((total_patches + 1))
    done < <(find "$tmpdir" -name "*.patch" -print0 2>/dev/null)

    for dir in $target_dirs; do
        mkdir -p "$PATCHES_DIR/$dir"
        for f in "${patch_list[@]:-}"; do
            [ -f "$f" ] || continue
            cp "$f" "$PATCHES_DIR/$dir/"
        done
    done

    info "  $total_patches patch file(s) → $target_dirs"
    rm -rf "$tmpdir"
    return 0
}

# =============================================================================
# Main
# =============================================================================
usage() {
    cat << 'EOF'
Usage: fetch-patches.sh [options]

Fetches Cygwin patches for LLVM/Clang/LLD/compiler-rt/libc++/libc++abi/libunwind
by downloading source packages resolved from setup.ini.

Options:
  --help, -h        Show this help

Environment:
  CYGWIN_MIRROR     Cygwin mirror base URL (default: mirrors.kernel.org)
  http_proxy / https_proxy   Proxy for downloads
EOF
    exit 0
}

for arg in "$@"; do
    case "$arg" in
        --help|-h) usage ;;
    esac
done

echo "================================================================"
echo " Fetching Cygwin Patches"
echo " Mirror : $CYGWIN_MIRROR"
echo " Target : $PATCHES_DIR"
echo "================================================================"

check_tools

step "Step 1: Download setup.ini"
INI="$(mktemp /tmp/cygwin-setup-XXXXXX.ini)"
download_setup_ini "$INI"

step "Step 2: Resolve source packages from setup.ini"

# Determine target major version from the llvm package
LLVM_PKG_VER="$(parse_field "version:" "llvm" "$INI")"
LLVM_MAJOR="${LLVM_PKG_VER%%.*}"
info "  LLVM version from setup.ini: $LLVM_PKG_VER (major: $LLVM_MAJOR)"

# Map: source_path → space-separated list of patch dirs
# (multiple packages may share the same source tarball)
declare -A SRC_TO_DIRS
declare -A SRC_TO_INFO   # source_path → "pkgname version"
FAILURES=0

for entry in "${PATCH_PKGS[@]}"; do
    local_dir="${entry%%:*}"
    candidates="${entry#*:}"

    pkg_name="$(resolve_pkg_name "$candidates" "$INI")"
    if [ -z "$pkg_name" ]; then
        err "Package not found in setup.ini (tried: $candidates)"
        FAILURES=$((FAILURES + 1))
        continue
    fi

    version="$(parse_field "version:" "$pkg_name" "$INI")"
    src_path="$(parse_field "source:" "$pkg_name" "$INI")"

    if [ -z "$src_path" ]; then
        err "No 'source:' field for $pkg_name in setup.ini"
        FAILURES=$((FAILURES + 1))
        continue
    fi

    # Skip packages whose major version doesn't match LLVM
    # (e.g. libc++abi1 only has ancient 8.0.1 — no longer packaged separately)
    pkg_major="${version%%.*}"
    if [ -n "$LLVM_MAJOR" ] && [ "$pkg_major" != "$LLVM_MAJOR" ]; then
        info "  $local_dir: skipping $pkg_name $version (major $pkg_major != $LLVM_MAJOR)"
        continue
    fi

    info "  $local_dir ← $pkg_name $version"

    # Accumulate target dirs for this source path
    if [ -n "${SRC_TO_DIRS[$src_path]:-}" ]; then
        SRC_TO_DIRS[$src_path]="${SRC_TO_DIRS[$src_path]} $local_dir"
    else
        SRC_TO_DIRS[$src_path]="$local_dir"
        SRC_TO_INFO[$src_path]="$pkg_name $version"
    fi
done

rm -f "$INI"

if [ ${#SRC_TO_DIRS[@]} -eq 0 ]; then
    err "No source packages resolved. Check CYGWIN_MIRROR: $CYGWIN_MIRROR"
    exit 1
fi

step "Step 3: Download and extract source packages"

TOTAL_PATCHES=0
for src_path in "${!SRC_TO_DIRS[@]}"; do
    dirs="${SRC_TO_DIRS[$src_path]}"
    pkg_info="${SRC_TO_INFO[$src_path]}"
    info "Source: $pkg_info"
    if fetch_source_pkg "$src_path" "$dirs"; then
        :
    else
        err "  Failed: $src_path"
        FAILURES=$((FAILURES + 1))
    fi
done

step "Summary"
# Count total patch files across all directories
TOTAL_PATCHES="$(find "$PATCHES_DIR"/llvm "$PATCHES_DIR"/clang "$PATCHES_DIR"/lld \
    "$PATCHES_DIR"/compiler-rt "$PATCHES_DIR"/libcxx "$PATCHES_DIR"/libcxxabi \
    "$PATCHES_DIR"/libunwind \
    -maxdepth 1 -name '*.patch' -type f 2>/dev/null | wc -l)"
info "Total patch files: $TOTAL_PATCHES"
info "Patches directory: $PATCHES_DIR/"

if [ "$FAILURES" -gt 0 ]; then
    err "$FAILURES package(s) failed."
    echo ""
    echo "  Make sure CYGWIN_MIRROR is correct: $CYGWIN_MIRROR"
    echo "  Try a different mirror:"
    echo "    CYGWIN_MIRROR=https://mirrors.ustc.edu.cn/cygwin $0"
    exit 1
fi

echo ""
echo -e "${GREEN}Done. Patches are in $PATCHES_DIR/${NC}"
