#!/usr/bin/env bash
# Download msvcup (macOS/Linux), install MSVC + Windows SDK into the supplied
# install directory, and emit zig-libc-{x64,arm64}.ini next to it.
#
# Invoked from build.zig via velopack.addMsvcupSetupStep(b, install_dir).
# The build script forwards three env vars:
#
#   VELOPACK_ZIG_ENV_FILE    — path to tools/msvcup.env (pinned tag + packages)
#   VELOPACK_ZIG_GEN_SCRIPT  — path to tools/gen_zig_libc_msvc.zig
#   VELOPACK_ZIG_ZIG         — path to the zig binary to use
#
# Single positional argument: <install-dir> (absolute or build-root-relative).
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: setup-msvc.sh <install-dir>" >&2
  exit 1
fi
INSTALL_ROOT="$1"

ENV_FILE="${VELOPACK_ZIG_ENV_FILE:?missing VELOPACK_ZIG_ENV_FILE}"
GEN_SCRIPT="${VELOPACK_ZIG_GEN_SCRIPT:?missing VELOPACK_ZIG_GEN_SCRIPT}"
ZIG="${VELOPACK_ZIG_ZIG:-zig}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "error: missing $ENV_FILE" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$ENV_FILE"

: "${MSVCUP_TAG:?MSVCUP_TAG not set in $ENV_FILE}"
: "${MSVCUP_PACKAGES:?MSVCUP_PACKAGES not set in $ENV_FILE}"

OS="$(uname -s)"
MARCH="$(uname -m)"
case "$OS" in
  Darwin) OSL=macos ;;
  Linux) OSL=linux ;;
  *) echo "error: unsupported OS '$OS' (use setup-msvc.ps1 on Windows)" >&2; exit 1 ;;
esac
case "$MARCH" in
  x86_64|amd64) DL_ARCH=x86_64 ;;
  arm64|aarch64) DL_ARCH=aarch64 ;;
  *) echo "error: unsupported machine '$MARCH'" >&2; exit 1 ;;
esac

mkdir -p "$INSTALL_ROOT"
TOOL_BIN="$INSTALL_ROOT/msvcup-bin"
mkdir -p "$TOOL_BIN"
MSVCUP="$TOOL_BIN/msvcup"
ARCHIVE="msvcup-${DL_ARCH}-${OSL}.tar.gz"
URL="https://github.com/marler8997/msvcup/releases/download/${MSVCUP_TAG}/${ARCHIVE}"

if [[ ! -x "$MSVCUP" ]]; then
  echo "Downloading msvcup ($ARCHIVE)..."
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  curl -fsSL -o "$TMP/$ARCHIVE" "$URL"
  tar -xzf "$TMP/$ARCHIVE" -C "$TOOL_BIN"
  chmod +x "$MSVCUP" 2>/dev/null || true
fi

# An install is "complete" only when the SDK headers (ucrt/stdlib.h), the SDK
# import libs (um/<arch>/kernel32.Lib), and the MSVC toolchain (VC/Tools/MSVC)
# are all present.  Earlier versions of this script only checked the parent
# directories, which falsely treated interrupted/partial installs as complete.
needs_install=0
[[ -d "$INSTALL_ROOT/VC/Tools/MSVC" ]] || needs_install=1
# Use globs because the SDK version subdirectory name varies (e.g. 10.0.22621.0).
shopt -s nullglob
have_ucrt_stdlib=("$INSTALL_ROOT/Windows Kits/10/Include"/*/ucrt/stdlib.h)
have_kernel32_x64=("$INSTALL_ROOT/Windows Kits/10/Lib"/*/um/x64/kernel32.Lib)
shopt -u nullglob
[[ ${#have_ucrt_stdlib[@]} -gt 0 ]] || needs_install=1
[[ ${#have_kernel32_x64[@]} -gt 0 ]] || needs_install=1

if [[ $needs_install -eq 1 ]]; then
  echo "Running msvcup install into $INSTALL_ROOT (first run can take several minutes)..."
  "$MSVCUP" install "$INSTALL_ROOT" --manifest-update-off ${MSVCUP_PACKAGES}
fi

# Vendor GameInput.h from MSVCUP_GAMEINPUT_PACKAGE into the base SDK's um/.
# The base SDK (22621) lacks it; the package that has it (26100) has a broken
# shared/ so it can't be installed into the main tree.  Install it to a scratch
# dir, copy just the one header, discard the rest.  Idempotent: skipped once the
# header is in place, so re-runs don't re-download the 26100 package.
shopt -s nullglob
main_um_dirs=("$INSTALL_ROOT/Windows Kits/10/Include"/*/um)
shopt -u nullglob
if [[ ${#main_um_dirs[@]} -gt 0 && -n "${MSVCUP_GAMEINPUT_PACKAGE:-}" ]]; then
  main_um="${main_um_dirs[0]}"
  if [[ ! -f "$main_um/GameInput.h" ]]; then
    echo "Vendoring GameInput.h from $MSVCUP_GAMEINPUT_PACKAGE..."
    GI_TMP="$INSTALL_ROOT/.gameinput-src"
    rm -rf "$GI_TMP"
    "$MSVCUP" install "$GI_TMP" --manifest-update-off "$MSVCUP_GAMEINPUT_PACKAGE"
    shopt -s nullglob
    gi_src=("$GI_TMP/Windows Kits/10/Include"/*/um/GameInput.h)
    shopt -u nullglob
    if [[ ${#gi_src[@]} -gt 0 ]]; then
      cp "${gi_src[0]}" "$main_um/GameInput.h"
      echo "  -> $main_um/GameInput.h"
    else
      echo "warning: GameInput.h not found in $MSVCUP_GAMEINPUT_PACKAGE" >&2
    fi
    rm -rf "$GI_TMP"
  fi
fi

echo "Writing zig libc manifests..."
"$ZIG" run "$GEN_SCRIPT" -- "$INSTALL_ROOT" x64 "$INSTALL_ROOT/zig-libc-x64.ini"
"$ZIG" run "$GEN_SCRIPT" -- "$INSTALL_ROOT" arm64 "$INSTALL_ROOT/zig-libc-arm64.ini"
echo "Done. zig-libc-*.ini ready under $INSTALL_ROOT/"
