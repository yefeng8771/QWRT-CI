#!/usr/bin/env node

// render-report.mjs — QWRT-CI 依赖变更周报渲染脚本
//
// 读取 Track-Packages 各步骤落下的结构化 JSON，渲染成 Markdown 周报。
// 用法: node render-report.mjs <报告目录> <输出文件>
// 输出: 向 stdout 写 title=...，供 GITHUB_OUTPUT 消费

import { readdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'

const short = (sha) => (sha ? sha.slice(0, 7) : '—')

// 宽松版本比较：按 . - + 切段，逐位比大小。
// 处理规则：
//   - 纯数字段按数值比较
//   - 非数字段（rc/alpha/beta 等）按字符串比较
//   - 一方先耗尽时，剩余段若含非数字则视为预发布（小于稳定版），否则视为更详细（大于简化版）
//   例如：2.1.4_rc2 < 2.1.4 < 2.1.4.1
export function compareVer(a, b) {
  // 统一剥离 tag 的 v 前缀: v2.1.4-rc.2 与 2.1.5 需可比
  const pa = String(a).replace(/^v/, '').split(/[.\-+_]/)
  const pb = String(b).replace(/^v/, '').split(/[.\-+_]/)
  const maxLen = Math.max(pa.length, pb.length)
  for (let i = 0; i < maxLen; i++) {
    const sa = pa[i]
    const sb = pb[i]
    // 某一方已耗尽
    if (sa === undefined) return sb && !/^\d+$/.test(sb) ? 1 : -1
    if (sb === undefined) return sa && !/^\d+$/.test(sa) ? -1 : 1
    // 双方都存在
    const na = parseInt(sa, 10)
    const nb = parseInt(sb, 10)
    if (!isNaN(na) && !isNaN(nb)) {
      if (na !== nb) return na - nb
    } else {
      if (sa !== sb) return sa < sb ? -1 : 1
    }
  }
  return 0
}

export function renderReport(items, today = new Date().toISOString().slice(0, 10)) {
  const byKind = (k) => items.filter((i) => i._kind === k)
  const updated = []
  const unchanged = []
  const warnings = []

  for (const i of byKind('rel')) {
    if (i.status === 'unavailable') {
      warnings.push(`${i.name}：上游发布不可用，本周未更新`)
      continue
    }
    if (i.status === 'updated') {
      updated.push(`**${i.name}**：\`${i.from || '—'}\` → \`${i.to}\``)
    } else {
      unchanged.push(`${i.name} \`${i.to}\``)
    }
    // 构建层落后于源仓库：fork 的交叉编译 CI 可能没跟上上游发布
    if (i.sourceTag) {
      const srcNum = i.sourceTag.replace(/^v/, '')
      if (!String(i.to).includes(srcNum)) {
        warnings.push(
          `${i.name}：构建层 \`${i.to}\`，源仓库 \`${i.sourceTag}\`，请确认交叉编译是否已跟进`)
      }
    }
  }

  for (const i of byKind('git')) {
    if (i.status === 'unavailable') {
      warnings.push(`${i.name}：无法获取 commit`)
      continue
    }
    if (i.status === 'unchanged') {
      unchanged.push(`${i.name} \`${short(i.to)}\``)
    } else if (i.status === 'initialized') {
      updated.push(`**${i.name}**：初始化为 \`${short(i.to)}\``)
    } else {
      updated.push(`**${i.name}**：\`${short(i.from)}\` → \`${short(i.to)}\`` +
        (i.ahead ? `（${i.ahead} 个提交）` : ''))
    }
  }

  for (const i of byKind('patch')) {
    if (i.status === 'unavailable') {
      warnings.push(`${i.name}：上游发布不可用，本周未更新`)
      continue
    }
    // feed 自带版本已追平/超过锁定版本 → 补丁自动休眠（不删除条目，待新预览版恢复）
    const covered = i.feedVersion && i.to &&
      compareVer(i.feedVersion, i.to) >= 0
    if (covered) {
      unchanged.push(`${i.name}：feed \`${i.feedVersion}\` 已覆盖锁定 \`${i.to}\`，补丁本周不生效`)
    } else if (i.status === 'updated') {
      updated.push(`**${i.name}**：\`${i.from || '—'}\` → \`${i.to}\``)
    } else {
      unchanged.push(`${i.name} 锁定 \`${i.to}\`（feed \`${i.feedVersion || '—'}\`）`)
    }
  }

  const lines = [`## 本周依赖变更（${today}）`, '']

  lines.push('### 有更新', '')
  lines.push(updated.length ? updated.map((s) => `- ${s}`).join('\n') : '- 无', '')

  const verify = byKind('verify')
  if (verify.length) {
    lines.push('### 产物校验', '')
    lines.push(verify.map((v) =>
      `- ${v.name} \`${v.tag}\`：架构 ${v.arch}，build tag 已验证`).join('\n'), '')
  }

  lines.push('### 无变化', '')
  lines.push(unchanged.length ? `- ${unchanged.join('、')}` : '- 无', '')

  if (warnings.length) {
    lines.push('### ⚠️ 需人工介入', '')
    lines.push(warnings.map((s) => `- ${s}`).join('\n'), '')
  }

  lines.push('### 上游', '')
  for (const u of byKind('upstream')) {
    lines.push(`- \`${u.repo}\`：\`${short(u.from)}\` → \`${short(u.to)}\`` +
      (u.ahead ? `（${u.ahead} 个提交）` : '（无变更）'))
  }

  const title = updated.length ? `更新 ${updated.length} 项依赖` : '依赖无变化'
  return { body: lines.join('\n') + '\n', title }
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  const [dir, out] = process.argv.slice(2)
  const items = readdirSync(dir)
    .filter((f) => f.endsWith('.json'))
    .map((f) => ({ ...JSON.parse(readFileSync(join(dir, f), 'utf8')),
                   _kind: f.split('-')[0] }))
  const { body, title } = renderReport(items)
  writeFileSync(out, body)
  console.log(`title=${title}`)
}