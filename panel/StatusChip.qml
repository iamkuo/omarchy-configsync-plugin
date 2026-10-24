pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Ui

// A compact, clickable status pill for the footer. It says one thing about one
// area (Git, Drive, watchers, software, trash) and reports a click so the panel
// can open the details and the actions.
BorderSurface {
  id: chip

  property string icon: ""
  property string label: ""
  property string tone: "off"        // ok | warn | off | busy
  property string tooltipText: ""
  property color foreground: Color.foreground
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  signal clicked()

  readonly property color toneColor: tone === "warn" ? Color.urgent
    : tone === "ok" ? accent
    : tone === "busy" ? accent
    : Qt.darker(foreground, 1.9)
  readonly property bool _hot: mouse.containsMouse

  implicitWidth: row.implicitWidth + Style.space(18)
  implicitHeight: Style.space(26)
  radius: height / 2
  color: _hot
    ? Style.hoverFillFor(foreground, accent)
    : Style.normalFillFor(foreground, accent)
  borderSpec: Border.controlSpec(_hot ? "hover-cursor" : "normal", foreground, accent)

  RowLayout {
    id: row
    anchors.centerIn: parent
    spacing: Style.space(5)

    Text {
      text: chip.icon
      textFormat: Text.PlainText
      color: chip.toneColor
      font.family: chip.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Text {
      text: chip.label
      textFormat: Text.PlainText
      elide: Text.ElideRight
      color: chip.tone === "off" ? Qt.darker(chip.foreground, 1.6) : chip.foreground
      font.family: chip.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: chip.clicked()
  }

  ToolTip.text: chip.tooltipText
  ToolTip.visible: mouse.containsMouse && chip.tooltipText !== ""
  ToolTip.delay: 400
}
