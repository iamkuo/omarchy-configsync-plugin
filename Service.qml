import QtQuick
import Quickshell
import Quickshell.Io

// The plugin's always-on half — deliberately small.
//
// Watching is two things, and neither of them is this file:
//   * the change watchers, which are Omarchy's own rsw processes: inotifywait
//     plus `rsync -a` per path, listed by `lsw` and stopped by `dsw`;
//   * a periodic full pass, which is a systemd user timer on a machine with a
//     user session.
//
// This service exists for the machine that has no user session bus: it asks the
// CLI to start the watchers when the shell comes up, and runs the same full pass
// on a Qt timer instead of the systemd one. Everything it does is one CLI call,
// so the work and the reporting stay in one place.
Scope {
  id: root

  property string omarchyPath: ""
  property var shell: null
  property var manifest: null

  readonly property string scriptPath: Qt.resolvedUrl("bin/configsync").toString().replace("file://", "")
  readonly property string statePath: Quickshell.env("HOME") + "/.config/omarchy/configsync.json"

  property bool watchEnabled: false
  property int pullMinutes: 10
  property bool systemd: false
  property bool loaded: false

  function parseConfig() {
    try {
      var d = JSON.parse(stateFile.text())
      var watch = (d && d.watch) || null
      var legacy = (d && d.auto) || null
      // An older state file has no `watch` key; its interval switch means the
      // same thing, and the CLI migrates it on the next write.
      root.watchEnabled = watch ? !!watch.enabled : !!(legacy && legacy.enabled)
      root.pullMinutes = (watch && Number(watch.pullMinutes)) || 10
      root.systemd = !!(watch && watch.systemd)
      root.loaded = true
    } catch (e) {
      // No state file yet, or mid-read: leave things as they are.
    }
    root.ensureWatchers()
  }

  // systemd owns the timer when it is there; without it, this service does.
  function ensureWatchers() {
    if (!root.loaded || !root.watchEnabled || root.systemd) return
    ensureProc.command = ["python3", root.scriptPath, "watch", "--ensure"]
    ensureProc.running = true
  }

  function pullNow() {
    if (pullProc.running) return
    pullProc.command = ["python3", root.scriptPath, "watch", "--once"]
    pullProc.running = true
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
  Process { id: ensureProc }

  // The full pass. systemd runs this too, and the CLI takes a lock, so a pass
  // that starts while the other one is running simply reports that and exits.
  Process {
    id: pullProc
    onExited: restartTimer.restart()
  }

  // One catch-up pass shortly after the shell starts, the way the systemd timer
  // does at boot.
  Timer {
    interval: 45000
    running: root.loaded && root.watchEnabled && !root.systemd
    repeat: false
    onTriggered: root.pullNow()
  }

  Timer {
    id: passTimer
    interval: Math.max(1, root.pullMinutes) * 60000
    running: root.loaded && root.watchEnabled && !root.systemd
    repeat: true
    onTriggered: root.pullNow()
  }

  // A watcher that dies (its tree was removed, inotify gave up) is noticed on
  // the next pass, which starts it again.
  Timer {
    id: restartTimer
    interval: 15000
    repeat: false
    onTriggered: root.ensureWatchers()
  }

  IpcHandler {
    target: "configsync"
    function sync(): void { root.syncNow() }
    function refresh(): void { root.parseConfig() }
  }
}
