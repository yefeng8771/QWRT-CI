// render-report.test.mjs — QWRT-CI 依赖变更周报渲染脚本单测
// 用 node --test 运行

import { describe, it } from 'node:test'
import assert from 'node:assert/strict'

import { renderReport, compareVer } from './render-report.mjs'

describe('compareVer', () => {
  it('两个空版本相等', () => assert.equal(compareVer('', ''), 0))
  it('主版本比较', () => {
    assert.ok(compareVer('1.2.3', '1.2.4') < 0)
    assert.ok(compareVer('2.0', '1.9') > 0)
  })
  it('rc/alpha/beta 后缀比较', () => {
    assert.ok(compareVer('2.1.4-rc.2', '2.1.4-rc.1') > 0)
    assert.ok(compareVer('2.1.4_rc2', '2.1.4') < 0)
  })
  it('不同长度版本', () => {
    assert.ok(compareVer('2.1.4', '2.1') > 0)
  })
})

describe('renderReport', () => {
  it('全部无变化时输出"依赖无变化"', () => {
    const items = [
      { _kind: 'rel', name: 'stundeck', status: 'unchanged', to: 'v1.0' },
      { _kind: 'git', name: 'natmapt', status: 'unchanged', to: 'abc1234' },
      { _kind: 'patch', name: 'syncthing', pinned: '2.1.4-rc.2', upstreamLatest: '2.1.3', abandonWhen: '2.1.4' },
      { _kind: 'upstream', repo: 'VIKINGYFY/OpenWRT-CI', from: 'aaa', to: 'bbb', ahead: 0 },
    ]
    const { body, title } = renderReport(items, '2026-09-08')
    assert.equal(title, '依赖无变化')
    assert.match(body, /无变化/)
  })

  it('有更新时标题正确', () => {
    const items = [
      { _kind: 'rel', name: 'sing-box', status: 'updated', from: 'v1.0', to: 'v2.0' },
      { _kind: 'git', name: 'natmapt', status: 'unchanged', to: 'def5678' },
      { _kind: 'patch', name: 'syncthing', pinned: '2.1.4-rc.2', upstreamLatest: '2.1.3', abandonWhen: '2.1.4' },
      { _kind: 'upstream', repo: 'VIKINGYFY/OpenWRT-CI', from: 'aaa', to: 'bbb', ahead: 0 },
    ]
    const { title } = renderReport(items)
    assert.equal(title, '更新 1 项依赖')
  })

  it('patch 项 upstreamLatest >= abandonWhen 时进入"需人工介入"', () => {
    const items = [
      { _kind: 'patch', name: 'syncthing', pinned: '2.1.4-rc.2', upstreamLatest: '2.1.5', abandonWhen: '2.1.4' },
    ]
    const { body } = renderReport(items)
    assert.match(body, /需人工介入/)
    assert.match(body, /建议移除/)
  })

  it('rel 项 sourceTag 与 to 不匹配时告警', () => {
    const items = [
      { _kind: 'rel', name: 'stundeck', status: 'unchanged', to: 'v0.1.202609021106', sourceTag: 'v0.2.0' },
    ]
    const { body } = renderReport(items)
    assert.match(body, /需人工介入/)
    assert.match(body, /构建层.*跟进/)
  })

  it('status: unavailable 不计入 updated/unchanged', () => {
    const items = [
      { _kind: 'rel', name: 'sing-box', status: 'unavailable' },
      { _kind: 'git', name: 'natmapt', status: 'unchanged', to: 'abc' },
    ]
    const { body } = renderReport(items)
    assert.match(body, /不可用/)
    assert.doesNotMatch(body, /sing-box.*→/)
  })
})