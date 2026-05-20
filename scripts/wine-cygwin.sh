#!/bin/bash
# =============================================================================
# wine-cygwin.sh — Run Cygwin PE/COFF executables under Wine for testing
# =============================================================================
# Searches for cygwin1.dll in the sysroot, sets up WINEPATH, and runs the
# given program under Wine.  Requires wine to be installed on the host.
#
# Usage:
#   ./scripts/wine-cygwin.sh hello.exe
#   ./scripts/wine-cygwin.sh --sysroot=./sysroot test.exe arg1 arg2
#
# The script auto-detects the sysroot by checking, in order:
#   1. --sysroot= argument
#   2. $CYGWIN_SYSROOT environment variable
#   3. ./sysroot (relative to project root)
#   4. ./toolchain/x86_64-pc-cygwin
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

# =============================================================================
# Check that wine is installed
# =============================================================================
check_wine() {
    if ! command -v wine &>/dev/null; then
        echo -e "${RED}ERROR: wine is not installed.${NC}" >&2
        echo "" >&2
        echo "Wine is required to test Cygwin PE/COFF executables on Linux." >&2
        echo "" >&2
        echo "Installation instructions:" >&2
        echo "  Debian/Ubuntu:  sudo dpkg --add-architecture i386 && sudo apt update && sudo apt install wine wine32" >&2
        echo "  Fedora:         sudo dnf install wine" >&2
        echo "  Arch:           sudo pacman -S wine" >&2
        echo "  openSUSE:       sudo zypper install wine" >&2
        echo "" >&2
        echo "Or install Wine from WineHQ for the latest version:" >&2
        echo "  https://wiki.winehq.org/Download" >&2
        exit 1
    fi
}

# =============================================================================
# Find cygwin1.dll — the core Cygwin runtime
# =============================================================================
find_cygwin1() {
    local search_paths=()

    # 1. Explicit --sysroot argument
    if [ -n "${ARG_SYSROOT:-}" ]; then
        search_paths+=("$ARG_SYSROOT/usr/bin/cygwin1.dll")
        search_paths+=("$ARG_SYSROOT/usr/lib/cygwin1.dll")
        search_paths+=("$ARG_SYSROOT/bin/cygwin1.dll")
    fi

    # 2. Env var
    if [ -n "${CYGWIN_SYSROOT:-}" ]; then
        search_paths+=("$CYGWIN_SYSROOT/usr/bin/cygwin1.dll")
        search_paths+=("$CYGWIN_SYSROOT/usr/lib/cygwin1.dll")
        search_paths+=("$CYGWIN_SYSROOT/bin/cygwin1.dll")
    fi

    # 3. Project sysroot
    search_paths+=("$PROJECT_DIR/sysroot/usr/bin/cygwin1.dll")
    search_paths+=("$PROJECT_DIR/sysroot/usr/lib/cygwin1.dll")
    search_paths+=("$PROJECT_DIR/sysroot/bin/cygwin1.dll")

    # 4. Toolchain sysroot
    search_paths+=("$PROJECT_DIR/toolchain/x86_64-pc-cygwin/bin/cygwin1.dll")
    search_paths+=("$PROJECT_DIR/toolchain/x86_64-pc-cygwin/lib/cygwin1.dll")

    # 5. Generic search within 3 levels
    while IFS= read -r -d '' dll; do
        search_paths+=("$dll")
    done < <(find "$PROJECT_DIR" -maxdepth 3 -name cygwin1.dll -print0 2>/dev/null || true)

    for candidate in "${search_paths[@]}"; do
        if [ -f "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done

    echo -e "${RED}ERROR: cygwin1.dll not found.${NC}" >&2
    echo "" >&2
    echo "Searched:" >&2
    for p in "${search_paths[@]}"; do
        echo "  $p" >&2
    done
    echo "" >&2
    echo "Make sure you have built/downloaded the Cygwin sysroot:" >&2
    echo "  ./scripts/fetch-sysroot.sh" >&2
    exit 1
}

# =============================================================================
# Collect all DLL search paths from sysroot
# =============================================================================
collect_winpath() {
    local cygwin1="$1"
    local cygwin_dir
    cygwin_dir="$(dirname "$cygwin1")"
    local paths=("$cygwin_dir")

    # Also add /usr/lib for other DLLs (libstdc++-6.dll, etc.)
    local sysroot_base
    sysroot_base="$(dirname "$(dirname "$cygwin_dir")")"  # go up to sysroot root

    for d in "$sysroot_base/usr/lib" "$sysroot_base/usr/bin" "$sysroot_base/bin"; do
        if [ -d "$d" ] && [ "$d" != "$cygwin_dir" ]; then
            paths+=("$d")
        fi
    done

    # Convert to Windows-style semicolon path (Wine handles Unix paths too)
    local winpath=""
    for p in "${paths[@]}"; do
        if [ -n "$winpath" ]; then
            winpath="$winpath;"
        fi
        # Use Z: drive mapping for absolute paths
        winpath="${winpath}Z:${p}"
    done

    echo "$winpath"
}

# =============================================================================
# Main
# =============================================================================

# Parse --sysroot= argument
ARGS=()
for arg in "$@"; do
    case "$arg" in
        --sysroot=*)
            ARG_SYSROOT="${arg#*=}"
            ;;
        --sysroot)
            echo "Use --sysroot=PATH (with equals sign)" >&2
            exit 1
            ;;
        *)
            ARGS+=("$arg")
            ;;
    esac
done

if [ ${#ARGS[@]} -eq 0 ]; then
    cat << 'EOF'
Usage: wine-cygwin.sh [--sysroot=PATH] program.exe [args...]

  Runs a Cygwin PE/COFF executable under Wine.
  Automatically finds cygwin1.dll and sets up the Wine environment.

Options:
  --sysroot=PATH    Path to Cygwin sysroot (auto-detected if omitted)

Environment:
  CYGWIN_SYSROOT    Alternative way to specify sysroot
  WINEDEBUG         Wine debug level (default: -all)

Examples:
  ./scripts/wine-cygwin.sh build/test-program.exe
  ./scripts/wine-cygwin.sh --sysroot=./sysroot hello.exe arg1 arg2
EOF
    exit 0
fi

echo "================================================================"
echo " Wine Cygwin Runner"
echo "================================================================"

# Step 1: Check wine
check_wine
echo -e "${GREEN}wine: $(wine --version)${NC}"

# Step 2: Find cygwin1.dll
CYGWIN1="$(find_cygwin1)"
echo -e "${GREEN}cygwin1.dll: $CYGWIN1${NC}"

# Step 3: Build WINEPATH
WINEPATH="$(collect_winpath "$CYGWIN1")"
echo -e "${YELLOW}WINEPATH: $WINEPATH${NC}"
export WINEPATH

# Step 4: Run
echo ""
echo -e "${GREEN}Running: ${ARGS[*]}${NC}"
echo "---"

export WINEDEBUG="${WINEDEBUG:--all}"
exec wine "${ARGS[@]}"
