#!/bin/bash
# PRIVATE.sh — QWRT-CI 私有注入脚本 (被 VIKINGYFY 上游 Packages.sh 在 "Custom Packages" 步 source)
#
# 走 VIKINGYFY 原生 PRIVATE.sh 钩子 (Packages.sh: `source $GITHUB_WORKSPACE/Scripts/PRIVATE.sh`),
# 不修改上游任何文件。CWD = $GITHUB_WORKSPACE/wrt/package/  (wrt 根 = ..)
#
# 职责 (在 make 之前完成全部资产就位):
#   [1] 注入 stundeck 包源 + 指向 prebuilt 二进制的 stundeck-build.mk
#   [2] clone muink natmapt + luci-app-natmapt (immortalwrt feeds 无 natmapt, 必须自带)
#   [3] 合并 files/ 覆盖层到 wrt/files/ (sing-box init/config + uci-defaults)
#   [4] 下载注入 reF1nd sing-box prerelease (linux-arm64-musl, with_ebpf) 到 wrt/files/usr/bin/
#   [5] sed 改 feeds/syncthing Makefile 指向上游 rc v2.1.4-rc.2 (feed 默认锁 stable 2.1.3, sha256 已校验)
#
# 时序: 本步在 .config 生成之前 → 不能读 .config 探测架构, 故硬编码 aarch64
#        (jdcloud_re-cs-02 = IPQ60XX = ARMv8/aarch64)
set -euo pipefail

GW="${GITHUB_WORKSPACE:?GITHUB_WORKSPACE not set}"
WRT_ROOT=".."            # wrt/package/ 的父 = wrt 根 (TOPDIR)
WRT_FILES="${WRT_ROOT}/files"

echo "[qwrt] === PRIVATE.sh start (CWD=$(pwd)) ==="

# jq 依赖 (sing-box 资产过滤用)
if ! command -v jq >/dev/null 2>&1; then
    echo "[qwrt] jq not found, installing..."
    sudo apt-get update -qq && sudo apt-get install -y -qq jq
fi

# ============ [1] StunDeck opkg 包 + release 裸二进制 ============
echo "[qwrt] [1/4] Injecting stundeck opkg package + pulling latest release binaries..."

# [1a] opkg 包源 (init/config/Makefile + DEPENDS natmapt) 来自本仓
if [ -d "$GW/package/stundeck" ]; then
    rm -rf ./stundeck
    cp -a "$GW/package/stundeck" ./stundeck
    echo "[qwrt]   stundeck package -> wrt/package/stundeck"
else
    echo "[qwrt]   ERROR: $GW/package/stundeck not found" >&2; exit 1
fi

# [1b] stundeck 二进制: 从 yefeng8771/stundeck 最新 release 拉裸二进制 tarball
#   (sing-box[4] 风格: 构建时下载, 不提交二进制到本仓, 自动跟踪上游 release)
#   与 sing-box 不同: stundeck 是 opkg 包, 二进制由后续 make package/install 步
#   从 STUNDECK_BIN_DIR 拷贝 -> 必须用持久目录 (不能用 trap 清理的 mktemp).
STUNDECK_REPO="yefeng8771/stundeck"
STUNDECK_RELEASE_ARCH="arm64"
GH_HEADERS=(-H 'Accept: application/vnd.github+json')
if [ -n "${GITHUB_TOKEN:-}" ]; then
    GH_HEADERS+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
fi

# 最新 (非 prerelease/draft) release
STUNDECK_REL_JSON=$(curl -fsSL "${GH_HEADERS[@]}" \
    "https://api.github.com/repos/${STUNDECK_REPO}/releases/latest")
STUNDECK_TAG=$(printf '%s' "$STUNDECK_REL_JSON" | jq -r '.tag_name')
if [ -z "$STUNDECK_TAG" ] || [ "$STUNDECK_TAG" = "null" ]; then
    echo "[qwrt]   ERROR: cannot resolve latest stundeck release tag" >&2; exit 1
fi
echo "[qwrt]   stundeck latest release: ${STUNDECK_TAG}"

STUNDECK_TARBALL_URL=$(printf '%s' "$STUNDECK_REL_JSON" | jq -r --arg arch "$STUNDECK_RELEASE_ARCH" \
    '.assets[] | select(.name | endswith("-linux-" + $arch + ".tar.gz")) | .browser_download_url')
