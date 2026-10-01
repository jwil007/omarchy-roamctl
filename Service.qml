import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Headless roamctl state. Service status (installed / enabled / active) comes
// from the helper script; live roaming state comes straight from roamctl's IPC
// socket, which streams one JSON ProcessState per signal poll (~100 ms).
Item {
  id: root

  property var settings: ({})
  property bool panelOpen: false

  readonly property string helperPath: String(Qt.resolvedUrl("bin/roamctl-omarchy")).replace(/^file:\/\//, "")
  readonly property string configToolPath: String(Qt.resolvedUrl("bin/roamctl-config")).replace(/^file:\/\//, "")
  readonly property string configuredIface: String(setting("iface", "") || "").trim()
  readonly property bool notifyRoams: setting("notifyRoams", true) === true

  // Service status
  property bool statusKnown: false
  property string iface: configuredIface
  property bool installed: false
  property string version: ""
  property bool tuiInstalled: false
  property bool socketAccess: false
  property bool active: false
  property bool enabled: false
  property string activeState: ""

  // Config (/etc/roamctl/<iface>.toml). Values are flattened "section.key".
  property string configPath: ""
  property bool configExists: false
  property bool configWritable: false
  property bool setupCurrent: false
  property var config: ({})
  property var configErrors: []
  property bool applying: applyProcess.running
  property string applyMessage: ""
  property bool applyFailed: false

  // Optimistic switch state while systemctl (and possibly polkit) settles:
  // -1 follows reality, 0/1 is the pending target.
  property int _desired: -1
  readonly property bool running: _desired === -1 ? active : _desired === 1
  readonly property bool busy: controlProcess.running
  property string lastError: ""

  // Live IPC state
  readonly property string socketPath: iface !== "" ? "/run/roamctl/" + iface + ".sock" : ""
  readonly property bool streaming: state !== null
  property var state: null
  property var rssiHistory: []
  property var roams: []
  readonly property int historyLength: 90

  property string _pendingLine: ""
  property string _preRoamLine: ""
  property double _preRoamSeenAt: 0
  property string _startLine: ""
  property double _startSeenAt: 0
  property bool _wasInProgress: false
  property var _pendingRoam: null
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/roamctl-omarchy"
  readonly property string roamLogPath: iface !== "" ? stateDir + "/roams-" + iface + ".jsonl" : ""
  property int roamsLogged: 0
  property bool exporting: exportProcess.running
  property string _lastRoamAt: ""
  property bool _roamBaseline: false

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function refresh() {
    if (statusProcess.running) return
    statusProcess.command = [helperPath, "status"].concat(configuredIface !== "" ? [configuredIface] : [])
    statusProcess.running = true
  }

  function run(args) {
    Quickshell.execDetached([helperPath].concat(args))
  }

  function install() { run(["install"]) }
  function setup() { run(["setup"]) }
  function openTui() { run(["tui", iface]) }
  function editConfig() { run(["config", iface]) }
  function openLogs() { run(["logs", iface]) }

  function restart() { control(["restart", iface], 1) }
  function setRunning(on) { control([on ? "enable" : "disable", iface], on ? 1 : 0) }
  function toggleRunning() { if (installed && !busy) setRunning(!running) }

  function control(args, desired) {
    if (!installed || controlProcess.running) return
    _desired = desired
    lastError = ""
    controlProcess.command = [helperPath].concat(args)
    controlProcess.running = true
  }

  function loadConfig() {
    if (configPath === "" || !configExists || configProcess.running) return
    configProcess.command = [configToolPath, "get", configPath]
    configProcess.running = true
  }

  // changes: { "roaming_tiers.fair_rssi": -67, ... }
  function applyConfig(changes) {
    if (applyProcess.running) return
    var args = [helperPath, "apply", iface]
    for (var key in changes) args.push(key + "=" + changes[key])
    applyMessage = running ? "Applying and restarting roamctl…" : "Saving…"
    applyFailed = false
    applyProcess.command = args
    applyProcess.running = true
  }

  function applyStatus(raw) {
    var parsed = Model.parseStatus(raw)
    if (!parsed) return
    statusKnown = true
    iface = String(parsed.iface || "")
    installed = parsed.installed === true
    version = String(parsed.version || "")
    tuiInstalled = parsed.tuiInstalled === true
    socketAccess = parsed.socketAccess === true
    active = parsed.active === true
    enabled = parsed.enabled === true
    activeState = String(parsed.activeState || "")
    configPath = String(parsed.config || "")
    configExists = parsed.configExists === true
    configWritable = parsed.configWritable === true
    setupCurrent = parsed.setupCurrent === true
    roamsLogged = Number(parsed.roamsLogged || 0)
    if (_desired !== -1 && active === (_desired === 1)) _desired = -1
    if (!active) {
      state = null
      _pendingLine = ""
    }
  }

  // Parsing every 100 ms frame is wasted work while nobody is looking, so
  // frames are coalesced: newest line wins, applied at 4 Hz with the panel
  // open and 1 Hz otherwise (still fast enough to catch every roam).
  function applyPending() {
    if (_pendingLine === "") return
    var next = Model.parseState(_pendingLine)
    _pendingLine = ""
    if (next) state = next
  }

  // Runs for every ~100 ms frame, so it mostly does cheap string checks;
  // frames are fully parsed for the UI tick above or around a roam.
  //
  // Decision snapshot: roamctl scores a fresh scan and decides in the same
  // step, then publishes a snapshot as it sets RoamInProgress. So the first
  // in-progress frame holds the scored list the target was chosen from. The
  // pre-roam frame can still carry the previous scan's scores, so it's only
  // a fallback for roams shorter than one frame.
  //
  // After snapshot: the completion frame still reports the old connection,
  // so the roam is finalized once the station reports the final BSSID (or
  // after 3 s).
  function handleFrame(line) {
    var now = Date.now()
    _lastFrameAt = now
    _pendingLine = line
    var inProgress = inProgressRe.test(line)
    var m = completedRe.exec(line)
    var completedAt = m && !Model.isZeroTime(m[1]) ? m[1] : ""

    if (_pendingRoam) settlePendingRoam(line, now)

    // The first frame after (re)connecting carries whatever roam happened
    // before we attached; remember it without announcing it.
    if (!_roamBaseline) {
      _roamBaseline = true
      _lastRoamAt = completedAt
    } else if (completedAt !== "" && completedAt !== _lastRoamAt) {
      _lastRoamAt = completedAt
      if (_pendingRoam) finalizeRoam(_pendingRoam, "", now)
      var startSeen = _startLine !== ""
      _pendingRoam = {
        resultLine: line,
        decisionLine: startSeen ? _startLine : _preRoamLine,
        decisionSource: startSeen ? "roam-start" : "pre-roam",
        decisionSeenAt: startSeen ? _startSeenAt : _preRoamSeenAt,
        completedSeenAt: now
      }
      _startLine = ""
      settlePendingRoam(line, now)
    }

    if (inProgress && !_wasInProgress) {
      _startLine = line
      _startSeenAt = now
    }
    if (!inProgress) {
      _preRoamLine = line
      _preRoamSeenAt = now
    }
    _wasInProgress = inProgress
  }

  readonly property var completedRe: /"CompletedAt":\s*"([^"]*)"/
  readonly property var inProgressRe: /"RoamInProgress":\s*true/

  function settlePendingRoam(line, now) {
    var p = _pendingRoam
    var frame = Model.parseState(line)
    var result = p._result || (p._result = Model.parseState(p.resultLine))
    if (!result) { _pendingRoam = null; return }
    var finalBssid = String(result.FinalBSSID || "").toLowerCase()
    var landed = frame && finalBssid !== "" && String(frame.BSSID || "").toLowerCase() === finalBssid
    if (landed || now - p.completedSeenAt >= 3000) finalizeRoam(p, landed ? line : "", now, frame)
  }

  function pushRssi(rssi) {
    if (!rssi) return
    var next = rssiHistory.slice(Math.max(0, rssiHistory.length - historyLength + 1))
    next.push(rssi)
    rssiHistory = next
  }

  function finalizeRoam(p, settledLine, now, lastFrame) {
    _pendingRoam = null
    var result = p._result || Model.parseState(p.resultLine)
    if (!result) return
    var decision = Model.parseState(p.decisionLine)
    var settled = settledLine !== ""
    var after = settled ? Model.parseState(settledLine) : (lastFrame || result)

    var target = Model.findBss(decision ? decision.BSSList : [], result.TargetBSSID) || Model.findBss(result.BSSList, result.FinalBSSID || result.TargetBSSID)
    var entry = {
      at: new Date(p.completedSeenAt),
      success: result.Success === true,
      bssid: String(result.FinalBSSID || result.TargetBSSID || ""),
      durationMs: Model.durationMs(result.Duration),
      summary: Model.roamSummary(result, target),
      tier: Model.tierLabel(decision ? decision.RoamingTier : result.RoamingTier)
    }
    roams = [entry].concat(roams).slice(0, 8)

    var record = Model.roamRecord(result, decision, after, {
      source: p.decisionSource,
      snapshotAgeMs: p.decisionSeenAt ? p.completedSeenAt - p.decisionSeenAt : -1,
      settled: settled,
      settleMs: now - p.completedSeenAt,
      nowMs: now
    }, config, penalties())
    logRoam(record, p.decisionSeenAt || p.completedSeenAt)

    if (notifyRoams) {
      Quickshell.execDetached([
        "notify-send", "--app-name=roamctl", "--transient",
        "--urgency=" + (entry.success ? "low" : "normal"),
        // Nerd Font glyph via Omarchy's hint; "network-wireless" isn't in
        // Yaru, and the missing themed icon renders as Qt's checkerboard.
        "--hint=string:omarchy-glyph:" + (entry.success ? "\u{f05a9}" : "\u{f05aa}"),
        entry.success ? "Wi-Fi roamed" : "Wi-Fi roam failed",
        entry.summary
      ])
    }
  }

  function penalties() {
    try {
      var parsed = JSON.parse(String(penaltyView.text() || "null"))
      return Array.isArray(parsed) ? parsed : []
    } catch (e) {
      return []
    }
  }

  // The helper attaches roamctl's journal lines for the roam window and
  // appends the record to roams-<iface>.jsonl.
  function logRoam(record, sinceMs) {
    if (iface === "") return
    Quickshell.execDetached([helperPath, "log-roam", iface, String(Math.floor(sinceMs / 1000) - 3), JSON.stringify(record)])
    roamsLogged += 1
  }

  function exportRoams() {
    if (exportProcess.running) return
    exportProcess.command = [helperPath, "export", iface]
    exportProcess.running = true
  }

  onSocketPathChanged: { state = null; rssiHistory = []; _roamBaseline = false }

  // roamctl creates its socket a moment after the unit goes active, and
  // restarts on failure or after a config apply. A Socket that was refused
  // never retries, so liveness is tracked from frames: no frame for 3 s
  // while the unit is active tears the Socket down and builds a fresh one.
  property double _lastFrameAt: 0
  property bool _socketWanted: true

  Loader {
    active: root.active && root.socketPath !== "" && root._socketWanted
    sourceComponent: Component {
      Socket {
        path: root.socketPath
        connected: true
        parser: SplitParser {
          onRead: function(line) { root.handleFrame(line) }
        }
        onConnectedChanged: {
          root._roamBaseline = false
          if (!connected) root.state = null
        }
        onError: function(error) {
          if (!root.socketAccess) root.lastError = "No access to " + root.socketPath + " — rerun install to add the socket drop-in"
        }
      }
    }
  }

  Timer {
    interval: 1500
    repeat: true
    running: root.active
    onTriggered: {
      if (Date.now() - root._lastFrameAt < 3000 || !root._socketWanted) return
      root._socketWanted = false
      reconnectKick.restart()
    }
  }

  Timer {
    id: reconnectKick
    interval: 250
    onTriggered: root._socketWanted = true
  }

  Timer {
    interval: 1000
    repeat: true
    running: root.streaming
    onTriggered: root.pushRssi(root.state ? root.state.RSSI : 0)
  }

  Timer {
    interval: root.panelOpen ? 250 : 1000
    repeat: true
    running: root.active
    onTriggered: root.applyPending()
  }

  Timer {
    interval: root.panelOpen ? 3000 : 15000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    id: settleTimer
    property int ticks: 0
    interval: 1000
    repeat: true
    onTriggered: {
      ticks += 1
      root.refresh()
      if (ticks >= 6) {
        ticks = 0
        running = false
        root._desired = -1
      }
    }
  }

  // roamctl's per-AP failure penalties; penalized APs are dropped from the
  // scored list, so the export records which were excluded at roam time.
  FileView {
    id: penaltyView
    path: root.iface !== "" ? "/run/roamctl/" + root.iface + "_penalty.json" : ""
    watchChanges: true
    printErrors: false
  }

  Process {
    id: exportProcess
    stdout: StdioCollector {
      id: exportOut
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: exportErr
      waitForEnd: true
    }
    onExited: function(exitCode) {
      var path = String(exportOut.text || "").trim().split("\n").pop()
      if (exitCode === 0 && path !== "") {
        Quickshell.execDetached(["notify-send", "--app-name=roamctl", "--icon=x-office-spreadsheet",
          "Roam log exported", path])
        Quickshell.execDetached(["uwsm-app", "--", "nautilus", "--select", "file://" + path])
      } else {
        var message = String(exportErr.text || "").trim() || "Export failed"
        Quickshell.execDetached(["notify-send", "--app-name=roamctl", "--urgency=normal",
          "Roam export failed", message.split("\n").pop()])
      }
    }
  }

  // Pick up edits from the advanced editor (or anywhere else) as they land.
  FileView {
    path: root.configExists ? root.configPath : ""
    watchChanges: true
    printErrors: false
    onFileChanged: root.loadConfig()
  }

  onConfigPathChanged: loadConfig()
  onConfigExistsChanged: loadConfig()

  Timer {
    id: applyMessageTimer
    interval: 4000
    onTriggered: if (!root.applyFailed) root.applyMessage = ""
  }

  Process {
    id: configProcess
    stdout: StdioCollector {
      id: configOut
      waitForEnd: true
    }
    onExited: function(exitCode) {
      var parsed = Model.parseStatus(configOut.text)
      if (!parsed) return
      root.config = parsed.values || {}
      root.configErrors = parsed.errors || []
    }
  }

  Process {
    id: applyProcess
    stdout: StdioCollector {
      id: applyOut
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: applyErr
      waitForEnd: true
    }
    onExited: function(exitCode) {
      var parsed = Model.parseStatus(applyOut.text)
      var errors = parsed && parsed.errors ? parsed.errors : []
      if (exitCode === 0 && parsed && parsed.ok) {
        root.applyFailed = false
        root.applyMessage = !parsed.changed ? "No changes" : parsed.restarted ? "Applied · roamctl restarted" : "Saved · applies when roamctl starts"
      } else {
        root.applyFailed = true
        var stderr = String(applyErr.text || "").trim()
        root.applyMessage = errors.length > 0 ? errors.join("\n") : (stderr !== "" ? stderr.split("\n").pop() : "Apply failed")
      }
      applyMessageTimer.restart()
      root.loadConfig()
      root.refresh()
    }
  }

  Process {
    id: statusProcess
    stdout: StdioCollector {
      id: statusOut
      waitForEnd: true
    }
    onExited: function(exitCode) {
      if (exitCode === 0) root.applyStatus(statusOut.text)
    }
  }

  Process {
    id: controlProcess
    stderr: StdioCollector {
      id: controlErr
      waitForEnd: true
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root._desired = -1
        var message = String(controlErr.text || "").trim()
        root.lastError = message !== "" ? message.split("\n").pop() : "systemctl failed"
      }
      settleTimer.ticks = 0
      settleTimer.restart()
      root.refresh()
    }
  }
}
