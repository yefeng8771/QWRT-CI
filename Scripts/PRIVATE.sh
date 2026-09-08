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
#   [4] 下载注入 reF1nd sing-box (linux-arm64-musl, with_ebpf) 到 wrt/files/usr/bin/
#   [5] sed 改 feeds/syncthing Makefile 指向上游 rc v2.1.4-rc.2 (feed 默认锁 stable 2.1.3, sha256 已校验)
#
# 时序: 本步在 .config 生成之前 → 不能读 .config 探测架构, 故硬编码 aarch64
#        (jdcloud_re-cs-02 = IPQ60XX = ARMv8/aarch64)
#
# 版本来源: 全部从 .github/packages.json 读取, 不再运行时动态解析。
#           新增/调整依赖只改 packages.json, 不动本文件。
set -euo pipefail

GW="${GITHUB_WORKSPACE:?GITHUB_WORKSPACE not set}"
WRT_ROOT=".."            # wrt/package/ 的父 = wrt 根 (TOPDIR)
WRT_FILES="${WRT_ROOT}/files"
MANIFEST="${GW}/.github/packages.json"

echo "[qwrt] === PRIVATE.sh start (CWD=$(pwd)) ==="

# jq 依赖 (清单解析用)
if ! command -v jq >/dev/null 2>&1; then
    echo "[qwrt] jq not found, installing..."
    sudo apt-get update -qq && sudo apt-get install -y -qq jq
fi

# 断言清单存在
test -f "$MANIFEST" || { echo "[qwrt]   ERROR: $MANIFEST not found" >&2; exit 1; }

# ============ [1] StunDeck opkg 包 + release 裸二进制 ============
echo "[qwrt] [1/4] Injecting stundeck opkg package + pulling release binaries..."

# [1a] opkg 包源 (init/config/Makefile + DEPENDS natmapt) 来自本仓
if [ -d "$GW/package/stundeck" ]; then
    rm -rf ./stundeck
    cp -a "$GW/package/stundeck" ./stundeck
    echo "[qwrt]   stundeck package -> wrt/package/stundeck"
else
    echo "[qwrt]   ERROR: $GW/package/stundeck not found" >&2; exit 1
fi

# [1b] stundeck 二进制: 从清单读 currentTag, 用固定 URL 下载 + sha256 校验
#   (sing-box[4] 风格: 构建时下载, 不提交二进制到本仓)
#   与 sing-box 不同: stundeck 是 opkg 包, 二进制由后续 make package/install 步
#   从 STUNDECK_BIN_DIR 拷贝 -> 必须用持久目录 (不能用 trap 清理的 mktemp).
STUNDECK_REPO="yefeng8771/stundeck"
STUNDECK_TAG="$(jq -r '.githubRelease[] | select(.name == "stundeck") | .currentTag' "$MANIFEST")"
STUNDECK_SHA256="$(jq -r '.githubRelease[] | select(.name == "stundeck") | .currentSha256' "$MANIFEST")"
test -n "$STUNDECK_TAG" || { echo "[qwrt]   ERROR: stundeck currentTag is empty in $MANIFEST" >&2; exit 1; }
test -n "$STUNDECK_SHA256" || { echo "[qwrt]   ERROR: stundeck currentSha256 is empty in $MANIFEST" >&2; exit 1; }
echo "[qwrt]   stundeck pinned version: ${STUNDECK_TAG}"

GH_HEADERS=(-H 'Accept: application/vnd.github+json')
if [ -n "${GITHUB_TOKEN:-}" ]; then
    GH_HEADERS+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
fi

STUNDECK_BIN_DIR="${GW}/stundeck-prebuilt"
rm -rf "$STUNDECK_BIN_DIR"
mkdir -p "$STUNDECK_BIN_DIR"

# 用 gh 下载或 curl 拼固定 URL
# GitHub release download URL: https://github.com/{owner}/{repo}/releases/download/{tag}/{asset}
STUNDECK_ASSET="stundeck-linux-arm64.tar.gz"
STUNDECK_DL_URL="https://github.com/${STUNDECK_REPO}/releases/download/${STUNDECK_TAG}/${STUNDECK_ASSET}"
echo "[qwrt]   downloading: ${STUNDECK_DL_URL}"
curl -fsSL "${GH_HEADERS[@]}" "$STUNDECK_DL_URL" -o "$STUNDECK_BIN_DIR/stundeck.tar.gz"

