pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "Presentation.js" as Presentation

// One git repository in the Repos tab: name and path on the left, branch and
// sync state on the right, with the origin underneath. Read-only — the tab is
// an inventory of what is on the machine.
Item {
  id: cell

  required property var modelData
  required property int index

  property color foreground: Color.foreground
  property string fontFamily: Style.font.family

  readonly property var repo: modelData || ({})
  readonly property string repoName: String(repo.name || "")
  readonly property bool outOfSync: (repo.ahead || 0) > 0 || (repo.behind || 0) > 0
  readonly property string statusText: {
    var parts = []
    if (repo.branch && repo.branch !== "") parts.push(repo.branch)
    if (repo.dirty) parts.push("modified")
    if ((repo.ahead || 0) > 0) parts.push("↑" + repo.ahead)
    if ((repo.behind || 0) > 0) parts.push("↓" + repo.behind)
    return parts.join("  ")
  }

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
        color: Presentation.iconColor(cell.repoName)

        Text {
          anchors.centerIn: parent
          text: "\uf1d3"
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
          text: cell.repoName
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
          text: String(cell.repo.path || "")
          textFormat: Text.PlainText
          elide: Label.ElideRight
          Layout.fillWidth: true
          Layout.minimumWidth: 0
          color: Qt.darker(cell.foreground, 1.7)
          font.family: cell.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      ColumnLayout {
        Layout.preferredWidth: Math.round(cell.width * 0.42)
        Layout.alignment: Qt.AlignVCenter
        spacing: Style.space(2)

        Label {
          text: cell.statusText
          textFormat: Text.PlainText
          elide: Label.ElideRight
          Layout.fillWidth: true
          horizontalAlignment: Text.AlignRight
          color: (cell.repo.dirty || cell.outOfSync) ? Color.accent : Qt.darker(cell.foreground, 1.4)
          font.family: cell.fontFamily
          font.pixelSize: Style.font.caption
        }

        Label {
          text: String(cell.repo.remote || "(no remote)")
          textFormat: Text.PlainText
          elide: Label.ElideRight
          Layout.fillWidth: true
          horizontalAlignment: Text.AlignRight
          color: Qt.darker(cell.foreground, 1.9)
          font.family: cell.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }

    HoverHandler { id: hover }
  }
}
