import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

// The bar's way into Config Sync: a sync icon that opens the popup. The popup
// itself is loaded hidden here and receives the bar, its settings, and the
// button to anchor to — the same split Omaplug uses, so the widget is the
// panel's identity for summon/hide routing.
BarWidget {
  id: root
  moduleName: "io.github.ryankuo.configsync"

  readonly property bool opened: panelItem ? panelItem.opened === true : false

  function open() { if (panelItem) panelItem.open() }
  function close() { if (panelItem) panelItem.close() }
  function togglePanel() { if (panelItem) panelItem.toggle() }
  function toggle() { togglePanel() }

  property var panelItem: null

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    panelItem = target
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰓦"
    tooltipText: root.opened ? "Close Config Sync" : "Config Sync"
    active: root.opened
    onPressed: function(b) {
      if (b === Qt.LeftButton) root.togglePanel()
    }
  }
}
