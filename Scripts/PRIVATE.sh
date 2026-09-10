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
#   [5] syncthing feed 补丁: 按用户策略锁定最新预览版 rc (版本+sha256 从 packages.json
#       feedPatch 条目读取, 由 Track-Packages 每周自动更新; feed 版本已追平时自动休眠)
#   [6] 写入固件清单快照 /etc/qwrt-manifest.json
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
echo "[qwrt] [1/6] Injecting stundeck opkg package + pulling release binaries..."

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

# 构建资产: stundeck-{version}-linux-arm64.tar.gz（tag 去 v 前缀拼接）
STUNDECK_VERSION="${STUNDECK_TAG#v}"
STUNDECK_ASSET="stundeck-${STUNDECK_VERSION}-linux-arm64.tar.gz"
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
echo "[qwrt] [2/6] Cloning muink natmapt + luci-app-natmapt..."
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
echo "[qwrt] [3/6] Merging files/ overlay into wrt/files/..."
if [ -d "$GW/files" ]; then
    mkdir -p "$WRT_FILES"
    cp -a "$GW/files/." "$WRT_FILES/"
    echo "[qwrt]   $GW/files/. -> ${WRT_FILES}/"
else
    echo "[qwrt]   NOTE: $GW/files not found, skipping overlay"
fi


# ============ [4] sing-box (reF1nd prerelease, with_ebpf) ============
echo "[qwrt] [4/6] Downloading & injecting reF1nd sing-box..."
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


# ============ [5] syncthing feed 补丁: 锁定最新预览版 ============
# 用户策略: syncthing 版本总是最新预览版(rc)。feed(immortalwrt/packages) 默认只跟 stable,
# 故在 feeds 更新后把 utils/syncthing/Makefile 的 PKG_VERSION/PKG_HASH sed 为清单锁定的
# 预览版。版本与 sha256 由 Track-Packages 每周自动写回 packages.json 的 feedPatch 条目。
# feed 版本追平/超过锁定版本时跳过 (dpkg 比较, -rc. 转 ~rc. 保证 2.1.4-rc.2 < 2.1.4 语义),
# 补丁自动休眠, 待更新的预览版发布后自动恢复。
echo "[qwrt] [5/6] Patching feeds syncthing to pinned prerelease..."

ST_FEED_MF="$(find "${WRT_ROOT}/feeds" -type f -wholename '*/syncthing/Makefile' -print -quit 2>/dev/null)"
ST_PINNED="$(jq -r '.feedPatch[]? | select(.name == "syncthing") | .sourceVersion // empty' "$MANIFEST" | head -n1)"
ST_SHA256="$(jq -r '.feedPatch[]? | select(.name == "syncthing") | .sourceSha256 // empty' "$MANIFEST" | head -n1)"

if [ -z "$ST_PINNED" ] || [ -z "$ST_SHA256" ]; then
    echo "[qwrt]   no syncthing feedPatch in $MANIFEST, skip (build feed default version)"
elif [ ! -f "$ST_FEED_MF" ]; then
    echo "[qwrt]   WARNING: syncthing Makefile not found in feeds, skip"
else
    ST_VERSION="${ST_PINNED#v}"
    # dpkg 语义比较: 2.1.4-rc.2 -> 2.1.4~rc.2, 确保 rc 排序在正式版之前
    ST_VERSION_CMP="${ST_VERSION//-rc./~rc.}"
    FEED_VERSION="$(grep -oP '^PKG_VERSION:=\K.*' "$ST_FEED_MF" | head -n1 || true)"
    if [ -z "$FEED_VERSION" ]; then
        echo "[qwrt]   WARNING: cannot read feed PKG_VERSION, patch skipped"
    elif dpkg --compare-versions "$FEED_VERSION" lt "$ST_VERSION_CMP"; then
        sed -i "s/^PKG_VERSION:=.*/PKG_VERSION:=${ST_VERSION}/" "$ST_FEED_MF"
        sed -i "s/^PKG_HASH:=.*/PKG_HASH:=${ST_SHA256}/" "$ST_FEED_MF"
        echo "[qwrt]   syncthing patched: ${FEED_VERSION} -> ${ST_VERSION}"
    else
        echo "[qwrt]   syncthing patch dormant: feed ${FEED_VERSION} >= pinned ${ST_VERSION}"
    fi
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
        feedPatch: [.feedPatch[]? | {name, upstreamRepo, sourceVersion, sourceSha256}]
    }' "$MANIFEST" > "$WRT_FILES/etc/qwrt-manifest.json"
    echo "[qwrt]   manifest snapshot -> ${WRT_FILES}/etc/qwrt-manifest.json"
    echo "[qwrt]   on-device: cat /etc/qwrt-manifest.json"
fi

echo "[qwrt] === PRIVATE.sh done ==="