const KEYS = {
  url: 'elf2_guardian_ws_url',
  trips: 'elf2_guardian_trips',
  eventIds: 'elf2_guardian_seen_event_ids',
  snapshot: 'elf2_guardian_current_snapshot'
}

function createGuardianStorage(api) {
  const get = (key, fallback) => {
    const value = api.getStorageSync(key)
    return value === undefined || value === null || value === '' ? fallback : value
  }

  return {
    getUrl: () => get(KEYS.url, ''),
    setUrl: url => api.setStorageSync(KEYS.url, url),
    getTrips: () => get(KEYS.trips, []),
    upsertTrip(trip) {
      const trips = this.getTrips().filter(item => item.tripId !== trip.tripId)
      trips.push(trip)
      trips.sort((a, b) => (b.endTs || 0) - (a.endTs || 0))
      api.setStorageSync(KEYS.trips, trips.slice(0, 5))
    },
    getSeenEventIds: () => get(KEYS.eventIds, []),
    hasSeenEvent(eventId) {
      return this.getSeenEventIds().includes(eventId)
    },
    rememberEvent(eventId) {
      if (!eventId || this.hasSeenEvent(eventId)) return
      api.setStorageSync(KEYS.eventIds,
        [...this.getSeenEventIds(), eventId].slice(-200))
    },
    getSnapshot: () => get(KEYS.snapshot, null),
    setSnapshot: snapshot => api.setStorageSync(KEYS.snapshot, snapshot)
  }
}

module.exports = { createGuardianStorage, KEYS }