if [ -z "$STUNDECK_TARBALL_URL" ] || [ "$STUNDECK_TARBALL_URL" = "null" ]; then
    echo "[qwrt]   ERROR: no *-linux-${STUNDECK_RELEASE_ARCH}.tar.gz asset in ${STUNDECK_REPO} ${STUNDECK_TAG}" >&2; exit 1
fi
echo "[qwrt]   asset: $(basename "$STUNDECK_TARBALL_URL")"

STUNDECK_BIN_DIR="${GW}/stundeck-prebuilt"
rm -rf "$STUNDECK_BIN_DIR"
mkdir -p "$STUNDECK_BIN_DIR"
curl -fsSL "${GH_HEADERS[@]}" "$STUNDECK_TARBALL_URL" -o "$STUNDECK_BIN_DIR/stundeck.tar.gz"
tar -xzf "$STUNDECK_BIN_DIR/stundeck.tar.gz" -C "$STUNDECK_BIN_DIR"
rm -f "$STUNDECK_BIN_DIR/stundeck.tar.gz"
if [ ! -f "$STUNDECK_BIN_DIR/stundeck" ] || [ ! -f "$STUNDECK_BIN_DIR/stundeck-notify" ]; then
    echo "[qwrt]   ERROR: tarball missing stundeck / stundeck-notify" >&2; exit 1
fi
echo "[qwrt]   stundeck binaries -> ${STUNDECK_BIN_DIR} (stundeck + stundeck-notify)"

# stundeck Makefile 顶: -include $(TOPDIR)/stundeck-build.mk  (TOPDIR = wrt 根 = ..)
# version 从 release tag 去掉前导 'v': v0.1.202609021106 -> 0.1.202609021106
STUNDECK_VERSION="${STUNDECK_TAG#v}"
{
    echo "STUNDECK_BIN_DIR:=${STUNDECK_BIN_DIR}"
    echo "STUNDECK_VERSION:=${STUNDECK_VERSION}"
} > "${WRT_ROOT}/stundeck-build.mk"
echo "[qwrt]   stundeck-build.mk -> ${WRT_ROOT}/stundeck-build.mk (BIN_DIR=${STUNDECK_BIN_DIR}, VER=${STUNDECK_VERSION})"


# ============ [2] NATMapt + LuCI (muink, feeds 无) ============
echo "[qwrt] [2/4] Cloning muink natmapt + luci-app-natmapt..."
# muink/openwrt-natmapt: 包名 natmapt, 但安装二进制名为 natmap
#   (Makefile: INSTALL_BIN $(PKG_BUILD_DIR)/bin/natmap -> /usr/bin/)
#   与 stundeck DEPENDS:+natmapt 及 init STUNDECK_NATMAP_BINARY=/usr/bin/natmap 完全一致, 无需 sed。
if [ ! -d "./natmapt" ]; then
    git clone --depth=1 https://github.com/muink/openwrt-natmapt.git ./natmapt
    echo "[qwrt]   natmapt -> wrt/package/natmapt"
fi
if [ ! -d "./luci-app-natmapt" ]; then
    git clone --depth=1 https://github.com/muink/luci-app-natmapt.git ./luci-app-natmapt
    echo "[qwrt]   luci-app-natmapt -> wrt/package/luci-app-natmapt"
fi

# ============ [3] files/ 覆盖层 ============
echo "[qwrt] [3/4] Merging files/ overlay into wrt/files/..."
if [ -d "$GW/files" ]; then
    mkdir -p "$WRT_FILES"
    cp -a "$GW/files/." "$WRT_FILES/"
    echo "[qwrt]   $GW/files/. -> ${WRT_FILES}/"
else
    echo "[qwrt]   NOTE: $GW/files not found, skipping overlay"
fi

# ============ [4] sing-box (reF1nd prerelease, with_ebpf) ============
echo "[qwrt] [4/4] Downloading & injecting reF1nd sing-box prerelease..."
RELEASE_ARCH="arm64"     # jdcloud_re-cs-02 = aarch64 (硬编码, .config 尚未生成)

GH_HEADERS=(-H 'Accept: application/vnd.github+json')
if [ -n "${GITHUB_TOKEN:-}" ]; then
    GH_HEADERS+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

