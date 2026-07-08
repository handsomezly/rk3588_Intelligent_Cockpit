const { createGuardianStorage } = require('../../services/guardian-storage')
const { formatDateTime, formatTime, formatDuration } = require('../../utils/format')

Page({
  data: { trips: [] },

  onShow() {
    const storage = createGuardianStorage(wx)
    const trips = storage.getTrips().map(trip => ({
      ...trip,
      startText: formatDateTime(trip.startTs),
      endText: formatTime(trip.endTs),
      durationText: formatDuration(trip.durationSec),
      timeline: (trip.timeline || []).map(item => ({
        ...item,
        timeText: formatTime(item.ts)
      }))
    }))
    this.setData({ trips })
  }
})

