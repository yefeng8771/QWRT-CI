#!/usr/bin/env bash
set -euo pipefail
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ROOT="$TMP/wrt"
mkdir -p "$ROOT/package"; touch "$ROOT/Config.in"
INSTALL=(bash "$REPO/Scripts/install-libffi.sh" "$ROOT")
"${INSTALL[@]}"
cmp "$REPO/package/libffi/Makefile" "$ROOT/package/libs/libffi/Makefile"
# Idempotent, including invocation from a package CWD.
(cd "$ROOT/package" && "${INSTALL[@]}")
cmp "$REPO/package/libffi/Makefile" "$ROOT/package/libs/libffi/Makefile"
echo 'PASS missing + repeated injection'
echo '# upstream core sentinel' > "$ROOT/package/libs/libffi/Makefile"
"${INSTALL[@]}"
grep -qx '# upstream core sentinel' "$ROOT/package/libs/libffi/Makefile"
echo 'PASS preserve upstream core'
rm -rf "$ROOT/package/libs/libffi"
mkdir -p "$ROOT/feeds/packages/libs/libffi"
echo '# upstream feed sentinel' > "$ROOT/feeds/packages/libs/libffi/Makefile"
"${INSTALL[@]}"
test ! -e "$ROOT/package/libs/libffi"
grep -qx '# upstream feed sentinel' "$ROOT/feeds/packages/libs/libffi/Makefile"
echo 'PASS preserve upstream feed'
rm -rf "$ROOT/feeds"
mkdir -p "$ROOT/package/feeds/packages/libffi"
echo '# installed feed sentinel' > "$ROOT/package/feeds/packages/libffi/Makefile"
"${INSTALL[@]}"
test ! -e "$ROOT/package/libs/libffi"
echo 'PASS preserve installed feed'
rm -rf "$ROOT/package/feeds"
mkdir -p "$ROOT/package/libs/libffi"
if "${INSTALL[@]}"; then echo 'ERROR accepted empty existing directory'; exit 1; fi
echo 'PASS reject damaged directory'
rmdir "$ROOT/package/libs/libffi"
ln -s "$TMP/missing" "$ROOT/package/libs/libffi"
if "${INSTALL[@]}"; then echo 'ERROR accepted dangling symlink'; exit 1; fi
echo 'PASS reject dangling symlink'
if bash "$REPO/Scripts/install-libffi.sh" "$TMP"; then echo 'ERROR accepted invalid root'; exit 1; fi
echo 'PASS reject invalid tree'
printf '%s  %s\n' 2bab7a694f4c59d2e28769e0060bcf9951ec6c5b6fbff7e8f4776e40aae62a12 "$REPO/package/libffi/Makefile" | sha256sum -c -
grep -Fq '$(eval $(call HostBuild))' "$REPO/package/libffi/Makefile"
grep -Fq '$(PKG_BUILD_DIR)/$(GNU_TARGET_NAME)*/fficonfig.h' "$REPO/package/libffi/Makefile"
grep -Fq 'bash "$GW/Scripts/install-libffi.sh" "$WRT_ROOT"' "$REPO/Scripts/PRIVATE.sh"
bash -n "$REPO/Scripts/PRIVATE.sh" "$REPO/Scripts/install-libffi.sh"
echo 'PASS pinned recipe + host/target/header + private hook + shell syntax'
