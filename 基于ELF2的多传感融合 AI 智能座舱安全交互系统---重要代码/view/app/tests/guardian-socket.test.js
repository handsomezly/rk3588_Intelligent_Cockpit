const test = require('node:test')
const assert = require('node:assert/strict')

const { createGuardianSocket } = require('../services/guardian-socket')

function fakeEnvironment() {
  const handlers = {}
  const task = {
    onOpen: fn => { handlers.open = fn },
    onMessage: fn => { handlers.message = fn },
    onClose: fn => { handlers.close = fn },
    onError: fn => { handlers.error = fn },
    close: () => { handlers.closed = true }
  }
  const timers = []
  const cleared = []
  return {
    wxApi: { connectSocket: () => task },
    scheduler: {
      setTimeout: (fn, delay) => { timers.push({ fn, delay }); return timers.length },
      clearTimeout: id => { cleared.push(id) }
    },
    handlers,
    timers,
    cleared
  }
}

test('socket uses capped reconnect backoff', () => {
  const env = fakeEnvironment()
  const socket = createGuardianSocket(env.wxApi, env.scheduler)
  socket.connect('ws://192.168.43.2:8765')
  env.handlers.close()
  assert.equal(env.timers[0].delay, 1000)
  env.timers[0].fn()
  env.handlers.close()
  assert.equal(env.timers[1].delay, 2000)
})

test('connect replaces the existing socket task', () => {
  const env = fakeEnvironment()
  const socket = createGuardianSocket(env.wxApi, env.scheduler)
  socket.connect('ws://one:8765')
  socket.connect('ws://two:8765')
  assert.equal(env.handlers.closed, true)
})

test('a stale socket close cannot schedule reconnect for the new connection', () => {
  const tasks = []
  const timers = []
  const wxApi = {
    connectSocket: () => {
      const handlers = {}
      const task = {
        handlers,
        onOpen: fn => { handlers.open = fn },
        onMessage: fn => { handlers.message = fn },
        onClose: fn => { handlers.close = fn },
        onError: fn => { handlers.error = fn },
        close: () => {}
      }
      tasks.push(task)
      return task
    }
  }
  const scheduler = {
    setTimeout: (fn, delay) => { timers.push({ fn, delay }); return timers.length },
    clearTimeout: () => {}
  }

  const socket = createGuardianSocket(wxApi, scheduler)
  socket.connect('ws://one:8765')
  socket.connect('ws://two:8765')
  tasks[0].handlers.close()

  assert.equal(tasks.length, 2)
  assert.equal(timers.length, 0)
})

test('invalid protocol messages are ignored', () => {
  const env = fakeEnvironment()
  const received = []
  const socket = createGuardianSocket(env.wxApi, env.scheduler, {
    onMessage: message => received.push(message)
  })
  socket.connect('ws://board:8765')

  env.handlers.message({ data: '{broken' })
  env.handlers.message({ data: JSON.stringify({ version: 2, type: 'heartbeat', ts: 1 }) })
  env.handlers.message({ data: JSON.stringify({
    version: 1,
    type: 'heartbeat',
    ts: 1,
    deviceId: 'ELF2-001',
    state: 'idle'
  }) })

  assert.equal(received.length, 1)
  assert.equal(received[0].type, 'heartbeat')
})

test('socket error schedules one reconnect even if close follows', () => {
  const env = fakeEnvironment()
  const socket = createGuardianSocket(env.wxApi, env.scheduler)
  socket.connect('ws://board:8765')

  env.handlers.error()
  assert.equal(env.timers.length, 1)
  assert.equal(env.timers[0].delay, 1000)
  env.handlers.close()
  assert.equal(env.timers.length, 1)
})

test('disconnect clears the heartbeat timer', () => {
  const env = fakeEnvironment()
  const socket = createGuardianSocket(env.wxApi, env.scheduler)
  socket.connect('ws://board:8765')
  env.handlers.open()
  socket.disconnect()

  assert.deepEqual(env.cleared, [1])
})

test('twelve seconds without a valid message reports offline', () => {
  const env = fakeEnvironment()
  const statuses = []
  const socket = createGuardianSocket(env.wxApi, env.scheduler, {
    onStatus: status => statuses.push(status)
  })
  socket.connect('ws://board:8765')
  env.handlers.open()

  assert.equal(env.timers[0].delay, 12000)
  env.timers[0].fn()
  assert.equal(statuses.at(-1), 'offline')
})

test('a valid message restores connected status after heartbeat timeout', () => {
  const env = fakeEnvironment()
  const statuses = []
  const socket = createGuardianSocket(env.wxApi, env.scheduler, {
    onStatus: status => statuses.push(status)
  })
  socket.connect('ws://board:8765')
  env.handlers.open()
  env.timers[0].fn()
  env.handlers.message({ data: JSON.stringify({
    version: 1,
    type: 'heartbeat',
    ts: 13000,
    deviceId: 'ELF2-001',
    state: 'guarding'
  }) })

  assert.equal(statuses.at(-1), 'connected')
})