# sha256 校验
echo "${STUNDECK_SHA256}  ${STUNDECK_BIN_DIR}/stundeck.tar.gz" | sha256sum -c \
    || { echo "[qwrt]   ERROR: stundeck tarball sha256 mismatch" >&2; exit 1; }
echo "[qwrt]   sha256 verified"

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

# 从清单读取 git commit
NATMAPT_COMMIT="$(jq -r '.gitRepo[] | select(.name == "natmapt") | .currentCommit' "$MANIFEST")"
LUCI_NATMAPT_COMMIT="$(jq -r '.gitRepo[] | select(.name == "luci-app-natmapt") | .currentCommit' "$MANIFEST")"

# natmapt: git init + fetch + checkout
if [ ! -d "./natmapt" ]; then
    mkdir -p ./natmapt && cd ./natmapt
    git init -q
    git remote add origin https://github.com/muink/openwrt-natmapt.git
    if [ -n "$NATMAPT_COMMIT" ] && [ "$NATMAPT_COMMIT" != "null" ]; then
        # 已知 commit: fetch 指定 commit
        git fetch origin "$NATMAPT_COMMIT" --depth=1 2>/dev/null
        git checkout FETCH_HEAD
        echo "[qwrt]   natmapt pinned commit: ${NATMAPT_COMMIT}"
    else
        # 首次: clone 默认分支, 后续 Track-Packages 会锁定
        git fetch origin master --depth=1
        git checkout FETCH_HEAD
        echo "[qwrt]   natmapt: initialized from master (no commit pinned yet)"
    fi
    cd ..
    echo "[qwrt]   natmapt -> wrt/package/natmapt"
fi

# luci-app-natmapt
if [ ! -d "./luci-app-natmapt" ]; then
    mkdir -p ./luci-app-natmapt && cd ./luci-app-natmapt
    git init -q
    git remote add origin https://github.com/muink/luci-app-natmapt.git
    if [ -n "$LUCI_NATMAPT_COMMIT" ] && [ "$LUCI_NATMAPT_COMMIT" != "null" ]; then
        git fetch origin "$LUCI_NATMAPT_COMMIT" --depth=1 2>/dev/null
        git checkout FETCH_HEAD
        echo "[qwrt]   luci-app-natmapt pinned commit: ${LUCI_NATMAPT_COMMIT}"
    else
        git fetch origin master --depth=1
        git checkout FETCH_HEAD
        echo "[qwrt]   luci-app-natmapt: initialized from master (no commit pinned yet)"
    fi
    cd ..
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
echo "[qwrt] [4/4] Downloading & injecting reF1nd sing-box..."
RELEASE_ARCH="arm64"     # jdcloud_re-cs-02 = aarch64 (硬编码, .config 尚未生成)

SINGBOX_TAG="$(jq -r '.githubRelease[] | select(.name == "sing-box") | .currentTag' "$MANIFEST")"
SINGBOX_SHA256="$(jq -r '.githubRelease[] | select(.name == "sing-box") | .currentSha256' "$MANIFEST")"
test -n "$SINGBOX_TAG" || { echo "[qwrt]   ERROR: sing-box currentTag is empty" >&2; exit 1; }

SINGBOX_SUFFIX="-linux-${RELEASE_ARCH}-musl.tar.gz"
echo "[qwrt]   sing-box pinned version: ${SINGBOX_TAG}"

GH_HEADERS=(-H 'Accept: application/vnd.github+json')
if [ -n "${GITHUB_TOKEN:-}" ]; then
    GH_HEADERS+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# 获取 release 资产列表, 找匹配 suffix 的 URL
SINGBOX_REL_JSON=$(curl -fsSL "${GH_HEADERS[@]}" \
    "https://api.github.com/repos/reF1nd/sing-box-releases/releases/tags/${SINGBOX_TAG}")
SINGBOX_URL=$(printf '%s' "$SINGBOX_REL_JSON" | jq -r --arg sfx "$SINGBOX_SUFFIX" \
    '.assets[] | select(.name | endswith($sfx)) | .browser_download_url')
if [ -z "$SINGBOX_URL" ] || [ "$SINGBOX_URL" = "null" ]; then
    echo "[qwrt]   ERROR: no *${SINGBOX_SUFFIX} asset in ${SINGBOX_TAG}" >&2; exit 1
fi

SINGBOX_ASSET=$(basename "$SINGBOX_URL")
echo "[qwrt]   asset: $SINGBOX_ASSET"