SINGBOX_URL=$(curl -fsSL "${GH_HEADERS[@]}" \
    "https://api.github.com/repos/reF1nd/sing-box-releases/releases" \
    | jq -r --arg arch "$RELEASE_ARCH" '
        [ .[]
            | select(.draft == false and .prerelease == true)
            | .assets[]?
            | select(.name | endswith("-linux-" + $arch + "-musl.tar.gz"))
            | .browser_download_url
        ][0]')

if [ -z "$SINGBOX_URL" ] || [ "$SINGBOX_URL" = "null" ]; then
    echo "[qwrt]   ERROR: sing-box prerelease not found for arch=$RELEASE_ARCH" >&2; exit 1
fi

SINGBOX_ASSET=$(basename "$SINGBOX_URL")
echo "[qwrt]   asset: $SINGBOX_ASSET"
curl -fL "$SINGBOX_URL" -o "$TMP_DIR/$SINGBOX_ASSET"
tar -xzf "$TMP_DIR/$SINGBOX_ASSET" -C "$TMP_DIR"
SINGBOX_BIN=$(find "$TMP_DIR" -type f -name sing-box | head -n 1)
if [ -z "$SINGBOX_BIN" ] || [ ! -f "$SINGBOX_BIN" ]; then
    echo "[qwrt]   ERROR: sing-box binary not found in $SINGBOX_ASSET" >&2; exit 1
fi

# eBPF 验证 (软检查: 本步 go 可能未装; reF1nd prerelease beta 可靠含 with_ebpf)
if command -v go >/dev/null 2>&1; then
    if go version -m "$SINGBOX_BIN" 2>&1 | grep -q 'with_ebpf'; then
        echo "[qwrt]   sing-box with_ebpf: VERIFIED"
    else
        echo "[qwrt]   WARNING: sing-box may lack with_ebpf (proceeding)" >&2
    fi
else
    echo "[qwrt]   NOTE: go not installed at this step; skip eBPF verify (reF1nd prerelease reliably includes with_ebpf)"
fi

mkdir -p "$WRT_FILES/usr/bin"
install -m 0755 "$SINGBOX_BIN" "$WRT_FILES/usr/bin/sing-box"
echo "[qwrt]   sing-box -> ${WRT_FILES}/usr/bin/sing-box"

# ============ [5] Patch syncthing feed Makefile to RC v2.1.4-rc.2 ============
# immortalwrt feed 默认锁 stable 2.1.3; 用户要上游 rc 2.1.4-rc.2, 故 sed 强改
# PKG_VERSION+PKG_HASH(rc source tarball sha256 已本地校验). 时序: feeds install 后, defconfig 前.
echo "[qwrt] [5/5] Patching syncthing feed Makefile to RC v2.1.4-rc.2..."
SYNCTHING_MK=""
if [ -d "${WRT_ROOT}/feeds" ]; then
    SYNCTHING_MK=$(find "${WRT_ROOT}/feeds" -path '*/syncthing/Makefile' -type f 2>/dev/null | head -n 1 || true)
fi
if [ -n "$SYNCTHING_MK" ]; then
    sed -i \
        -e 's|^PKG_VERSION:=.*|PKG_VERSION:=2.1.4-rc.2|' \
        -e 's|^PKG_HASH:=.*|PKG_HASH:=bf51db8f7ba978e48580e175aeeb93c2c18e53cde8fac439a2ac0277007c63b8|' \
        "$SYNCTHING_MK"
    echo "[qwrt]   patched: $SYNCTHING_MK"
    if grep -qE '^PKG_VERSION:=2.1.4-rc.2' "$SYNCTHING_MK"; then
        grep -E '^(PKG_VERSION|PKG_HASH):=' "$SYNCTHING_MK"
        echo "[qwrt]   syncthing -> rc v2.1.4-rc.2 (source sha256 verified)"
    else
        echo "[qwrt]   ERROR: sed did not set PKG_VERSION=2.1.4-rc.2" >&2; exit 1
    fi
else
    echo "[qwrt]   ERROR: syncthing Makefile not found in ${WRT_ROOT}/feeds/" >&2; exit 1
fi

echo "[qwrt] === PRIVATE.sh done ==="
