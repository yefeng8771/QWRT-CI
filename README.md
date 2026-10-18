# QWRT-CI — 京东云亚瑟专用云编译

[IPQ技术讨论群](https://qm.qq.com/q/v7nMhzB4oU)

---

[LiBwrt-Ai](https://api.zipimg.cn/register?aff=FFPS3UMJ8HJD)

1. **禁止修改任何上游文件**（文件头带 `# SPDX-License-Identifier: MIT` + `# Copyright (C) 2026 VIKINGYFY`）。  
   所有自定义必须走新增文件 + 上游原生钩子：
   - `Scripts/Packages.sh` 会 `source $GITHUB_WORKSPACE/Scripts/PRIVATE.sh`
   - `Scripts/Settings.sh` 会 `cat Config/PRIVATE.txt` 追加到 `.config`

2. **启用 `git merge -X theirs` 强制合并**，任何对上游文件的修改会在下次每日同步时被静默吞掉。  
   自有文件在上游不存在，完全不受影响。

3. **绝不可用 `git reset --hard upstream/main`** — 那会抹掉全部自有增量文件。

---

## 📦 仓库结构

| 类型 | 文件 | 说明 |
|------|------|------|
| **自有（可改）** | `.github/workflows/QWRT.yml` | 编译入口，被 Weekly-Build 调用 |
| **自有（可改）** | `.github/workflows/Auto-Sync.yml` | 每日强制同步上游 |
| **自有（可改）** | `.github/workflows/Track-Packages.yml` | 每周依赖跟踪 |
| **自有（可改）** | `.github/workflows/Weekly-Build.yml` | 每周编译固件 |
| **自有（可改）** | `.github/workflows/QWRT-Guard.yml` | 编译超时看门狗 |
| **自有（可改）** | `.github/workflows/Notify.yml` | Telegram 通知 |
| **自有（可改）** | `.github/packages.json` | 依赖清单（版本锁定 + 状态） |
| **自有（可改）** | `.github/scripts/check-config.sh` | .config 片段语法校验（QWRT.yml 预检） |
| **自有（可改）** | `Scripts/PRIVATE.sh` | 私有注入脚本（版本从清单读取） |
| **自有（可改）** | `Config/PRIVATE.txt` | Kconfig 追加（设备精简 / 包选择） |
| **自有（可改）** | `files/` | 固件覆盖层（uci-defaults + sing-box 配置） |
| **自有（可改）** | `package/stundeck/` | stundeck opkg 包定义 |
| **自有（可改）** | `prebuilt/` | 已被移除（构建时动态下载） |
| **上游（不可改）** | `.github/workflows/WRT-CORE.yml` | 编译核心，被 QWRT.yml 复用 |
| **上游（不可改）** | `.github/workflows/MTK-ALL.yml` | 上游多机型编译（已禁用） |
| **上游（不可改）** | `.github/workflows/OWRT-ALL.yml` | 上游多机型编译（已禁用） |
| **上游（不可改）** | `.github/workflows/QCA-ALL.yml` | 上游多机型编译（已禁用） |
| **上游（不可改）** | `.github/workflows/QCB-ALL.yml` | 上游多机型编译（已禁用） |
| **上游（不可改）** | `.github/workflows/WRT-TEST.yml` | 上游测试编译（已禁用） |
| **上游（不可改）** | `.github/workflows/Auto-Clean.yml` | 上游自动清理（**已禁用**，请勿启用） |
| **上游（不可改）** | `.github/workflows/Cache-Clean.yml` | 上游缓存清理（已禁用） |
| **上游（不可改）** | `Scripts/*`（除 PRIVATE.sh） | 上游脚本 |
| **上游（不可改）** | `Config/*`（除 PRIVATE.txt） | 上游配置 |

---

## 🕐 流水线时序

```
每日 20:00 UTC (04:00 北京)  →  每日同步上游 (Auto-Sync.yml)
                                   ↓ 强制合并 + 禁用无关 workflow
周五 18:00 UTC (02:00 北京)  →  每周跟踪依赖更新 (Track-Packages.yml)
                                   ↓ 检查 stundeck / sing-box / natmapt / syncthing
                                   ↓ 有变化则回写 .github/packages.json 并提交
                                   ↓ 生成周报（artifact）
周六 20:00 UTC (04:00 北京)  →  每周编译固件 (Weekly-Build.yml)
                                   ↓ 消费 .github/packages.json
                                   ↓ 调用 QWRT.yml → WRT-CORE.yml
                                   ↓ 编译完成 → 追加清单快照到 Release
                                   ↓ 滚动发布（保留最近 3 个）
全程                              →  执行结果通知 (Notify.yml)
                                   →  编译超时看门狗 (QWRT-Guard.yml)
```

---

## 📦 依赖清单 `packages.json`

所有外部依赖的版本锁定在 `.github/packages.json`，由 `Track-Packages.yml` 自动维护。

| 依赖 | 类型 | 来源 |
|------|------|------|
| **stundeck** | GitHub Release | `yefeng8771/stundeck`（fork 构建层，产出 arm64 tarball） |
| **sing-box** | GitHub Release | `reF1nd/sing-box-releases`（prerelease，带 `with_ebpf`） |
| **natmapt** | Git 仓库 | `muink/openwrt-natmapt` |
| **luci-app-natmapt** | Git 仓库 | `muink/luci-app-natmapt` |
| **syncthing** | Feed 补丁 | 自动锁定最新预览版 rc（Track-Packages 每周更新版本+sha256；feed 版本追上时补丁自动休眠） |

新增依赖只改 `packages.json`，无需动 `PRIVATE.sh` 或 workflow yml。

---

## 🛠️ 手动操作

### 手动触发编译
```bash
gh workflow run QWRT.yml -f TEST=false
```

### 手动触发依赖跟踪（DRY-RUN，只出报告不写清单）
```bash
gh workflow run Track-Packages.yml -f DRY_RUN=true
```

### 手动触发每日同步
```bash
gh workflow run 每日同步上游
```

---

## 🔐 所需 Secrets

| Secret | 用途 |
|--------|------|
| `AUTOSYNC_PAT` | 带 `contents:write` 权限的 PAT，用于 Auto-Sync 推送和触发下游 workflow |
| `TG_BOT_TOKEN` | Telegram Bot Token（Notify 可选） |
| `TG_CHAT_ID` | Telegram 目标 Chat ID（Notify 可选） |
| `GITHUB_TOKEN` | 默认 token（已自动注入） |

> ⚠️ 若未配置 `TG_BOT_TOKEN` 和 `TG_CHAT_ID`，通知会输出到 Actions 页面 step summary，不会发送 Telegram。

---

## ⚙️ 架构说明

- **仅编译** `jdcloud_re-cs-02`（京东云亚瑟，IPQ60XX 平台）
- **aarch64 硬编码**（`.config` 生成前无法读取架构）
- **版本解析与编译解耦**：所有外部依赖版本在 `packages.json` 中锁定，`PRIVATE.sh` 纯函数式读取
- **滚动发布**：保留最近 3 个 Release，自动删除旧版本
- **编译超时看门狗**：240 分钟自动取消（绕过 reusable workflow 不支持 `timeout-minutes` 的限制）。同时监听 `QWRT` 与 `每周编译固件` 两条入口：`workflow_call` 内嵌调用不产生独立 run，若只监听 `QWRT` 将永远捕获不到周编译路径
- **配置预检**：`QWRT.yml` 在编译前用 `check-config.sh` 秒级校验 `Config/IPQ60XX-WIFI-YES.txt / GENERAL.txt / PRIVATE.txt` 的 .config 语法。WRT-CORE 会把这些片段 cat 成 `.config` 且 GNU make 直接 include 它，语法错误会让编译在 ~6 分钟后以晦涩的 `missing separator` 失败（事故：run 34721609785）。**kconfig 关闭开关必须写 `# CONFIG_X is not set`（带 #），去掉 # 既不是合法 make 语法也不是合法 kconfig 语法**

## Star History

<a href="https://www.star-history.com/?repos=vikingyfy%2Fopenwrt-ci&type=date&legend=top-left">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=vikingyfy/openwrt-ci&type=date&theme=dark&legend=top-left" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=vikingyfy/openwrt-ci&type=date&legend=top-left" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=vikingyfy/openwrt-ci&type=date&legend=top-left" />
 </picture>
</a>