# 从清单获取 digest 做 sha256 校验
SINGBOX_DIGEST="$(printf '%s' "$SINGBOX_REL_JSON" | jq -r --arg sfx "$SINGBOX_SUFFIX" \
    '[.assets[] | select(.name | endswith($sfx))][0].digest // "" | sub("^sha256:"; "")')"

curl -fL "$SINGBOX_URL" -o "$TMP_DIR/$SINGBOX_ASSET"

if [ -n "$SINGBOX_DIGEST" ]; then
    echo "${SINGBOX_DIGEST}  ${TMP_DIR}/${SINGBOX_ASSET}" | sha256sum -c \
        || { echo "[qwrt]   ERROR: sing-box tarball sha256 mismatch" >&2; exit 1; }
    echo "[qwrt]   sha256 verified"
fi

tar -xzf "$TMP_DIR/$SINGBOX_ASSET" -C "$TMP_DIR"
SINGBOX_BIN=$(find "$TMP_DIR" -type f -name sing-box | head -n 1)
if [ -z "$SINGBOX_BIN" ] || [ ! -f "$SINGBOX_BIN" ]; then
    echo "[qwrt]   ERROR: sing-box binary not found in $SINGBOX_ASSET" >&2; exit 1
fi

# eBPF 验证 (软检查: 本步 go 可能未装; reF1nd prerelease 可靠含 with_ebpf)
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
# immortalwrt feed 默认锁 stable 2.1.3; 用户要上游 rc 2.1.4-rc.2, 故 sed 强改.
# 解耦: PKG_VERSION=2.1.4_rc2 (apk合法包版本, _rc=rc suffix), 引入 PKG_SOURCE_VERSION=2.1.4-rc.2
#       供 PKG_SOURCE/URL/BUILD_DIR/LDFLAGS 用 (源码目录名=2.1.4-rc.2). PKG_HASH=rc tarball sha256 已校验.
# 根因: 旧 PKG_VERSION=2.1.4-rc.2 致 apk 包版本 "2.1.4-rc.2-r1" 非法 (Error99). 时序: feeds install 后, defconfig 前.
echo "[qwrt] [5/5] Patching syncthing feed Makefile to RC v2.1.4-rc.2..."

# 从清单读取 syncthing 补丁参数
SYNCTHING_PKG_VER="$(jq -r '.feedPatch[] | select(.name == "syncthing") | .pkgVersion' "$MANIFEST")"
SYNCTHING_SRC_VER="$(jq -r '.feedPatch[] | select(.name == "syncthing") | .sourceVersion' "$MANIFEST")"
SYNCTHING_PKG_HASH="$(jq -r '.feedPatch[] | select(.name == "syncthing") | .pkgHash' "$MANIFEST")"
SYNCTHING_ABANDON="$(jq -r '.feedPatch[] | select(.name == "syncthing") | .abandonWhenFeedReaches' "$MANIFEST")"

test -n "$SYNCTHING_PKG_VER" || { echo "[qwrt]   ERROR: syncthing pkgVersion empty" >&2; exit 1; }

SYNCTHING_MK=""
if [ -d "${WRT_ROOT}/feeds" ]; then
    SYNCTHING_MK=$(find "${WRT_ROOT}/feeds" -path '*/syncthing/Makefile' -type f 2>/dev/null | head -n 1 || true)
fi

