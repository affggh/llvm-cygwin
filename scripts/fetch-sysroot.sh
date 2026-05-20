#!/bin/bash
# =============================================================================
# fetch-sysroot.sh — Download Cygwin packages to create a cross-compile sysroot
# =============================================================================
# Downloads base Cygwin binary packages from a mirror and extracts headers,
# libraries, and runtime files to create a sysroot for llvm-cygwin.
#
# Usage:
#   ./scripts/fetch-sysroot.sh                    # download to ./sysroot
#   ./scripts/fetch-sysroot.sh /path/to/sysroot   # custom location
#   CYGWIN_MIRROR=https://... ./scripts/fetch-sysroot.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SYSROOT="${1:-$PROJECT_DIR/sysroot}"

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
# Packages to download
# Format: "setup.ini_section:Display label"
# =============================================================================
declare -a PACKAGES=(
    "cygwin:Cygwin runtime DLL and cygwin1.dll"
    "cygwin-devel:Cygwin headers, crt*.o, libcygwin.a"
    "w32api-headers:Windows API headers (win32api)"
    "w32api-runtime:Windows API import libraries"
    "gcc-core:GCC runtime (libgcc.a, libstdc++.a, crtbegin.o)"
    "libiconv-devel:libiconv.a, libcharset.a, iconv.h"
    "libintl-devel:libintl.a, libintl.h"
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

    if command -v zstd &>/dev/null; then
        HAVE_ZSTD=1
    else
        info "zstd not found — gcc-core (.zst) may fail. Install zstd."
        HAVE_ZSTD=0
    fi

    if [ "$missing" -eq 1 ]; then
        exit 1
    fi
}

