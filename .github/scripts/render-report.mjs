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

// 宽松版本比较：按 . - + 切段取整数逐位比大小
export function compareVer(a, b) {
  const pa = String(a).split(/[.\-+_]/).map((x) => parseInt(x, 10) || 0)
  const pb = String(b).split(/[.\-+_]/).map((x) => parseInt(x, 10) || 0)
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    if ((pa[i] || 0) !== (pb[i] || 0)) return (pa[i] || 0) - (pb[i] || 0)
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
    const reached = i.upstreamLatest && i.abandonWhen &&
      compareVer(i.upstreamLatest, i.abandonWhen) >= 0
    if (reached) {
      warnings.push(`${i.name}：上游已发布 \`${i.upstreamLatest}\`，` +
        `PRIVATE.sh 中锁定 \`${i.pinned}\` 的 sed 补丁建议移除，否则会静默降级`)
    } else {
      unchanged.push(`${i.name} 补丁仍有效（锁定 \`${i.pinned}\`）`)
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