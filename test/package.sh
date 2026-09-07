#!/usr/bin/env bash
# Build the sample app and package it with Velopack, then check that vpk
# actually produced a release. Used by .github/workflows/package.yml on Linux,
# macOS and Windows; run it locally the same way:
#
#     ./test/package.sh
#
set -euo pipefail

cd "$(dirname "$0")/sample"

# mksquashfs (needed for Linux AppImages) is a lazy dependency, so fetch the
# whole tree up front rather than have the first build quietly skip it.
zig build --fetch=all

zig build package -Dinstall-vpk=true

out=zig-out/desktop
echo "--- $out ---"
ls -l "$out"

have() { compgen -G "$out/$1" >/dev/null; }
require() {
    for pattern in "$@"; do
        have "$pattern" && return 0
    done
    echo "package.sh: expected one of [$*] in $out" >&2
    exit 1
}

require '*.nupkg'
require 'RELEASES*'
# Whatever the platform calls its installable artifact.
require '*Setup*' '*Portable*' '*.AppImage' '*.pkg' '*.dmg'

echo "package.sh: OK"
