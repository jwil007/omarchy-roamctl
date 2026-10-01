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
  readonly property bool streaming: socket.connected && state !== null
  property var state: null
  property var rssiHistory: []
  property var roams: []
  readonly property int historyLength: 90

  property string _pendingLine: ""
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
    if (!next) return
    state = next
    detectRoam(next)
  }

  function pushRssi(rssi) {
    if (!rssi) return
    var next = rssiHistory.slice(Math.max(0, rssiHistory.length - historyLength + 1))
    next.push(rssi)
    rssiHistory = next
  }

  function detectRoam(s) {
    var completedAt = Model.isZeroTime(s.CompletedAt) ? "" : String(s.CompletedAt)
    // The first frame after (re)connecting carries whatever roam happened
    // before we attached; remember it without announcing it.
    if (!_roamBaseline) {
      _roamBaseline = true
      _lastRoamAt = completedAt
      return
    }
    if (completedAt === "" || completedAt === _lastRoamAt) return
    _lastRoamAt = completedAt

    var target = Model.findBss(s.BSSList, s.FinalBSSID || s.TargetBSSID)
    var entry = {
      at: new Date(),
      success: s.Success === true,
      bssid: String(s.FinalBSSID || s.TargetBSSID || ""),
      durationMs: Model.durationMs(s.Duration),
      summary: Model.roamSummary(s, target),
      tier: Model.tierLabel(s.RoamingTier)
    }
    roams = [entry].concat(roams).slice(0, 8)

    if (notifyRoams) {
      Quickshell.execDetached([
        "notify-send", "--app-name=roamctl", "--transient",
        "--urgency=" + (entry.success ? "low" : "normal"),
        "--icon=network-wireless",
        entry.success ? "Wi-Fi roamed" : "Wi-Fi roam failed",
        entry.summary
      ])
    }
  }

  onSocketPathChanged: { state = null; rssiHistory = []; _roamBaseline = false }

  Socket {
    id: socket
    path: root.socketPath
    connected: root.active && root.socketPath !== ""
    parser: SplitParser {
      onRead: function(line) { root._pendingLine = line }
    }
    onConnectedChanged: {
      root._roamBaseline = false
      if (!connected) root.state = null
    }
    onError: function(error) {
      if (!root.socketAccess) root.lastError = "No access to " + root.socketPath + " — rerun install to add the socket drop-in"
    }
  }

  // roamctl creates its socket a moment after the unit goes active, and
  // restarts on failure; keep nudging the socket until it attaches.
  Timer {
    interval: 2000
    repeat: true
    running: root.active && !socket.connected
    onTriggered: {
      socket.connected = false
      socket.connected = Qt.binding(function() { return root.active && root.socketPath !== "" })
    }
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
    running: socket.connected
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
