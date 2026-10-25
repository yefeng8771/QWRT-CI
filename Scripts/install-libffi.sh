#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Fallback for main trees predating the packages -> core libffi migration.
# Run after feeds install, before defconfig. Never replace an upstream recipe.
set -euo pipefail
ROOT="${1:?usage: install-libffi.sh OPENWRT_ROOT}"
ASSETS="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test -f "$ROOT/Config.in" && test -d "$ROOT/package" || {
    echo '[qwrt] ERROR: not an OpenWrt source root' >&2; exit 1;
}
for RECIPE in "$ROOT/package/libs/libffi/Makefile" \
              "$ROOT/feeds/packages/libs/libffi/Makefile" \
              "$ROOT/package/feeds/packages/libffi/Makefile"; do
    if [ -f "$RECIPE" ]; then
        echo "[qwrt] libffi already provided: $RECIPE (unchanged)"
        exit 0
    fi
done
DEST="$ROOT/package/libs/libffi"
# Refuse to clobber an unexpected directory/symlink, including dangling links.
if [ -e "$DEST" ] || [ -L "$DEST" ]; then
    echo "[qwrt] ERROR: $DEST exists without a usable Makefile" >&2; exit 1
fi
SOURCE="$ASSETS/package/libffi/Makefile"
test -s "$SOURCE"
mkdir -p "$ROOT/package/libs"
mkdir "$DEST"
cp "$SOURCE" "$DEST/Makefile"
echo '[qwrt] injected pinned libffi 3.4.7 fallback (host + target)'
