#!/bin/bash
# =============================================================================
# fetch-patches.sh — Download Cygwin LLVM/Clang/LLD patches via setup.ini
# =============================================================================
# Fetches setup.ini from a Cygwin mirror, resolves the source packages for the
# LLVM release build.sh builds (same major, newest available), downloads the
# -src.tar.xz archives, and extracts .patch files into patches/.
#
# Usage:
#   ./scripts/fetch-patches.sh
#   LLVM_VERSION=23.1.1 ./scripts/fetch-patches.sh
#   CYGWIN_MIRROR=https://... ./scripts/fetch-patches.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
PATCHES_DIR="$PROJECT_DIR/patches"

CYGWIN_MIRROR="${CYGWIN_MIRROR:-https://mirrors.kernel.org/sourceware/cygwin}"
ARCH="x86_64"

# Target LLVM version whose sources get patched: take it from build.sh so the
# fetched patches always match the tree it compiles. Override with
# LLVM_VERSION=23.1.1 ./scripts/fetch-patches.sh
LLVM_VERSION="${LLVM_VERSION:-$(sed -n 's/^LLVM_VERSION="\(.*\)"$/\1/p' "$PROJECT_DIR/build.sh" 2>/dev/null | head -1)}"
LLVM_MAJOR="${LLVM_VERSION%%.*}"

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
            # A truncated download or an HTML error page must not abort the
            # script (set -e): report it and fall through to the next format.
            if bzcat "${ini}.bz2" > "$ini" 2>/dev/null; then
                rm -f "${ini}.bz2"
                info "setup.bz2: OK ($(wc -c < "$ini") bytes)"
                return 0
            fi
            info "setup.bz2: decompression failed, trying next format"
        fi
        rm -f "${ini}.bz2"
    fi

    # Try setup.zst
    if command -v zstd &>/dev/null; then
        local url="${CYGWIN_MIRROR}/${ARCH}/setup.zst"
        info "Fetching setup.zst ..."
        if download "$url" "${ini}.zst"; then
            if zstd -dc "${ini}.zst" > "$ini" 2>/dev/null; then
                rm -f "${ini}.zst"
                info "setup.zst: OK ($(wc -c < "$ini") bytes)"
                return 0
            fi
            info "setup.zst: decompression failed, trying next format"
        fi
        rm -f "${ini}.zst"
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
# List "version source-path" pairs for a package section of setup.ini.
# Cygwin lists several versions per package (current, [test], [prev]); the
# "source:" line always belongs to the "version:" line above it.
#   $1 = package name
#   $2 = path to setup.ini
# =============================================================================
list_pkg_versions() {
    local pkg="$1"
    local ini="$2"

    awk -v pkg="@ $pkg" '
        $0 == pkg { found = 1; version = ""; next }
        found && /^@ / { exit }
        found && /^version:/ { version = $2; next }
        found && /^source:/ && version != "" { print version, $2; version = "" }
    ' "$ini"
}

# =============================================================================
# Pick the setup.ini version/source pair that matches the LLVM version we
# build: an exact version first, otherwise the newest one with the same major
# (Cygwin usually lags a patch release behind upstream, e.g. it ships 23.1.0
# while upstream already has 23.1.1).
# Echoes a single "version source-path" line, or nothing if unavailable.
#   $1 = package name
#   $2 = path to setup.ini
#   $3 = wanted version (e.g. 23.1.1, may be empty)
#   $4 = wanted major (e.g. 23, may be empty)
# =============================================================================
select_pkg_version() {
    local pkg="$1"
    local ini="$2"
    local want="${3:-}"
    local want_major="${4:-}"

    local pairs
    pairs="$(list_pkg_versions "$pkg" "$ini")"
    [ -n "$pairs" ] || return 0

    local selected=""
    if [ -n "$want" ]; then
        # "23.1.0-1" → "23.1.0"; Cygwin appends its own -N release suffix.
        selected="$(printf '%s\n' "$pairs" \
            | awk -v w="$want" '{ v = $1; sub(/-[0-9]+$/, "", v); if (v == w) { print; exit } }')"
    fi
    if [ -z "$selected" ] && [ -n "$want_major" ]; then
        selected="$(printf '%s\n' "$pairs" \
            | awk -v m="$want_major" '{ split($1, v, "."); if (v[1] == m) print }' \
            | sort -V -k1,1 | tail -1)"
    fi
    if [ -z "$selected" ] && [ -z "$want" ] && [ -z "$want_major" ]; then
        # No target version known: fall back to the newest on the mirror.
        selected="$(printf '%s\n' "$pairs" | sort -V -k1,1 | tail -1)"
    fi

    [ -n "$selected" ] && printf '%s\n' "$selected"
    return 0
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
    local patch_names=()
    while IFS= read -r -d '' f; do
        patch_list+=("$f")
        patch_names+=("$(basename "$f")")
        total_patches=$((total_patches + 1))
    done < <(find "$tmpdir" -name "*.patch" -print0 2>/dev/null)

    for dir in $target_dirs; do
        local target="$PATCHES_DIR/$dir"
        local manifest="$target/.fetched-patches"
        mkdir -p "$target"

        # Drop patches a previous run fetched that this version no longer
        # ships (e.g. one merged upstream). Only files this script created are
        # tracked in the manifest, so hand-written patches stay untouched.
        if [ -f "$manifest" ] && [ "$total_patches" -gt 0 ]; then
            local stale
            while IFS= read -r stale; do
                [ -n "$stale" ] || continue
                [ -f "$target/$stale" ] || continue
                if ! printf '%s\n' "${patch_names[@]}" | grep -qxF -- "$stale"; then
                    rm -f "$target/$stale"
                    info "  removed stale patch: $dir/$stale"
                fi
            done < "$manifest"
        fi

        for f in "${patch_list[@]:-}"; do
            [ -f "$f" ] || continue
            cp "$f" "$target/"
        done

        if [ "$total_patches" -gt 0 ]; then
            printf '%s\n' "${patch_names[@]}" > "$manifest"
        fi
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
  LLVM_VERSION      LLVM version to patch (default: LLVM_VERSION from build.sh)
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

info "  Target LLVM version: $LLVM_VERSION (major: ${LLVM_MAJOR:-any})"

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

    selected="$(select_pkg_version "$pkg_name" "$INI" "$LLVM_VERSION" "$LLVM_MAJOR")"
    if [ -z "$selected" ]; then
        # e.g. libc++abi1 only has ancient 8.0.1 — no longer packaged separately
        info "  $local_dir: skipping $pkg_name (no ${LLVM_MAJOR:-matching} source package)"
        continue
    fi

    version="${selected%% *}"
    src_path="${selected#* }"

    if [ -z "$src_path" ]; then
        err "No 'source:' field for $pkg_name $version in setup.ini"
        FAILURES=$((FAILURES + 1))
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
# Count total patch files recursively (matches how build.sh consumes them).
# Guard against a missing PATCHES_DIR: find would fail and, under pipefail,
# abort the script before printing anything.
if [ -d "$PATCHES_DIR" ]; then
    TOTAL_PATCHES="$(find "$PATCHES_DIR" -name '*.patch' -type f 2>/dev/null | wc -l || true)"
fi
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
