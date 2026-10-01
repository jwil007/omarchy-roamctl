// Pure helpers for the roamctl plugin. roamctl streams one JSON-encoded
// ipc.ProcessState per line; Go encodes time.Duration as integer nanoseconds
// and time.Time as RFC 3339 (zero value = year 1).

// Wire names from roamctl's roamingTier.String(), mapped to the README's
// tier names and a 1–4 signal-bar level for the bar icon.
var TIERS = {
  roam_disabled: { label: "Excellent", level: 4 },
  opportunistic: { label: "Fair", level: 3 },
  active_roaming: { label: "Degraded", level: 2 },
  critical: { label: "Critical", level: 1 }
}

function parseState(line) {
  try {
    var parsed = JSON.parse(String(line || ""))
    return parsed && typeof parsed === "object" ? parsed : null
  } catch (e) {
    return null
  }
}

function parseStatus(raw) {
  try {
    var parsed = JSON.parse(String(raw || "").trim())
    return parsed && typeof parsed === "object" ? parsed : null
  } catch (e) {
    return null
  }
}

function tierLevel(tier) {
  var t = TIERS[String(tier || "")]
  return t ? t.level : 0
}

function tierLabel(tier) {
  var t = TIERS[String(tier || "")]
  return t ? t.label : "Starting"
}

var TIER_BEHAVIOR = {
  roam_disabled: "roaming paused",
  opportunistic: "opportunistic roaming",
  active_roaming: "active roaming",
  critical: "aggressive roaming"
}

function tierBehavior(tier) {
  return TIER_BEHAVIOR[String(tier || "")] || ""
}

function scanText(state) {
  if (!state) return ""
  var mode = { fast_scan: "Smart scan", full_scan: "Full scan", scan_disabled: "Paused", external: "External" }[state.ScanMode] || "—"
  if (state.ScanInProgress) return mode + " running…"
  if (!isZeroTime(state.LastScanTime)) return mode + " · last " + clockText(state.LastScanTime)
  return mode
}

function isZeroTime(value) {
  return !value || String(value).indexOf("0001-01-01") === 0
}

function durationMs(ns) {
  return Math.round(Number(ns || 0) / 1e6)
}

function durationText(ns) {
  var s = Math.floor(Number(ns || 0) / 1e9)
  if (s < 60) return s + "s"
  var m = Math.floor(s / 60)
  if (m < 60) return m + "m " + (s % 60) + "s"
  var h = Math.floor(m / 60)
  return h + "h " + (m % 60) + "m"
}

function channelFor(freq) {
  var f = Number(freq || 0)
  if (f === 2484) return 14
  if (f >= 2412 && f < 2484) return (f - 2407) / 5
  if (f >= 5955 && f <= 7115) return (f - 5950) / 5
  if (f >= 5000 && f < 5925) return (f - 5000) / 5
  return 0
}

function bandFor(freq) {
  var f = Number(freq || 0)
  if (f >= 5925) return "6 GHz"
  if (f >= 5000) return "5 GHz"
  if (f >= 2400) return "2.4 GHz"
  return ""
}

// "5 GHz · ch 36 · 80MHz"
function channelText(freq, width) {
  var parts = []
  var band = bandFor(freq)
  if (band) parts.push(band)
  var ch = channelFor(freq)
  if (ch) parts.push("ch " + ch)
  if (width && width !== "Unknown") parts.push(String(width))
  return parts.join(" · ")
}

// roamctl reports bitrates in bits per second.
function rateText(bps, mcs) {
  var text = Math.round(Number(bps || 0) / 1e5) / 10 + " Mbps"
  if (Number(mcs) >= 0 && mcs !== undefined && mcs !== null) text += " · MCS " + mcs
  return text
}

function rssiText(rssi, avg) {
  if (!rssi) return "—"
  var text = rssi + " dBm"
  if (avg && avg !== rssi) text += " (avg " + avg + ")"
  return text
}

function shortBssid(bssid) {
  var value = String(bssid || "")
  return value.length === 17 ? value.substring(9) : value
}

// Top-N scored BSSes, current AP first when present.
function candidates(bssList, limit) {
  var list = Array.isArray(bssList) ? bssList.slice() : []
  list.sort(function(a, b) {
    if (a.IsCurrentAP !== b.IsCurrentAP) return a.IsCurrentAP ? -1 : 1
    return (b.FinalScore || 0) - (a.FinalScore || 0)
  })
  return list.slice(0, limit || 6)
}

function bssMeta(bss) {
  if (!bss) return ""
  var parts = [channelText(bss.Freq, bss.ChannelWidth)]
  if (bss.PHYType && bss.PHYType !== "Unknown") parts.push(bss.PHYType)
  if (bss.QBSSStaCt) parts.push(bss.QBSSStaCt + " clients")
  return parts.filter(function(p) { return p !== "" }).join(" · ")
}

function findBss(bssList, bssid) {
  var list = Array.isArray(bssList) ? bssList : []
  for (var i = 0; i < list.length; i++) {
    if (list[i].BSSID === bssid) return list[i]
  }
  return null
}

function roamSummary(stats, target) {
  var ms = durationMs(stats.Duration)
  if (!stats.Success) return "Roam to " + (stats.TargetBSSID || "AP") + " failed" + (stats.Message ? ": " + stats.Message : "")
  var parts = ["Roamed to " + (stats.FinalBSSID || stats.TargetBSSID)]
  if (target) parts.push(channelText(target.Freq, ""))
  if (target && target.RSSI) parts.push(target.RSSI + " dBm")
  parts.push(ms + " ms")
  return parts.join(" · ")
}

function clockText(date) {
  var d = date instanceof Date ? date : new Date(date)
  function pad(n) { return n < 10 ? "0" + n : String(n) }
  return pad(d.getHours()) + ":" + pad(d.getMinutes()) + ":" + pad(d.getSeconds())
}
