import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "jwil007.roamctl"
  ipcTarget: "jwil007.roamctl"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color accent: Color.accent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property var s: roamctl.state
  readonly property int level: s ? Model.tierLevel(s.RoamingTier) : 0
  readonly property bool critical: s !== null && s.RoamingTier === "critical"
  readonly property bool roaming: s !== null && s.RoamInProgress === true
  readonly property var candidates: s ? Model.candidates(s.BSSList, root.intSetting("candidateCount", 5, 1, 15)) : []

  readonly property string heroMeta: {
    if (!roamctl.statusKnown) return "Checking…"
    if (!roamctl.installed) return "Not installed"
    if (!roamctl.running) return "Stopped · wpa_supplicant roams on its own"
    if (!s) return roamctl.activeState === "active" ? "Connecting to " + roamctl.iface + "…" : "Starting…"
    var ssid = s.SSID || "Not associated"
    var behavior = Model.tierBehavior(s.RoamingTier)
    return ssid + (behavior ? " · " + behavior : "")
  }

  readonly property string tooltip: {
    if (!roamctl.installed) return "roamctl: not installed"
    if (!roamctl.running) return "roamctl: stopped"
    if (!s) return "roamctl: starting"
    return "roamctl · " + Model.tierLabel(s.RoamingTier) + " · " + s.RSSI + " dBm"
  }

  // Quick tuning: edits are staged in `draft` (only keys that differ from the
  // file) and written together by "Apply", which restarts roamctl.
  property bool tuningOpen: false
  property var draft: ({})
  readonly property var tuningGroups: [
    { title: "Tier floors (dBm)", from: -128, to: 0, fields: [
      { key: "roaming_tiers.excellent_rssi", label: "Excellent" },
      { key: "roaming_tiers.fair_rssi", label: "Fair" },
      { key: "roaming_tiers.degraded_rssi", label: "Degraded" }
    ] },
    { title: "Score gain needed to roam", from: 0, to: 100, fields: [
      { key: "roaming_tiers.fair_score_delta", label: "Fair" },
      { key: "roaming_tiers.degraded_score_delta", label: "Degraded" },
      { key: "roaming_tiers.critical_score_delta", label: "Critical" }
    ] },
    { title: "Band preference", from: 0, to: 100, fields: [
      { key: "band_scores.2point4ghz", label: "2.4 GHz" },
      { key: "band_scores.5ghz", label: "5 GHz" },
      { key: "band_scores.6ghz", label: "6 GHz" }
    ] }
  ]
  readonly property bool dirty: Object.keys(draft).length > 0
  readonly property string draftError: {
    var e = valueOf("roaming_tiers.excellent_rssi")
    var f = valueOf("roaming_tiers.fair_rssi")
    var d = valueOf("roaming_tiers.degraded_rssi")
    if (!(e > f)) return "Excellent must be above Fair"
    if (!(f > d)) return "Fair must be above Degraded"
    return ""
  }
  readonly property var thresholds: {
    var c = roamctl.config
    if (c["roaming_tiers.excellent_rssi"] === undefined) return []
    return [
      { value: c["roaming_tiers.excellent_rssi"], label: "E" },
      { value: c["roaming_tiers.fair_rssi"], label: "F" },
      { value: c["roaming_tiers.degraded_rssi"], label: "D" }
    ]
  }

  function setTuningOpen(on) {
    tuningOpen = on
    if (on) Qt.callLater(function() { panelFlick.contentY = Math.max(0, panelFlick.contentHeight - panelFlick.height) })
  }

  function valueOf(key) {
    if (draft[key] !== undefined) return draft[key]
    var v = Number(roamctl.config[key])
    return isFinite(v) ? v : 0
  }

  function setDraft(key, value) {
    var next = Object.assign({}, draft)
    if (value === Number(roamctl.config[key])) delete next[key]
    else next[key] = value
    draft = next
  }

  function applyDraft() {
    if (!dirty || draftError !== "" || roamctl.applying) return
    roamctl.applyConfig(draft)
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    return Math.max(min, Math.min(max, n))
  }

  function run(action) {
    if (action === "tui") roamctl.openTui()
    else if (action === "config") roamctl.editConfig()
    else if (action === "logs") roamctl.openLogs()
    else if (action === "restart") roamctl.restart()
    else if (action === "install") roamctl.install()
    else if (action === "setup") roamctl.setup()
    else if (action === "export") { roamctl.exportRoams(); return }
    else return
    if (action !== "restart") root.close()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    roamctl.refresh()
    roamctl.loadConfig()
    if (panelFlick && !tuningOpen) panelFlick.contentY = 0
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Service {
    id: roamctl
    settings: root.settings
    panelOpen: root.opened
  }

  Connections {
    target: roamctl
    function onApplyingChanged() {
      if (!roamctl.applying && !roamctl.applyFailed) root.draft = ({})
    }
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function tui(): void { roamctl.openTui() }
    function exportRoams(): void { roamctl.exportRoams() }
    function tuning(): void { root.open(); root.setTuningOpen(true) }
    function enable(): void { roamctl.setRunning(true) }
    function disable(): void { roamctl.setRunning(false) }
    function status(): string { return root.tooltip }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: root.tooltip
    iconComponent: Component {
      Item {
        TierBars {
          anchors.centerIn: parent
          iconSize: Style.space(13)
          level: root.level
          color: root.critical ? root.urgent : root.barForeground
          opacity: roamctl.running ? 1.0 : 0.45
          pulsing: root.roaming
        }
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) roamctl.openTui()
      else if (buttonCode === Qt.RightButton) roamctl.toggleRunning()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(760))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onActivateRequested: roamctl.installed ? roamctl.toggleRunning() : root.run("install")
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        var key = String(t).toLowerCase()
        if (key === "t") root.run("tui")
        else if (key === "c") root.run("config")
        else if (key === "e") root.run("export")
        else if (key === "l") root.run("logs")
        else if (key === "r") root.run("restart")
        else if (key === "i" && !roamctl.installed) root.run("install")
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { id: vbar; policy: ScrollBar.AsNeeded }

        Column {
          id: column
          // Leave a gutter for the scrollbar so it doesn't cover the right
          // edge of the content (e.g. the tuning fields) while scrolling.
          width: panelFlick.width - (panelFlick.interactive ? vbar.width + Style.space(4) : 0)
          spacing: Style.space(12)

          PanelHero {
            id: hero
            width: parent.width
            title: "roamctl"
            detail: root.s ? Model.tierLabel(root.s.RoamingTier) : ""
            meta: root.heroMeta
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: roamctl.running ? 1.0 : 0.5
            iconComponent: Component {
              TierBars {
                iconSize: Style.font.display
                level: root.level
                color: root.critical ? root.urgent : root.foreground
                pulsing: root.roaming
              }
            }
            trailingControl: Component {
              ToggleSwitch {
                id: powerSwitch
                visible: roamctl.installed
                checked: roamctl.running
                busy: roamctl.busy
                foreground: hero.foreground
                onToggled: roamctl.toggleRunning()

                PanelToolTip {
                  visible: powerSwitch.containsMouse
                  text: roamctl.running ? "Stop and disable roamctl@" + roamctl.iface : "Enable and start roamctl@" + roamctl.iface
                  fontFamily: hero.fontFamily
                }
              }
            }
          }

          Text {
            visible: roamctl.lastError !== ""
            width: parent.width
            textFormat: Text.PlainText
            text: roamctl.lastError
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          ActionRow {
            visible: roamctl.statusKnown && !roamctl.installed
            width: parent.width
            glyph: "\uf019"
            title: "Install roamctl"
            subtitle: "Download the latest release from github.com/jwil007/roamctl"
            onActivated: root.run("install")
          }

          RowLayout {
            visible: roamctl.installed
            width: parent.width
            spacing: Style.space(6)

            Text {
              Layout.fillWidth: true
              textFormat: Text.PlainText
              text: roamctl.iface + (roamctl.version ? " · " + roamctl.version : "")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }

            PanelActionButton {
              iconText: "\uf120"
              tooltipText: "Open roamctl-tui (t)"
              foreground: root.foreground
              fontFamily: root.fontFamily
              enabled: roamctl.running && roamctl.tuiInstalled
              onClicked: root.run("tui")
            }
            PanelActionButton {
              iconText: "\uf1c3"
              tooltipText: roamctl.roamsLogged > 0
                ? "Export " + roamctl.roamsLogged + " logged roam" + (roamctl.roamsLogged === 1 ? "" : "s") + " with scan lists to CSV (e)"
                : "Export roams to CSV (e) · nothing logged yet"
              foreground: root.foreground
              fontFamily: root.fontFamily
              enabled: roamctl.roamsLogged > 0 && !roamctl.exporting
              onClicked: root.run("export")
            }
            PanelActionButton {
              iconText: "\uf03a"
              tooltipText: "Follow logs (l)"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.run("logs")
            }
            PanelActionButton {
              iconText: "\uf021"
              tooltipText: "Restart service (r)"
              foreground: root.foreground
              fontFamily: root.fontFamily
              enabled: roamctl.running && !roamctl.busy
              onClicked: root.run("restart")
            }
          }

          // Live connection details
          Column {
            visible: root.s !== null
            width: parent.width
            spacing: Style.spacing.labelGap

            InfoPair { label: "Access point"; value: root.s ? (root.s.BSSID || "—") : "" }
            InfoPair { label: "Channel"; value: root.s ? Model.channelText(root.s.Freq, root.s.ChannelWidth) : "" }
            InfoPair {
              label: "Signal"
              value: root.s ? Model.rssiText(root.s.RSSI, root.s.AvgRSSI) : ""
              valueColor: root.critical ? root.urgent : root.foreground
            }
            InfoPair { label: "Tx"; value: root.s ? Model.rateText(root.s.TxBitrate, root.s.TxMCS) + (root.s.TxPHY ? " · " + root.s.TxPHY : "") : "" }
            InfoPair { label: "Rx"; value: root.s ? Model.rateText(root.s.RxBitrate, root.s.RxMCS) + (root.s.RxPHY ? " · " + root.s.RxPHY : "") : "" }
            InfoPair {
              label: "Retries"
              value: root.s ? root.s.RetryRate + "%" + (root.s.UnhealthyConn ? " · unhealthy" : "") : ""
              valueColor: root.s && root.s.UnhealthyConn ? root.urgent : root.foreground
            }
            InfoPair { label: "Connected"; value: root.s ? Model.durationText(root.s.ConnDuration) : "" }
            InfoPair { label: "Scanning"; value: Model.scanText(root.s) }
          }

          PanelSeparator { visible: roamctl.rssiHistory.length > 1; foreground: root.foreground }

          Column {
            visible: roamctl.rssiHistory.length > 1
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              text: "SIGNAL · LAST " + roamctl.historyLength + "S"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Sparkline {
              width: parent.width
              height: Style.space(72)
              values: roamctl.rssiHistory
              capacity: roamctl.historyLength
              lineColor: root.critical ? root.urgent : root.accent
              gridColor: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
              labelColor: root.dim
              fontFamily: root.fontFamily
              thresholds: root.thresholds
            }
          }

          PanelSeparator { visible: root.candidates.length > 0; foreground: root.foreground }

          Column {
            visible: root.candidates.length > 0
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              text: "SCORED APS · " + (root.s && root.s.BSSList ? root.s.BSSList.length : 0)
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.candidates
              BssRow {
                required property var modelData
                width: parent.width
                bss: modelData
              }
            }
          }

          PanelSeparator { visible: roamctl.roams.length > 0; foreground: root.foreground }

          Column {
            visible: roamctl.roams.length > 0
            width: parent.width
            spacing: Style.space(4)

            PanelSectionHeader {
              text: "RECENT ROAMS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: roamctl.roams
              InfoPair {
                required property var modelData
                label: Model.clockText(modelData.at) + "  " + (modelData.success ? "→ " + Model.shortBssid(modelData.bssid) : "✕ failed")
                value: modelData.success ? modelData.durationMs + " ms" : ""
                valueColor: modelData.success ? root.foreground : root.urgent
              }
            }
          }

          PanelSeparator { visible: roamctl.configExists; foreground: root.foreground }

          Column {
            id: tuningSection
            visible: roamctl.configExists
            width: parent.width
            spacing: Style.space(10)

            RowLayout {
              width: parent.width
              spacing: Style.space(6)

              PanelSectionHeader {
                Layout.fillWidth: true
                text: (root.tuningOpen ? "▾ " : "▸ ") + "TUNING" + (root.dirty ? " · UNSAVED" : "")
                foreground: root.foreground
                fontFamily: root.fontFamily

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.setTuningOpen(!root.tuningOpen)
                }
              }

              PanelActionButton {
                iconText: "\uf044"
                tooltipText: "Edit full config · restarts roamctl when you close the editor"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.run("config")
              }
            }

            ActionRow {
              visible: root.tuningOpen && !(roamctl.configWritable && roamctl.setupCurrent)
              width: parent.width
              glyph: "\uf084"
              title: "Enable quick tuning"
              subtitle: "One-time sudo: lets wheel edit the config and restart roamctl"
              onActivated: root.run("setup")
            }

            Column {
              visible: root.tuningOpen && roamctl.configWritable && roamctl.setupCurrent
              width: parent.width
              spacing: Style.space(10)

              Repeater {
                model: root.tuningGroups

                Column {
                  id: group
                  required property var modelData
                  width: parent.width
                  spacing: Style.space(4)

                  Text {
                    textFormat: Text.PlainText
                    text: group.modelData.title
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }

                  Row {
                    id: fieldRow
                    width: parent.width
                    spacing: Style.space(8)
                    readonly property real cellWidth: (width - spacing * 2) / 3

                    Repeater {
                      model: group.modelData.fields
                      NumberField {
                        required property var modelData
                        label: modelData.label + (root.draft[modelData.key] !== undefined ? " •" : "")
                        from: group.modelData.from
                        to: group.modelData.to
                        value: root.valueOf(modelData.key)
                        fieldWidth: fieldRow.cellWidth
                        foreground: root.foreground
                        accent: root.accent
                        fontFamily: root.fontFamily
                        fontSize: Style.font.bodySmall
                        onModified: function(v) { root.setDraft(modelData.key, v) }
                        // Typing into the SpinBox breaks its binding to `value`;
                        // push Reset / reloaded values back in explicitly.
                        onValueChanged: if (field.value !== value) field.value = value
                      }
                    }
                  }
                }
              }

              Text {
                visible: text !== ""
                width: parent.width
                textFormat: Text.PlainText
                text: root.draftError !== "" ? root.draftError : roamctl.applyMessage
                color: root.draftError !== "" || roamctl.applyFailed ? root.urgent : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }

              Row {
                anchors.right: parent.right
                spacing: Style.space(6)

                Button {
                  text: "Reset"
                  fontSize: Style.font.bodySmall
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  bordered: true
                  enabled: root.dirty && !roamctl.applying
                  opacity: enabled ? 1 : 0.4
                  onClicked: root.draft = ({})
                }
                Button {
                  text: roamctl.applying ? "Applying…" : roamctl.running ? "Apply & restart" : "Save"
                  fontSize: Style.font.bodySmall
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  bordered: true
                  active: root.dirty && root.draftError === ""
                  enabled: root.dirty && root.draftError === "" && !roamctl.applying
                  opacity: enabled ? 1 : 0.4
                  onClicked: root.applyDraft()
                }
              }
            }
          }
        }
      }
    }
  }

  component ActionRow: CursorSurface {
    id: actionRow
    property string glyph: ""
    property string title: ""
    property string subtitle: ""
    signal activated()

    foreground: root.foreground
    hasCursor: rowMouse.containsMouse
    implicitHeight: actionContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: actionRow.activated()
    }

    RowLayout {
      id: actionContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(10)

      Text {
        text: actionRow.glyph
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.heading
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(1)
        Text {
          Layout.fillWidth: true
          textFormat: Text.PlainText
          text: actionRow.title
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }
        Text {
          Layout.fillWidth: true
          textFormat: Text.PlainText
          text: actionRow.subtitle
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }
  }

  component BssRow: Item {
    id: bssRow
    property var bss: null
    readonly property bool current: bss && bss.IsCurrentAP === true

    implicitHeight: bssContent.implicitHeight

    RowLayout {
      id: bssContent
      anchors.left: parent.left
      anchors.right: parent.right
      spacing: Style.space(8)

      Text {
        text: bssRow.current ? "●" : "○"
        color: bssRow.current ? root.accent : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: 0
        Text {
          Layout.fillWidth: true
          textFormat: Text.PlainText
          text: bssRow.bss ? bssRow.bss.BSSID : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }
        Text {
          Layout.fillWidth: true
          textFormat: Text.PlainText
          text: Model.bssMeta(bssRow.bss)
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      ColumnLayout {
        spacing: 0
        Layout.alignment: Qt.AlignVCenter
        Text {
          Layout.alignment: Qt.AlignRight
          textFormat: Text.PlainText
          text: bssRow.bss ? String(bssRow.bss.FinalScore) : ""
          color: bssRow.current ? root.accent : root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
        }
        Text {
          Layout.alignment: Qt.AlignRight
          textFormat: Text.PlainText
          text: bssRow.bss ? bssRow.bss.RSSI + " dBm" : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }

  component InfoPair: RowLayout {
    property string label: ""
    property string value: ""
    property color valueColor: root.foreground

    width: parent ? parent.width : 0
    spacing: Style.space(8)

    Text {
      textFormat: Text.PlainText
      text: parent.label
      color: root.foreground
      opacity: 0.6
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
    Item { Layout.fillWidth: true }
    Text {
      Layout.maximumWidth: Style.space(260)
      textFormat: Text.PlainText
      text: parent.value
      color: parent.valueColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }
  }
}