if [ -n "$SYNCTHING_MK" ]; then
    # 前置条件: 检查 feed 当前版本是否已 ≥ abandon 阈值
    CURRENT_FEED_VER="$(grep -oP '^PKG_VERSION:=\K.*' "$SYNCTHING_MK" 2>/dev/null || echo "")"
    if [ -n "$CURRENT_FEED_VER" ] && [ -n "$SYNCTHING_ABANDON" ]; then
        # 简单版本比较: 用 sed 把 _rc / -rc 归一化后按数值比较主版本
        FEED_NORM="$(echo "$CURRENT_FEED_VER" | sed 's/_rc/./; s/-rc/./' | cut -d. -f1-2)"
        ABANDON_NORM="$(echo "$SYNCTHING_ABANDON" | cut -d. -f1-2)"
        # 转浮点数比较 (2.1 < 2.1.4 → yes)
        HIGHEST=$(printf '%s\n' "$FEED_NORM" "$ABANDON_NORM" | sort -t. -k1,1n -k2,2n | tail -n1)
        if [ "$HIGHEST" = "$FEED_NORM" ] && [ "$FEED_NORM" != "$ABANDON_NORM" ] || \
           [ "$CURRENT_FEED_VER" = "$SYNCTHING_ABANDON" ] || \
           [ "$(echo "$CURRENT_FEED_VER" | cut -d. -f1)" -gt "$(echo "$SYNCTHING_ABANDON" | cut -d. -f1)" ]; then
            echo "[qwrt]   ::warning:: syncthing feed ${CURRENT_FEED_VER} ≥ abandon ${SYNCTHING_ABANDON}, skipping patch (recommend removing feedPatch)"
        else
            sed -i \
                -e "s|^PKG_VERSION:=.*|PKG_VERSION:=${SYNCTHING_PKG_VER}\nPKG_SOURCE_VERSION:=${SYNCTHING_SRC_VER}|" \
                -e 's|$(PKG_VERSION)|$(PKG_SOURCE_VERSION)|g' \
                -e "s|^PKG_HASH:=.*|PKG_HASH:=${SYNCTHING_PKG_HASH}|" \
                "$SYNCTHING_MK"
            echo "[qwrt]   patched: $SYNCTHING_MK"
            if grep -qE "^PKG_VERSION:=${SYNCTHING_PKG_VER}" "$SYNCTHING_MK"; then
                grep -E '^(PKG_VERSION|PKG_SOURCE_VERSION|PKG_HASH):=' "$SYNCTHING_MK"
                echo "[qwrt]   syncthing -> rc ${SYNCTHING_SRC_VER} (pkgver ${SYNCTHING_PKG_VER} apk-legal)"
            else
                echo "[qwrt]   ERROR: sed did not set PKG_VERSION=${SYNCTHING_PKG_VER}" >&2; exit 1
            fi
        fi
    else
        # 无版本或阈值: 直接执行 sed
        sed -i \
            -e "s|^PKG_VERSION:=.*|PKG_VERSION:=${SYNCTHING_PKG_VER}\nPKG_SOURCE_VERSION:=${SYNCTHING_SRC_VER}|" \
            -e 's|$(PKG_VERSION)|$(PKG_SOURCE_VERSION)|g' \
            -e "s|^PKG_HASH:=.*|PKG_HASH:=${SYNCTHING_PKG_HASH}|" \
            "$SYNCTHING_MK"
        echo "[qwrt]   patched: $SYNCTHING_MK"
        if grep -qE "^PKG_VERSION:=${SYNCTHING_PKG_VER}" "$SYNCTHING_MK"; then
            grep -E '^(PKG_VERSION|PKG_SOURCE_VERSION|PKG_HASH):=' "$SYNCTHING_MK"
            echo "[qwrt]   syncthing -> rc ${SYNCTHING_SRC_VER}"
        else
            echo "[qwrt]   ERROR: sed did not set PKG_VERSION=${SYNCTHING_PKG_VER}" >&2; exit 1
        fi
    fi
else
    echo "[qwrt]   ERROR: syncthing Makefile not found in ${WRT_ROOT}/feeds/" >&2; exit 1
fi

# ============ [6] 写入固件清单快照 ============
# 将 .github/packages.json 的快照写入固件内，供用户 cat /etc/qwrt-manifest.json 查看。
# 这是方案二（Release Body 增强），随固件打包，信息随设备走。
echo "[qwrt] [6/6] Writing manifest snapshot to firmware..."
if [ -d "$WRT_FILES" ]; then
    mkdir -p "$WRT_FILES/etc"
    # 生成精简版清单快照（去冗余字段，保留关键版本信息）
    jq '{
        upstream: {ciRepo: .upstream.ciRepo, sourceRepo: .upstream.sourceRepo, ciCommit: .upstream.currentCiCommit, sourceCommit: .upstream.currentSourceCommit},
        githubRelease: [.githubRelease[] | {name, repo, currentTag, currentSha256, sourceRepo, currentSourceTag}],
        gitRepo: [.gitRepo[] | {name, repo, currentCommit}],
        feedPatch: [.feedPatch[] | {name, pkgVersion, sourceVersion, pkgHash}]
    }' "$MANIFEST" > "$WRT_FILES/etc/qwrt-manifest.json"
    echo "[qwrt]   manifest snapshot -> ${WRT_FILES}/etc/qwrt-manifest.json"
    echo "[qwrt]   on-device: cat /etc/qwrt-manifest.json"
fi

echo "[qwrt] === PRIVATE.sh done ==="