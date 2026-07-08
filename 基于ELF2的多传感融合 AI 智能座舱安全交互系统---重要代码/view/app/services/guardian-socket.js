const VALID_STATES = new Set(['idle', 'guarding', 'warning', 'recovered', 'arrived'])
const EVENT_TYPES = new Set(['trip_started', 'alert', 'recovered', 'trip_ended'])

function isServerMessage(message) {
  if (!message || typeof message !== 'object' || message.version !== 1 ||
      typeof message.type !== 'string' || !Number.isFinite(message.ts) ||
      typeof message.deviceId !== 'string') return false

  if (message.type === 'heartbeat') {
    return VALID_STATES.has(message.state)
  }
  if (message.type === 'snapshot') {
    return VALID_STATES.has(message.state) &&
      Object.prototype.hasOwnProperty.call(message, 'trip') &&
      Array.isArray(message.timeline) && Number.isFinite(message.alertCount) &&
      Number.isFinite(message.lastHeartbeatTs)
  }
  if (!EVENT_TYPES.has(message.type)) return false
  const validEvent = typeof message.eventId === 'string' &&
    typeof message.tripId === 'string' && typeof message.level === 'string' &&
    typeof message.title === 'string' && typeof message.summary === 'string'
  if (!validEvent) return false
  return message.type !== 'alert' || typeof message.alertType === 'string'
}

function createGuardianSocket(wxApi, scheduler, initialOptions = {}) {
  const timerApi = scheduler || {
    setTimeout: (fn, delay) => setTimeout(fn, delay),
    clearTimeout: id => clearTimeout(id)
  }
  let options = initialOptions
  let task = null
  let url = ''
  let reconnectAttempt = 0
  let reconnectTimer = null
  let heartbeatTimer = null
  let manualClose = false
  let connectionGeneration = 0
  let heartbeatTimedOut = false
  const delays = [1000, 2000, 4000, 8000]

  function clearTimer(name) {
    const id = name === 'reconnect' ? reconnectTimer : heartbeatTimer
    if (id) timerApi.clearTimeout(id)
    if (name === 'reconnect') reconnectTimer = null
    else heartbeatTimer = null
  }

  function armHeartbeat() {
    clearTimer('heartbeat')
    heartbeatTimer = timerApi.setTimeout(() => {
      heartbeatTimedOut = true
      if (options.onStatus) options.onStatus('offline')
    }, options.heartbeatTimeoutMs || 12000)
  }

  function scheduleReconnect() {
    if (manualClose || !url || reconnectTimer) return
    const delay = delays[Math.min(reconnectAttempt, delays.length - 1)]
    reconnectAttempt += 1
    reconnectTimer = timerApi.setTimeout(() => {
      reconnectTimer = null
      open()
    }, delay)
  }

  function open() {
    if (!url) return
    const generation = connectionGeneration
    if (options.onStatus) options.onStatus('connecting')
    const currentTask = wxApi.connectSocket({ url })
    task = currentTask
    currentTask.onOpen(() => {
      if (generation !== connectionGeneration || task !== currentTask) return
      reconnectAttempt = 0
      heartbeatTimedOut = false
      if (options.onStatus) options.onStatus('connected')
      armHeartbeat()
    })
    currentTask.onMessage(message => {
      if (generation !== connectionGeneration || task !== currentTask) return
      let parsed
      try { parsed = JSON.parse(message.data) } catch (_error) { return }
      if (!isServerMessage(parsed)) return
      armHeartbeat()
      if (heartbeatTimedOut) {
        heartbeatTimedOut = false
        if (options.onStatus) options.onStatus('connected')
      }
      if (options.onMessage) options.onMessage(parsed)
    })
    currentTask.onClose(() => {
      if (generation !== connectionGeneration || task !== currentTask) return
      clearTimer('heartbeat')
      task = null
      heartbeatTimedOut = false
      if (options.onStatus) options.onStatus('offline')
      scheduleReconnect()
    })
    currentTask.onError(() => {
      if (generation !== connectionGeneration || task !== currentTask) return
      clearTimer('heartbeat')
      task = null
      heartbeatTimedOut = false
      if (options.onStatus) options.onStatus('offline')
      scheduleReconnect()
      currentTask.close()
    })
  }

  return {
    setCallbacks(nextOptions) { options = { ...options, ...nextOptions } },
    connect(nextUrl) {
      connectionGeneration += 1
      manualClose = true
      clearTimer('reconnect')
      clearTimer('heartbeat')
      if (task) task.close()
      task = null
      manualClose = false
      heartbeatTimedOut = false
      reconnectAttempt = 0
      url = nextUrl
      open()
    },
    disconnect() {
      connectionGeneration += 1
      manualClose = true
      clearTimer('reconnect')
      clearTimer('heartbeat')
      if (task) task.close()
      task = null
      heartbeatTimedOut = false
    }
  }
}

module.exports = { createGuardianSocket, isServerMessage }
