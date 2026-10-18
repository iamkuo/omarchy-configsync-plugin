import QtQuick
import Quickshell
import Quickshell.Io

// The plugin's always-on half.
//
// Watching is normally a systemd user service: the panel installs it when
// Watch is switched on, and it keeps running across shell restarts. This
// service is the fallback for a machine without a user session — it keeps
// `configsync watch` alive as a child, restarts it if it dies, and stops it
// when Watch is switched off. The CLI's own lock file means the two can never
// both be doing the work, so a duplicate simply exits.
//
// It also gives the panel (and anything else) an IPC route to sync without
// opening the popup.
Scope {
  id: root

  property string omarchyPath: ""
  property var shell: null
  property var manifest: null

  readonly property string scriptPath: Qt.resolvedUrl("bin/configsync").toString().replace("file://", "")
  readonly property string statePath: Quickshell.env("HOME") + "/.config/omarchy/configsync.json"

  property bool watchEnabled: false
  property bool watchRunning: false
  property bool serviceActive: false
  property bool loaded: false

  function parseConfig() {
    try {
      var d = JSON.parse(stateFile.text())
      var watch = (d && d.watch) || null
      var legacy = (d && d.auto) || null
      // An older state file has no `watch` key; its interval switch means the
      // same thing, and the CLI migrates it on the next write.
      root.watchEnabled = watch ? !!watch.enabled : !!(legacy && legacy.enabled)
      root.loaded = true
    } catch (e) {
      // No state file yet, or mid-write: leave the watcher off until it reads.
    }
    root.reconcile()
  }

  // Ensure exactly one watcher: ours, or the systemd one.
  function reconcile() {
    if (!root.loaded) return
    var managedElsewhere = root.watchRunning || root.serviceActive
    if (!root.watchEnabled || managedElsewhere) {
      if (watcher.running) watcher.running = false
      return
    }
    if (watcher.running) return
    watcher.command = ["python3", root.scriptPath, "watch"]
    watcher.running = true
  }

  function checkStatus() {
    if (statusProc.running) return
    statusProc.command = ["python3", root.scriptPath, "state"]
    statusProc.running = true
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

  // The fallback watcher. It runs until Watch is switched off, or until it
  // finds that the systemd service already holds the lock.
  Process {
    id: watcher
    onExited: restartTimer.restart()
  }

  Process {
    id: statusProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var d = JSON.parse(text)
          var w = (d && d.watch) || {}
          root.watchRunning = !!w.running
          root.serviceActive = !!((w.service || {}).active)
        } catch (e) {
          // Leave the last reading; the next check is a minute away.
        }
        root.reconcile()
      }
    }
  }

  Timer {
    id: statusTimer
    interval: 60000
    running: root.loaded
    repeat: true
    onTriggered: root.checkStatus()
  }

  // A short delay before restarting a child that just exited, so a watcher
  // that cannot start does not spin.
  Timer {
    id: restartTimer
    interval: 30000
    repeat: false
    onTriggered: root.checkStatus()
  }

  Timer {
    interval: 8000
    running: true
    repeat: false
    onTriggered: root.checkStatus()
  }

  IpcHandler {
    target: "configsync"
    function sync(): void { root.syncNow() }
    function refresh(): void { root.checkStatus() }
  }
}
