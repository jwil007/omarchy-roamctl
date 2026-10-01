import QtQuick

// RSSI history plot. Values are dBm (negative); the y-axis auto-fits to the
// visible range with a little padding, but never narrower than 20 dB so a
// steady signal doesn't look like a seismograph. Optional `thresholds`
// ([{ value, label }], e.g. roamctl's tier floors) are drawn as dashed lines
// and pulled into range when they're near the signal.
Canvas {
  id: root

  property var values: []
  property int capacity: 90
  property color lineColor: "white"
  property color gridColor: Qt.rgba(1, 1, 1, 0.12)
  property color labelColor: "gray"
  property string fontFamily: ""
  property var thresholds: []

  onValuesChanged: requestPaint()
  onWidthChanged: requestPaint()
  onLineColorChanged: requestPaint()
  onThresholdsChanged: requestPaint()

  onPaint: {
    var ctx = getContext("2d")
    ctx.reset()
    var list = values || []
    if (list.length < 2) return

    var lo = Math.min.apply(null, list)
    var hi = Math.max.apply(null, list)
    var mid = (lo + hi) / 2
    var span = Math.max(20, hi - lo + 6)
    lo = Math.floor(mid - span / 2)
    hi = Math.ceil(mid + span / 2)
    // Stretch to include thresholds within 15 dB of the window, so the floor
    // the signal is approaching is visible without flattening the trace.
    var marks = (thresholds || []).filter(function(t) { return isFinite(t.value) })
    marks.forEach(function(t) {
      if (t.value < lo && t.value >= lo - 15) lo = t.value - 2
      if (t.value > hi && t.value <= hi + 15) hi = t.value + 2
    })

    var labelW = 40
    var plotW = width - labelW
    var pad = 3
    function y(v) { return pad + (hi - v) / (hi - lo) * (height - pad * 2) }
    function x(i) { return labelW + (capacity - list.length + i) / (capacity - 1) * plotW }

    ctx.font = "10px '" + fontFamily + "'"
    ctx.fillStyle = labelColor
    ctx.strokeStyle = gridColor
    ctx.lineWidth = 1
    var visibleMarks = marks.filter(function(t) { return t.value >= lo && t.value <= hi })
    if (visibleMarks.length > 0) {
      ctx.setLineDash([3, 3])
      // Lines always draw; labels closer than ~11 px merge into one ("E/F").
      var labels = []
      visibleMarks.slice().sort(function(a, b) { return b.value - a.value }).forEach(function(t) {
        var yy = Math.round(y(t.value)) + 0.5
        ctx.beginPath(); ctx.moveTo(labelW, yy); ctx.lineTo(width, yy); ctx.stroke()
        var prev = labels[labels.length - 1]
        if (prev && yy - prev.y < 11) {
          prev.text = prev.letters + "/" + t.label
          prev.letters = prev.text
        } else {
          labels.push({ y: yy, text: t.label + " " + t.value, letters: t.label })
        }
      })
      labels.forEach(function(l) { ctx.fillText(l.text, 0, l.y + 3.5) })
      ctx.setLineDash([])
    } else {
      ;[hi, lo].forEach(function(v) {
        var yy = Math.round(y(v)) + 0.5
        ctx.beginPath(); ctx.moveTo(labelW, yy); ctx.lineTo(width, yy); ctx.stroke()
        ctx.fillText(String(v), 0, v === hi ? yy + 9 : yy - 1)
      })
    }

    ctx.beginPath()
    for (var i = 0; i < list.length; i++) {
      if (i === 0) ctx.moveTo(x(i), y(list[i]))
      else ctx.lineTo(x(i), y(list[i]))
    }
    ctx.strokeStyle = lineColor
    ctx.lineWidth = 1.6
    ctx.lineJoin = "round"
    ctx.stroke()

    ctx.lineTo(x(list.length - 1), height)
    ctx.lineTo(x(0), height)
    ctx.closePath()
    ctx.fillStyle = Qt.rgba(lineColor.r, lineColor.g, lineColor.b, 0.14)
    ctx.fill()

    var last = list[list.length - 1]
    ctx.beginPath()
    ctx.arc(x(list.length - 1), y(last), 2.5, 0, Math.PI * 2)
    ctx.fillStyle = lineColor
    ctx.fill()
  }
}
