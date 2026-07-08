const test = require('node:test')
const assert = require('node:assert/strict')

const { createInitialState, reduceGuardianEvent } = require('../models/guardian-state')

test('snapshot restores an active guarding trip', () => {
  const result = reduceGuardianEvent(createInitialState(), {
    version: 1,
    type: 'snapshot',
    ts: 1000,
    state: 'guarding',
    trip: { tripId: 'trip-1', startTs: 900, alertCount: 0, timeline: [] }
  })
  assert.equal(result.state.mode, 'guarding')
  assert.equal(result.state.trip.tripId, 'trip-1')
})

test('duplicate alerts are ignored and vibrate only once', () => {
  const event = {
    version: 1, eventId: 'event-1', type: 'alert', tripId: 'trip-1',
    ts: 1000, title: '检测到疲劳风险', summary: '状态持续监测中'
  }
  const first = reduceGuardianEvent(createInitialState(), event)
  const second = reduceGuardianEvent(first.state, event)
  assert.deepEqual(first.effects, ['vibrate'])
  assert.deepEqual(second.effects, [])
  assert.equal(second.state.timeline.length, 1)
})

test('recovered state schedules a two second return to guarding', () => {
  const state = { ...createInitialState(), mode: 'warning', trip: { tripId: 'trip-1' } }
  const result = reduceGuardianEvent(state, {
    version: 1, eventId: 'event-2', type: 'recovered', tripId: 'trip-1', ts: 2000,
    title: '状态已恢复', summary: '驾驶状态恢复平稳'
  })
  assert.equal(result.state.mode, 'recovered')
  assert.deepEqual(result.effects, ['schedule-guarding'])
})

test('a recovered snapshot also schedules the temporary state to end', () => {
  const result = reduceGuardianEvent(createInitialState(), {
    version: 1,
    type: 'snapshot',
    ts: 2000,
    state: 'recovered',
    trip: { tripId: 'trip-1', startTs: 1000, endTs: null, timeline: [] },
    lastHeartbeatTs: 2000
  })
  assert.equal(result.state.mode, 'recovered')
  assert.deepEqual(result.effects, ['schedule-guarding'])
})

test('an old recovery timer cannot hide a newer alert', () => {
  const state = {
    ...createInitialState(),
    mode: 'warning',
    trip: { tripId: 'trip-1', startTs: 1000, endTs: null }
  }
  const result = reduceGuardianEvent(state, { type: 'return_guarding', ts: 3000 })
  assert.equal(result.state.mode, 'warning')
})

test('an arrived snapshot restores the missed trip into local history', () => {
  const result = reduceGuardianEvent(createInitialState(), {
    version: 1,
    type: 'snapshot',
    ts: 4000,
    state: 'arrived',
    trip: {
      tripId: 'trip-1', startTs: 1000, endTs: 4000,
      summary: '本次行程平稳，最终平安到达。', timeline: []
    },
    lastHeartbeatTs: 4000
  })
  assert.deepEqual(result.effects, ['save-trip'])
})

test('offline keeps the last trip instead of clearing the page', () => {
  const state = { ...createInitialState(), mode: 'guarding', trip: { tripId: 'trip-1' } }
  const result = reduceGuardianEvent(state, { type: 'offline', ts: 5000 })
  assert.equal(result.state.mode, 'offline')
  assert.equal(result.state.lastOnlineMode, 'guarding')
  assert.equal(result.state.trip.tripId, 'trip-1')
})
