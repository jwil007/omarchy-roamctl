import QtQuick
import qs.Commons

// Four ascending signal bars; `level` (0–4) of them are lit. Deliberately not
// a Wi-Fi fan so it reads differently from the network widget next to it.
Item {
  id: root

  property real iconSize: Style.font.icon
  property int level: 0
  property color color: Color.foreground
  property color dimColor: Qt.rgba(color.r, color.g, color.b, 0.28)
  property bool pulsing: false

  implicitWidth: iconSize
  implicitHeight: iconSize
  width: implicitWidth
  height: implicitHeight

  Row {
    id: bars
    anchors.centerIn: parent
    spacing: Math.max(1, Math.round(root.iconSize * 0.1))
    readonly property real barWidth: Math.max(2, Math.round((root.iconSize * 0.84 - spacing * 3) / 4))

    Repeater {
      model: 4
      Rectangle {
        required property int index
        anchors.bottom: parent.bottom
        width: bars.barWidth
        height: Math.round(root.iconSize * (0.34 + index * 0.22))
        radius: Math.min(width / 2, Style.cornerRadius > 0 ? 1 : 0)
        color: index < root.level ? root.color : root.dimColor
      }
    }
  }

  SequentialAnimation on opacity {
    running: root.pulsing
    loops: Animation.Infinite
    alwaysRunToEnd: true
    NumberAnimation { to: 0.35; duration: 380; easing.type: Easing.InOutQuad }
    NumberAnimation { to: 1.0; duration: 380; easing.type: Easing.InOutQuad }
  }
}
