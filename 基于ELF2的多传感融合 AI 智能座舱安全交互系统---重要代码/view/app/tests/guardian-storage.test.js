const test = require('node:test')
const assert = require('node:assert/strict')

const { createGuardianStorage } = require('../services/guardian-storage')

function memoryApi() {
  const values = new Map()
  return {
    getStorageSync: key => values.get(key),
    setStorageSync: (key, value) => values.set(key, value)
  }
}

test('storage keeps only five newest trips', () => {
  const storage = createGuardianStorage(memoryApi())
  for (let i = 1; i <= 7; i += 1) storage.upsertTrip({ tripId: `trip-${i}`, endTs: i })
  assert.deepEqual(storage.getTrips().map(item => item.tripId),
    ['trip-7', 'trip-6', 'trip-5', 'trip-4', 'trip-3'])
})

test('storage keeps only two hundred newest event ids', () => {
  const storage = createGuardianStorage(memoryApi())
  for (let i = 0; i < 205; i += 1) storage.rememberEvent(`event-${i}`)
  assert.equal(storage.getSeenEventIds().length, 200)
  assert.equal(storage.hasSeenEvent('event-0'), false)
  assert.equal(storage.hasSeenEvent('event-204'), true)
})

