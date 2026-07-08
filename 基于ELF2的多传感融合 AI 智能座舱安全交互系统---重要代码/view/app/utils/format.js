function pad(value) {
  return String(value).padStart(2, '0')
}

function formatTime(ts) {
  if (!ts) return '—'
  const date = new Date(ts)
  return `${pad(date.getHours())}:${pad(date.getMinutes())}`
}

function formatDateTime(ts) {
  if (!ts) return '—'
  const date = new Date(ts)
  return `${pad(date.getMonth() + 1)}月${pad(date.getDate())}日 ${formatTime(ts)}`
}

function formatDuration(seconds) {
  const value = Math.max(0, Number(seconds) || 0)
  const minutes = Math.floor(value / 60)
  const remain = Math.floor(value % 60)
  if (minutes === 0) return `${remain} 秒`
  if (remain === 0) return `${minutes} 分钟`
  return `${minutes} 分 ${remain} 秒`
}

module.exports = { formatTime, formatDateTime, formatDuration }

