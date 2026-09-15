#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# 校验将被 cat 进 OpenWrt .config 的配置片段语法（QWRT.yml 预检 job 调用）。
#
# 背景：WRT-CORE.yml 的 Custom Settings 步骤把 Config/<设备>.txt + GENERAL.txt
# 以及 Settings.sh 追加的 PRIVATE.txt 直接 cat 成 .config，随后
#   make defconfig → include/toplevel.mk prepare-tmpinfo → GNU make include .config
# 因此 .config 的每一行必须同时满足两套解析器：
#   1. GNU make：只接受 "变量=值" 与 # 注释，其余报 "missing separator" 直接失败；
#   2. kconfig conf：接受 "CONFIG_X=y|m|n|\"字符串\"|数字" 与 "# CONFIG_X is not set"。
# 关闭一个开关的唯一安全写法是 "# CONFIG_X is not set"（带 #）。
# 事故记录：run 34721609785（2026-09-12 周编译）因 PRIVATE.txt 中 17 行
# 设备配置被去掉 # 写成 "CONFIG_X is not set"，make 报
# ".config:202: *** missing separator" 而失败。
#
# 用法: check-config.sh <config-fragment> [...]   # 全部通过 exit 0，否则 exit 1

set -uo pipefail

if [ $# -eq 0 ]; then
    echo "usage: $0 <config-fragment> [...]" >&2
    exit 2
fi

fail=0
for f in "$@"; do
    if [ ! -f "$f" ]; then
        echo "::error file=$f::配置片段不存在"
        fail=1
        continue
    fi

    bad=$(awk -v F="$f" '
    {
        line = $0
        sub(/\r$/, "", line)                                   # dos2unix 双保险
        if (line ~ /^[[:space:]]*$/)             next          # 空行
        if (line ~ /^[[:space:]]*#/)             next          # 注释（含规范的 "# CONFIG_X is not set"）
        if (line ~ /^[[:space:]]*CONFIG_[A-Za-z0-9_-]+=/) {     # 赋值（符号名可含 -，如 luci-app-*）
            val = line
            sub(/^[[:space:]]*CONFIG_[A-Za-z0-9_-]+=/, "", val)
            sub(/[[:space:]]+$/, "", val)
            if (val ~ /^(y|m|n|"[^"]*"|-?[0-9]+|0[xX][0-9a-fA-F]+)$/) next
            printf "::error file=%s,line=%d::赋值非法(仅允许 y/m/n/引号字符串/数字): %s\n", F, NR, line
            bad = 1
            next
        }
        if (line ~ /[[:space:]]is[[:space:]]+not[[:space:]]+set[[:space:]]*$/) {
            printf "::error file=%s,line=%d::缺少前导 # 的 \"is not set\" 行: %s\n", F, NR, line
            printf "::error file=%s::kconfig 关闭开关的规范写法是 \"# CONFIG_X is not set\"(带 #); 去掉 # 后 GNU make 解析 .config 会报 missing separator, 编译直接失败\n", F
        } else {
            printf "::error file=%s,line=%d::非法 .config 行(仅允许 空行 / # 注释 / CONFIG_X=值): %s\n", F, NR, line
        }
        bad = 1
    }
    END { exit bad ? 1 : 0 }
    ' "$f")

    if [ -n "$bad" ]; then
        printf '%s\n' "$bad"
        fail=1
    else
        echo "OK: $f"
    fi
done

if [ "$fail" -ne 0 ]; then
    echo "::error::配置片段语法校验未通过, 修复后再触发编译"
fi
exit "$fail"
