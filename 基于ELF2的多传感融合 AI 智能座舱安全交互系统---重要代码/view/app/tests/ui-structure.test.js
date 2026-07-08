const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')

const root = path.resolve(__dirname, '..')

test('app declares only guardian and trips pages without a tab bar', () => {
  const config = JSON.parse(fs.readFileSync(path.join(root, 'app.json'), 'utf8'))
  assert.deepEqual(config.pages, ['pages/guardian/guardian', 'pages/trips/trips'])
  assert.equal(config.tabBar, undefined)
})

test('guardian page contains the approved low density content', () => {
  const wxml = fs.readFileSync(path.join(root, 'pages/guardian/guardian.wxml'), 'utf8')
  for (const text of ['平安守护', '守护中', '需要关注', '今日平安签', '已收到提醒']) {
    assert.match(wxml, new RegExp(text))
  }
  for (const forbidden of ['PERCLOS', 'RKNN', 'IMU', '温湿度']) {
    assert.doesNotMatch(wxml, new RegExp(forbidden))
  }
})

test('guardian page uses approved light theme tokens and reduced motion', () => {
  const wxss = fs.readFileSync(path.join(root, 'pages/guardian/guardian.wxss'), 'utf8')
  for (const token of ['#F7FAFC', '#173042', '#65AAA7', '#63B487', '#E5845A']) {
    assert.match(wxss.toUpperCase(), new RegExp(token.toUpperCase()))
  }
  assert.match(wxss, /prefers-reduced-motion/)
})
