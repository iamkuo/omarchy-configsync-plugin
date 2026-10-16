import QtQuick
import Quickshell
import Quickshell.Io

// The plugin's always-on half: it watches the state file and, when Auto is on,
// runs a background sync on the chosen interval. It also gives the panel (and
// anything else) an IPC route to trigger a sync without opening the panel.
//
// The panel is the only UI; this service has none. Keeping the timer here means
// automatic syncs happen whether or not the popup was ever opened.
Scope {
  id: root

  property string omarchyPath: ""
  property var shell: null
  property var manifest: null

  readonly property string scriptPath: Qt.resolvedUrl("bin/configsync").toString().replace("file://", "")
  readonly property string statePath: Quickshell.env("HOME") + "/.config/omarchy/configsync.json"

  property bool autoEnabled: false
  property int autoIntervalMinutes: 30

  function parseConfig() {
    try {
      var d = JSON.parse(stateFile.text())
      var auto = (d && d.auto) || {}
      root.autoEnabled = !!auto.enabled
      root.autoIntervalMinutes = Number(auto.intervalMinutes) || 30
    } catch (e) {
      // No state file yet, or mid-write: leave Auto off until it reads.
    }
  }

  function syncNow() {
    if (syncProc.running) return
    syncProc.command = ["python3", root.scriptPath, "sync"]
    syncProc.running = true
  }

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: true
    onLoaded: root.parseConfig()
    onFileChanged: { reload(); root.parseConfig() }
  }

  Process { id: syncProc }

  Timer {
    id: autoTimer
    running: root.autoEnabled
    interval: Math.max(5, root.autoIntervalMinutes) * 60000
    repeat: true
    onTriggered: root.syncNow()
  }

  // One catch-up sync a little after the shell starts, if Auto is on.
  Timer {
    interval: 45000
    running: root.autoEnabled
    repeat: false
    onTriggered: root.syncNow()
  }

  IpcHandler {
    target: "configsync"
    function sync(): void { root.syncNow() }
    function refresh(): void { root.parseConfig() }
  }
}
