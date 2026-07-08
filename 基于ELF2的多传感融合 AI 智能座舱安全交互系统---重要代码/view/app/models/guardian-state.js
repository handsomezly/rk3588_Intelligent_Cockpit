function createInitialState() {
  return {
    mode: 'idle',
    lastOnlineMode: 'idle',
    connected: false,
    trip: null,
    timeline: [],
    seenEventIds: [],
    latestAlert: null,
    lastHeartbeatTs: 0
  }
}

function rememberEvent(ids, eventId) {
  if (!eventId || ids.includes(eventId)) return ids
  return [...ids, eventId].slice(-200)
}

function timelineFromTrip(trip) {
  return trip && Array.isArray(trip.timeline) ? trip.timeline.slice() : []
}

function reduceGuardianEvent(current, event) {
  const state = { ...current }
  const effects = []

  if (!event || !event.type) return { state, effects }

  if (event.type === 'offline') {
    state.lastOnlineMode = current.mode === 'offline'
      ? current.lastOnlineMode : current.mode
    state.mode = 'offline'
    state.connected = false
    return { state, effects }
  }

  if (event.type === 'snapshot') {
    state.connected = true
    state.mode = event.state || 'idle'
    state.lastOnlineMode = state.mode
    state.trip = event.trip || null
    state.timeline = timelineFromTrip(event.trip)
    state.lastHeartbeatTs = event.lastHeartbeatTs || event.ts || 0
    state.latestAlert = state.timeline.slice().reverse()
      .find(item => item.type === 'alert') || null
    if (state.mode === 'recovered') effects.push('schedule-guarding')
    if (state.mode === 'arrived' && state.trip) effects.push('save-trip')
    return { state, effects }
  }

  if (event.type === 'heartbeat') {
    state.connected = true
    state.lastHeartbeatTs = event.ts || Date.now()
    if (state.mode === 'offline') state.mode = state.lastOnlineMode || event.state || 'idle'
    return { state, effects }
  }

  if (event.type === 'return_guarding') {
    if (current.mode === 'recovered' && state.trip && !state.trip.endTs) {
      state.mode = 'guarding'
      state.lastOnlineMode = 'guarding'
    }
    return { state, effects }
  }

  if (event.eventId && current.seenEventIds.includes(event.eventId)) {
    return { state, effects }
  }
  state.seenEventIds = rememberEvent(current.seenEventIds, event.eventId)
  state.connected = true
  state.lastHeartbeatTs = event.ts || Date.now()

  if (event.type === 'trip_started') {
    state.mode = 'guarding'
    state.trip = {
      tripId: event.tripId,
      startTs: event.ts,
      endTs: null,
      alertCount: 0,
      timeline: []
    }
    state.timeline = []
  } else if (event.type === 'alert') {
    state.mode = 'warning'
    state.trip = state.trip || {
      tripId: event.tripId,
      startTs: event.ts,
      endTs: null,
      alertCount: 0,
      timeline: []
    }
    state.latestAlert = event
    effects.push('vibrate')
  } else if (event.type === 'recovered') {
    state.mode = 'recovered'
    effects.push('schedule-guarding')
  } else if (event.type === 'trip_ended') {
    state.mode = 'arrived'
    state.trip = {
      ...(state.trip || {}),
      tripId: event.tripId,
      endTs: event.endTs || event.ts,
      startTs: event.startTs || (state.trip && state.trip.startTs),
      durationSec: event.durationSec || 0,
      alertCount: event.alertCount || 0,
      summary: event.summary || '',
      timeline: Array.isArray(event.timeline) ? event.timeline.slice() : state.timeline.slice()
    }
    state.timeline = timelineFromTrip(state.trip)
    effects.push('save-trip')
  }

  if (['trip_started', 'alert', 'recovered'].includes(event.type)) {
    state.timeline = [...state.timeline, event]
    if (state.trip) state.trip = { ...state.trip, timeline: state.timeline.slice() }
  }
  state.lastOnlineMode = state.mode
  return { state, effects }
}

module.exports = { createInitialState, reduceGuardianEvent }
