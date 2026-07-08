const config = require('../../config')
const { createInitialState, reduceGuardianEvent } = require('../../models/guardian-state')
const { createGuardianSocket } = require('../../services/guardian-socket')
const { createGuardianStorage } = require('../../services/guardian-storage')
const { formatTime, formatDuration } = require('../../utils/format')

const SUPPORTED_MESSAGES = new Set([
  'snapshot', 'heartbeat', 'trip_started', 'alert', 'recovered', 'trip_ended'
])

function normalizeAddress(value) {
  const raw = String(value || '').trim()
  if (!raw) return ''
  const host = raw.replace(/^(ws|https?):\/\//i, '')
    .replace(/\/$/, '').split(':')[0]
  if (!host) return ''
  return `ws://${host}:${config.GUARDIAN_PORT}`
}

Page({
  data: {
    mode: 'idle',
    connectionLabel: '未连接',
    boardAddress: '',
    addressInput: '',
    showConnectionSheet: false,
    statusSubtitle: '等待车机开启守护',
    timeline: [],
    latestAlert: null,
    trip: null,
    durationText: '0 分钟',
    acknowledged: false,
    hasTrips: false
  },

  onLoad() {
    this.storage = createGuardianStorage(wx)
    const saved = this.storage.getSnapshot()
    this.guardianState = saved && saved.mode ? saved : createInitialState()
    this.guardianState.seenEventIds = this.storage.getSeenEventIds()
    this.socket = createGuardianSocket(wx, null, {
      heartbeatTimeoutMs: config.HEARTBEAT_TIMEOUT_MS,
      onMessage: event => this.handleGuardianMessage(event),
      onStatus: status => this.handleSocketStatus(status)
    })
    const savedUrl = this.storage.getUrl()
    const defaultUrl = normalizeAddress(config.DEFAULT_BOARD_IP)
    const url = savedUrl || defaultUrl
    this.setData({
      boardAddress: url,
      addressInput: url,
      showConnectionSheet: !url,
      hasTrips: this.storage.getTrips().length > 0
    })
    this.applyViewModel()
    if (url) {
      this.socket.connect(url)
      this.socketStarted = true
    }
  },

  onShow() {
    if (this.storage) {
      this.setData({ hasTrips: this.storage.getTrips().length > 0 })
    }
  },

  onUnload() {
    if (this.recoveryTimer) clearTimeout(this.recoveryTimer)
    if (this.socket) this.socket.disconnect()
  },

  handleSocketStatus(status) {
    const labels = {
      connecting: '连接中',
      connected: '已连接',
      offline: '连接中断'
    }
    this.setData({ connectionLabel: labels[status] || '未连接' })
    if (status === 'offline') {
      const result = reduceGuardianEvent(this.guardianState, {
        type: 'offline', ts: Date.now()
      })
      this.guardianState = result.state
      this.persistAndRender()
    }
  },

  handleGuardianMessage(event) {
    if (!event || event.version !== 1 || !SUPPORTED_MESSAGES.has(event.type)) return
    const result = reduceGuardianEvent(this.guardianState, event)
    this.guardianState = result.state
    if (event.eventId) this.storage.rememberEvent(event.eventId)
    this.runEffects(result.effects)
    this.persistAndRender()
  },

  runEffects(effects) {
    if (effects.includes('vibrate')) {
      wx.vibrateLong({ fail: () => {} })
      this.setData({ acknowledged: false })
    }
    if (effects.includes('schedule-guarding')) {
      if (this.recoveryTimer) clearTimeout(this.recoveryTimer)
      this.recoveryTimer = setTimeout(() => {
        const result = reduceGuardianEvent(this.guardianState, {
          type: 'return_guarding', ts: Date.now()
        })
        this.guardianState = result.state
        this.persistAndRender()
      }, 2000)
    }
    if (effects.includes('save-trip') && this.guardianState.trip) {
      this.storage.upsertTrip(this.guardianState.trip)
      this.setData({ hasTrips: true })
    }
  },

  persistAndRender() {
    this.guardianState.seenEventIds = this.storage.getSeenEventIds()
    this.storage.setSnapshot(this.guardianState)
    this.applyViewModel()
  },

  applyViewModel() {
    const state = this.guardianState
    const trip = state.trip
    const latest = state.latestAlert
    const subtitles = {
      idle: '等待车机开启守护',
      guarding: trip ? `已出发 · ${formatTime(trip.startTs)}` : '行程守护中',
      warning: latest ? latest.title : '检测到需要关注的状态',
      recovered: '驾驶状态已恢复平稳',
      arrived: trip ? `本次行程 ${formatDuration(trip.durationSec)}` : '本次行程已结束',
      offline: `最后状态已保留 · ${formatTime(state.lastHeartbeatTs)}`
    }
    const timeline = (state.timeline || []).slice(-4).map(item => ({
      ...item,
      timeText: formatTime(item.ts),
      tone: item.type === 'alert' ? 'warning'
        : item.type === 'trip_ended' ? 'success' : 'normal'
    }))
    this.setData({
      mode: state.mode,
      statusSubtitle: subtitles[state.mode] || subtitles.idle,
      timeline,
      latestAlert: latest,
      trip,
      durationText: trip ? formatDuration(trip.durationSec) : '0 分钟'
    })
  },

  openConnectionSheet() {
    this.setData({
      showConnectionSheet: true,
      addressInput: this.data.boardAddress
    })
  },

  closeConnectionSheet() {
    if (this.data.boardAddress) this.setData({ showConnectionSheet: false })
  },

  onAddressInput(event) {
    this.setData({ addressInput: event.detail.value })
  },

  saveConnection() {
    const url = normalizeAddress(this.data.addressInput)
    if (!url) {
      wx.showToast({ title: '请输入开发板 IP', icon: 'none' })
      return
    }
    this.storage.setUrl(url)
    this.setData({
      boardAddress: url,
      addressInput: url,
      showConnectionSheet: false,
      connectionLabel: '连接中'
    })
    this.socket.connect(url)
    this.socketStarted = true
  },

  acknowledgeAlert() {
    this.setData({ acknowledged: true })
  },

  openTrips() {
    wx.navigateTo({ url: '/pages/trips/trips' })
  }
})
