pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "Presentation.js" as Presentation

// One app in the list: a compact card — colour tile with the app's initial,
// the name and its path, a Git/Drive picker, and the on/off switch. The switch
// decides whether it syncs at all; the picker only chooses where. Presentational
// only — it reports what the user did and the panel runs the CLI.
Item {
  id: cell

  required property var modelData
  required property int index

  property color foreground: Color.foreground
  property string fontFamily: Style.font.family

  signal toggleRequested(var app)
  signal targetRequested(var app, string value)
  signal removeRequested(var app)

  readonly property var app: modelData || ({})
  readonly property string appName: String(app.name || app.id || "")
  readonly property bool isCustom: app.kind === "custom"
  readonly property bool isFolder: app.kind === "custom" || app.kind === "personal"

  implicitWidth: Style.space(440)
  implicitHeight: Style.space(58)

  Rectangle {
    id: card
    anchors.fill: parent
    anchors.topMargin: Style.space(2)
    anchors.bottomMargin: Style.space(2)
    radius: Style.cornerRadius > 0 ? Style.cornerRadius : 4
    color: hover.hovered
      ? Style.hoverFillFor(cell.foreground, Color.accent)
      : Style.normalFillFor(cell.foreground, Color.accent)
    border.color: Qt.rgba(cell.foreground.r, cell.foreground.g, cell.foreground.b, 0.12)
    border.width: 1

    RowLayout {
      anchors.fill: parent
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(10)

      Rectangle {
        Layout.preferredWidth: Style.space(28)
        Layout.preferredHeight: Style.space(28)
        Layout.alignment: Qt.AlignVCenter
        radius: 6
        color: Presentation.iconColor(cell.appName)

        Text {
          anchors.centerIn: parent
          text: cell.isFolder
            ? "\uf07b"
            : (cell.app.risky ? "\uf071" : cell.appName.trim().charAt(0).toUpperCase())
          textFormat: Text.PlainText
          color: "white"
          font.family: cell.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
        }
      }

      ColumnLayout {
        Layout.fillWidth: true
        Layout.minimumWidth: 0
        Layout.alignment: Qt.AlignVCenter
        spacing: Style.space(2)

        Label {
          text: cell.appName
          textFormat: Text.PlainText
          elide: Label.ElideRight
          Layout.fillWidth: true
          Layout.minimumWidth: 0
          color: cell.foreground
          font.family: cell.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
        }

        Label {
          Layout.fillWidth: true
          Layout.minimumWidth: 0
          text: cell.app.enabled
            ? String((cell.app.paths || [""])[0])
            : (cell.app.note || "not synced")
          textFormat: Text.PlainText
          elide: Label.ElideRight
          color: Qt.darker(cell.foreground, 1.7)
          font.family: cell.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      ButtonGroup {
        visible: cell.app.enabled
        Layout.alignment: Qt.AlignVCenter
        focusable: false
        spacing: Style.space(4)
        fontSize: Style.font.caption
        options: [
          { value: "git", label: "Git" },
          { value: "gdrive", label: "Drive" }
        ]
        value: String(cell.app.target || "git")
        foreground: cell.foreground
        accent: Color.accent
        fontFamily: cell.fontFamily
        onChanged: function(value) { cell.targetRequested(cell.app, value) }
      }

      PanelActionButton {
        // Only folder rows can be removed; the Apps tab is detection-owned.
        visible: cell.isFolder
        Layout.alignment: Qt.AlignVCenter
        iconText: "\uf00d"
        tooltipText: cell.isCustom ? "Stop syncing this folder" : "Remove from this list"
        foreground: cell.foreground
        fontFamily: cell.fontFamily
        onClicked: cell.removeRequested(cell.app)
      }

      ToggleSwitch {
        Layout.alignment: Qt.AlignVCenter
        trackHeight: Style.space(20)
        checked: !!cell.app.enabled
        foreground: cell.foreground
        accent: Color.accent
        onToggled: cell.toggleRequested(cell.app)
      }
    }

    HoverHandler { id: hover }
  }
}