# =============================================================================
# Download a file
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
# Extract a package archive with auto-detection of compression format
# =============================================================================
extract_pkg() {
    local archive="$1"
    local dest="$2"

    case "$archive" in
        *.tar.xz)  tar -xJf "$archive" -C "$dest" 2>/dev/null ;;
        *.tar.zst) tar --zstd -xf "$archive" -C "$dest" 2>/dev/null ;;
        *.tar.bz2) tar -xjf "$archive" -C "$dest" 2>/dev/null ;;
        *.tar.gz)  tar -xzf "$archive" -C "$dest" 2>/dev/null ;;
        *)
            err "Unknown archive format: $archive"
            return 1
            ;;
    esac
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
# Parse setup.ini for the latest install path of a package
# =============================================================================
parse_install_path() {
    local pkg="$1"
    local ini="$2"

    awk -v pkg="@ $pkg" '
        $0 == pkg { found=1; next }
        found && /^@ /   { exit }
        found && /^\[/   { exit }
        found && /^install:/ {
            gsub(/^install: */, "")
            print $1
            exit
        }
    ' "$ini"
}

# =============================================================================
# Download and extract a single package
# =============================================================================
fetch_pkg() {
    local name="$1"
    local display="$2"
    local relpath="$3"

    if [ -z "$relpath" ]; then
        err "  Package '$name' not found in setup.ini"
        return 1
    fi

    local url="${CYGWIN_MIRROR}/${relpath}"
    local fname
    fname="$(basename "$relpath")"
    local tmpfile
    tmpfile="$(mktemp /tmp/cygwin-pkg-XXXXXX-${fname})"

    info "  $display"
    info "  $url"

    if ! download "$url" "$tmpfile" "$fname"; then
        rm -f "$tmpfile"
        return 1
    fi

    info "  Extracting..."
    mkdir -p "$SYSROOT"
    if extract_pkg "$tmpfile" "$SYSROOT"; then
        local size
        size="$(du -h "$tmpfile" | cut -f1)"
        info "  OK (${size})"
        rm -f "$tmpfile"
        return 0
    else
        err "  Extraction failed for $fname"
        err "  The archive may be corrupted or a required decompressor is missing."
        rm -f "$tmpfile"
        return 1
    fi
}

# =============================================================================
# Download all packages
# =============================================================================
resolve_and_fetch() {
    step "Step 1: Download setup.ini"
    check_tools

    local ini
    ini="$(mktemp /tmp/cygwin-setup-XXXXXX.ini)"
    download_setup_ini "$ini"

    step "Step 2: Resolve and download packages"

    local failures=0
    local total=0
    for entry in "${PACKAGES[@]}"; do
        local pkg_label="${entry%%:*}"
        local display="${entry#*:}"

        info "Resolving $pkg_label ($display)..."
        local path
        path="$(parse_install_path "$pkg_label" "$ini")"

        if [ -z "$path" ]; then
            err "  Package '$pkg_label' not found in setup.ini"
            failures=$((failures + 1))
            continue
        fi

        if fetch_pkg "$pkg_label" "$display" "$path"; then
            total=$((total + 1))
        else
            failures=$((failures + 1))
        fi
    done

    rm -f "$ini"

    echo ""
    info "Downloaded $total packages successfully."
    if [ "$failures" -gt 0 ]; then
        err "$failures package(s) failed."
        echo ""
        echo "  Make sure CYGWIN_MIRROR is correct: $CYGWIN_MIRROR"
        echo "  Try a different mirror:"
        echo "    CYGWIN_MIRROR=https://mirrors.ustc.edu.cn/cygwin $0"
        exit 1
    fi
}

# =============================================================================
# Post-processing: create target-triple symlinks, remove .exe, etc.
# =============================================================================
post_process() {
    step "Step 3: Post-process sysroot"

    local TRIPLE="x86_64-pc-cygwin"
    local TRIPLE32="i686-pc-cygwin"

    info "Creating $TRIPLE symlinks..."
    mkdir -p "$SYSROOT/usr/$TRIPLE/include" "$SYSROOT/usr/$TRIPLE/lib"

    if [ -d "$SYSROOT/usr/include" ]; then
        for h in "$SYSROOT"/usr/include/*; do
            [ -e "$h" ] || continue
            ln -sf "../../../usr/include/$(basename "$h")" "$SYSROOT/usr/$TRIPLE/include/" 2>/dev/null || true
        done
    fi

    if [ -d "$SYSROOT/usr/lib" ]; then
        for l in "$SYSROOT"/usr/lib/*.a "$SYSROOT"/usr/lib/*.o; do
            [ -e "$l" ] || continue
            ln -sf "../../../usr/lib/$(basename "$l")" "$SYSROOT/usr/$TRIPLE/lib/" 2>/dev/null || true
        done
    fi

    info "Creating $TRIPLE32 symlinks..."
    mkdir -p "$SYSROOT/usr/$TRIPLE32/include" "$SYSROOT/usr/$TRIPLE32/lib"
    if [ -d "$SYSROOT/usr/include" ]; then
        for h in "$SYSROOT"/usr/include/*; do
            [ -e "$h" ] || continue
            ln -sf "../../../usr/include/$(basename "$h")" "$SYSROOT/usr/$TRIPLE32/include/" 2>/dev/null || true
        done
    fi
    if [ -d "$SYSROOT/usr/lib" ]; then
        for l in "$SYSROOT"/usr/lib/*.a "$SYSROOT"/usr/lib/*.o; do
            [ -e "$l" ] || continue
            ln -sf "../../../usr/lib/$(basename "$l")" "$SYSROOT/usr/$TRIPLE32/lib/" 2>/dev/null || true
        done
    fi

    # Report cygwin1.dll location
    if [ -f "$SYSROOT/usr/bin/cygwin1.dll" ]; then
        info "cygwin1.dll: $SYSROOT/usr/bin/cygwin1.dll"
    elif [ -f "$SYSROOT/usr/lib/cygwin1.dll" ]; then
        info "cygwin1.dll: $SYSROOT/usr/lib/cygwin1.dll"
    else
        info "cygwin1.dll not found (may be in different location)"
    fi

    # Cleanup
    info "Removing .exe files (not needed on Linux)..."
    find "$SYSROOT" -name "*.exe" -type f -delete 2>/dev/null || true
    rm -rf "$SYSROOT/usr/sbin" 2>/dev/null || true

    # Summary
    echo ""
    info "Sysroot summary for $SYSROOT:"
    echo "  Headers  : $(find "$SYSROOT/usr/include" -maxdepth 1 -type d 2>/dev/null | wc -l) directories"
    echo "  Libraries: $(find "$SYSROOT/usr/lib" -name '*.a' -o -name '*.o' 2>/dev/null | wc -l) files"
    DLL=$(find "$SYSROOT" -name cygwin1.dll -type f 2>/dev/null | head -1)
    [ -n "$DLL" ] && echo "  cygwin1.dll: $DLL" || echo "  cygwin1.dll: NOT FOUND"
}

# =============================================================================
# Main
# =============================================================================
for arg in "$@"; do
    case "$arg" in
        --help|-h)
            echo "Usage: $0 [sysroot-path]"
            echo ""
            echo "Downloads Cygwin packages to create a cross-compile sysroot."
            echo ""
            echo "Environment:"
            echo "  CYGWIN_MIRROR   Cygwin mirror URL (default: mirrors.kernel.org)"
            echo "  http_proxy      HTTP proxy"
            exit 0
            ;;
    esac
done

echo "================================================================"
echo " Fetching Cygwin Sysroot"
echo " Mirror : $CYGWIN_MIRROR"
echo " Target : $SYSROOT"
echo "================================================================"

resolve_and_fetch
post_process

echo ""
echo -e "${GREEN}Sysroot created at: $SYSROOT${NC}"
echo "Use with: --sysroot=$SYSROOT"
