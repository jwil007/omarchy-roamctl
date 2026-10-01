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

// Score delta roamctl requires in each tier (checkRoam in roam.go).
var TIER_DELTA_KEYS = {
  opportunistic: "roaming_tiers.fair_score_delta",
  active_roaming: "roaming_tiers.degraded_score_delta",
  critical: "roaming_tiers.critical_score_delta"
}

function connSnapshot(s) {
  if (!s) return null
  return {
    bssid: s.BSSID || "",
    freq: s.Freq || 0,
    channel: channelFor(s.Freq),
    band: bandFor(s.Freq),
    channelWidth: s.ChannelWidth || "",
    rssi: s.RSSI || 0,
    avgRssi: s.AvgRSSI || 0,
    avgRssiBeacon: s.AvgRSSIBeacon || 0,
    txBitrate: s.TxBitrate || 0,
    txMcs: s.TxMCS,
    txPhy: s.TxPHY || "",
    rxBitrate: s.RxBitrate || 0,
    rxMcs: s.RxMCS,
    rxPhy: s.RxPHY || "",
    retryRate: s.RetryRate || 0,
    txRetries: s.TxRetries || 0,
    txFails: s.TxFails || 0,
    beaconLoss: s.BeaconLoss || 0,
    connDurationMs: durationMs(s.ConnDuration),
    wpaState: s.WPAState || "",
    tier: s.RoamingTier || "",
    resultFlag: s.RoamResultFlag || "",
    lastTriggerRssi: s.LastTriggerRSSI || 0,
    hysteresisActive: s.HysteresisActive === true,
    unhealthyConn: s.UnhealthyConn === true,
    entryScanned: s.EntryScanned === true,
    entryScannedCrit: s.EntryScannedCrit === true,
    fullScannedCrit: s.FullScannedCrit === true,
    scanMode: s.ScanMode || "",
    scanInProgress: s.ScanInProgress === true,
    scanDurationMs: durationMs(s.ScanDuration),
    lastScanTime: isZeroTime(s.LastScanTime) ? "" : s.LastScanTime,
    bssListStable: s.BSSListStable === true
  }
}

// One roam, as logged to roams-<iface>.jsonl and expanded by roamctl-export.
//   result:   the frame where the roam's CompletedAt first appeared
//   decision: the frame holding the scored list the target was chosen from
//             (meta.source: "roam-start" = first RoamInProgress frame,
//             "pre-roam" = last frame before it, for sub-frame roams)
//   after:    the first frame reporting the final BSSID (meta.settled), else
//             the latest frame when the 3 s settle window ran out
function roamRecord(result, decision, after, meta, config, penalties) {
  var cfg = config || {}
  var tier = decision ? decision.RoamingTier : ""
  var deltaKey = TIER_DELTA_KEYS[tier]
  return {
    schema: 2,
    loggedAt: new Date(meta.nowMs).toISOString(),
    iface: result.Iface || "",
    ssid: result.SSID || (decision ? decision.SSID : "") || "",
    roam: {
      completedAt: result.CompletedAt,
      success: result.Success === true,
      resultFlag: result.RoamResultFlag || "",
      message: result.Message || "",
      targetBssid: result.TargetBSSID || "",
      finalBssid: result.FinalBSSID || "",
      durationMs: durationMs(result.Duration)
    },
    decision: {
      source: meta.source,
      // How long before the roam's completion was observed this frame arrived.
      snapshotAgeMs: meta.snapshotAgeMs,
      tier: tier,
      requiredDelta: deltaKey && cfg[deltaKey] !== undefined ? cfg[deltaKey] : null,
      hysteresisOverrideDelta: cfg["roaming_tiers.fair_score_delta"] !== undefined ? cfg["roaming_tiers.fair_score_delta"] * 2 : null,
      connection: connSnapshot(decision),
      bssList: decision && Array.isArray(decision.BSSList) ? decision.BSSList : []
    },
    after: Object.assign(connSnapshot(after) || {}, { settled: meta.settled === true, settleMs: meta.settleMs }),
    penalties: penalties || [],
    config: cfg
  }
}
