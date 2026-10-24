pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "panel" as Cells

// Config Sync popup.
//
// One list of everything that can sync (app configs and personal folders
// together), one primary action, and one switch that decides whether changes
// are watched and pushed as they happen. The backend fields stay collapsed
// once both are set, because they are configured once and read never.
//
// Every action is a CLI call followed by a re-read of the state, so the panel
// never holds a second copy of the truth.
Panel {
  id: root
  moduleName: "io.github.ryankuo.configsync"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null

  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string scriptPath: Qt.resolvedUrl("bin/configsync").toString().replace("file://", "")

  property var stateData: ({ apps: [], git: {}, gdrive: {}, watch: {}, lastSync: {}, software: {} })
  property var reposData: []
  property var softwarePlan: null
  // Snapshots: the rolling commit first, then the tags the user named. The
  // panel never invents a point of its own — it lists what the CLI reports.
  property var snapshots: []
  property bool snapshotsBusy: false
  property string snapshotDraft: ""
  property string snapshotRenameFrom: ""
  property string resumeTarget: ""
  property bool resumeArmed: false
  property bool reposBusy: false
  property bool loaded: false
  property bool busy: false
  property bool refreshOwed: false
  property bool resetArmed: false
  property bool backendsOpen: false
  property string tab: "items"

  // Drafts for the two backend fields, so a refresh does not clobber typing.
  property string gitDraft: ""
  property string gdriveDraft: ""

  readonly property var apps: root.stateData.apps || []
  readonly property var watchInfo: root.stateData.watch || ({})
  readonly property bool watchOn: !!root.watchInfo.enabled
  readonly property var gitInfo: root.stateData.git || ({})
  readonly property var driveInfo: root.stateData.gdrive || ({})
  readonly property var lastInfo: root.stateData.lastSync || ({})
  readonly property var gitLast: root.lastInfo.git || ({})
  readonly property var driveLast: root.lastInfo.drive || ({})
  readonly property var softwareInfo: root.stateData.software || ({})
  readonly property int trashCount: root.stateData.trash || 0
  property string statusDetail: ""
  property string busyKind: ""

  readonly property bool gitBusy: root.busy && (root.busyKind === "sync"
    || root.busyKind === "download" || root.busyKind === "deploy")
  readonly property bool driveBusy: root.busy && (root.busyKind === "sync"
    || root.busyKind === "deploy")
  readonly property bool watchBusy: root.busy && root.busyKind === "watch"
  readonly property bool softwareBusy: root.busy && root.busyKind === "install-software"

  readonly property string gitChipLabel: {
    if (!root.gitInfo.configured) return "Git not set"
    if (root.gitBusy) return "Git syncing…"
    if (root.gitLast.published === false) return "Git push refused"
    var a = Number(root.gitInfo.ahead || 0)
    var b = Number(root.gitInfo.behind || 0)
    if (a && b) return "Git ↑" + a + " ↓" + b
    if (a) return "Git ↑" + a + " to send"
    if (b) return "Git ↓" + b + " to bring"
    return root.gitLast.at ? "Git up to date" : "Git idle"
  }
  readonly property string gitChipTone: {
    if (!root.gitInfo.configured) return "off"
    if (root.gitBusy) return "busy"
    if (root.gitLast.ok === false || root.gitLast.published === false) return "warn"
    return root.gitLast.at ? "ok" : "off"
  }
  readonly property string driveChipLabel: {
    if (!root.driveInfo.configured) return "Drive not set"
    if (!root.driveInfo.available) return "Drive not mounted"
    if (root.driveBusy) return "Drive syncing…"
    return root.driveLast.at ? "Drive synced" : "Drive idle"
  }
  readonly property string driveChipTone: {
    if (!root.driveInfo.configured) return "off"
    if (!root.driveInfo.available || root.driveLast.ok === false) return "warn"
    if (root.driveBusy) return "busy"
    return root.driveLast.at ? "ok" : "off"
  }
  readonly property int watchRunning: root.watchInfo.watching || 0
  readonly property int watchExpected: root.watchInfo.expected || 0
  readonly property string watchChipLabel: {
    if (!root.watchOn) return "Watch off"
    if (root.watchBusy) return "Watch starting…"
    if (root.watchExpected && root.watchRunning < root.watchExpected)
      return "Watch " + root.watchRunning + "/" + root.watchExpected
    return "Watch " + root.watchRunning + " path(s)"
  }
  readonly property string watchChipTone: {
    if (!root.watchOn) return "off"
    if (root.watchBusy) return "busy"
    if (root.watchExpected && root.watchRunning < root.watchExpected) return "warn"
    return "ok"
  }
  readonly property string softwareChipLabel: {
    var s = root.softwareInfo
    if (!s.captured) return "Software not recorded"
    return s.plugins + " plugins · " + s.packages + " pkgs"
  }
  readonly property string softwareChipTone: root.softwareInfo.captured ? "ok" : "off"
  readonly property string trashChipLabel: root.trashCount + " in trash"
  readonly property string lastLine: {
    var s = root.lastInfo
    if (!s.at) return "Never synced — press Sync now"
    var parts = []
    if (s.pushed) parts.push(s.pushed + " sent")
    if (s.pulled) parts.push(s.pulled + " received")
    if (s.deleted) parts.push(s.deleted + " removed")
    var body = parts.length ? parts.join(" · ") : "up to date"
    if (s.conflicts) body += " · " + s.conflicts + " conflict(s)"
    if (s.ok === false) body = "⚠  " + body
    return "Last pass " + s.at + " · " + body
  }

  readonly property string statusTitle: {
    switch (root.statusDetail) {
      case "git": return "Git backend"
      case "drive": return "Google Drive"
      case "watch": return "Change watchers"
      case "software": return "Plugins and packages"
      case "trash": return "Trash"
      default: return "Last pass"
    }
  }
  readonly property string statusBody: {
    switch (root.statusDetail) {
      case "git": {
        var g = root.gitLast
        var out = []
        out.push(root.gitInfo.configured ? root.shorten(String(root.gitInfo.remote || "")) : "No remote set.")
        out.push("Branch " + String(root.gitInfo.branch || "main")
                 + " · ahead " + Number(root.gitInfo.ahead || 0)
                 + " · behind " + Number(root.gitInfo.behind || 0))
        if (g.at) out.push("Last pass " + g.at + ": " + Number(g.pushed || 0) + " sent, "
                           + Number(g.pulled || 0) + " received, "
                           + Number(g.deleted || 0) + " removed.")
        else out.push("No pass has run yet.")
        if (g.published === false) out.push("The last push was refused, so the next pass reconciles against the remote.")
        return out.join("\n")
      }
      case "drive": {
        var d = root.driveLast
        var out2 = []
        out2.push(root.driveInfo.configured ? root.shorten(String(root.driveInfo.remote || "")) : "No folder set.")
        out2.push(root.driveInfo.available ? "The folder is available."
                                           : "The folder is missing — mount it (rclone) first.")
        if (d.at) out2.push("Last pass " + d.at + ": " + Number(d.pushed || 0) + " sent, "
                            + Number(d.pulled || 0) + " received, "
                            + Number(d.deleted || 0) + " removed.")
        else out2.push("No pass has run yet.")
        return out2.join("\n")
      }
      case "watch": {
        var out3 = []
        out3.push(root.watchOn ? "Watching is on."
                               : "Watching is off; sync runs only when you press Sync now.")
        out3.push(root.watchRunning + " of " + root.watchExpected + " enabled path(s) watched.")
        out3.push("Full pass every " + Number(root.watchInfo.pullMinutes || 10) + " min ("
                  + (root.watchInfo.systemd ? "systemd timer" : "inside the shell") + ").")
        if (root.watchInfo.lastPass)
          out3.push("Last pass " + root.watchInfo.lastPass + ": " + (root.watchInfo.lastResult || "ok"))
        return out3.join("\n")
      }
      case "software": {
        var s = root.softwareInfo
        if (!s.captured) return "No manifest yet — Sync records your plugins and packages."
        return "Captured " + String(s.capturedAt || "?") + ": " + s.plugins
          + " plugin(s), " + s.packages + " package(s).\nOnly what is missing gets installed."
      }
      case "trash":
        return root.trashCount + " file(s) in the trash.\n"
          + "Restoring puts them back where they were; nothing is overwritten."
      default: {
        var s2 = root.lastInfo
        var out4 = [String(s2.message || "never synced")]
        if (s2.at) out4.push("at " + s2.at)
        var notes = s2.notes || []
        for (var i = 0; i < notes.length; i++) out4.push("· " + notes[i])
        return out4.join("\n")
      }
    }
  }

  // Enabled items float to the top, then alphabetical — so what is syncing is
  // always the first thing in view.
  readonly property var shown: {
    var out = root.apps.slice()
    out.sort(function(a, b) {
      var ae = a.enabled ? 0 : 1
      var be = b.enabled ? 0 : 1
      if (ae !== be) return ae - be
      var an = String(a.name || a.id || "").toLowerCase()
      var bn = String(b.name || b.id || "").toLowerCase()
      return an < bn ? -1 : (an > bn ? 1 : 0)
    })
    return out
  }

  readonly property var tabOptions: [
    { value: "items", label: "Items · " + root.apps.length },
    { value: "repos", label: "Repos · " + root.reposData.length }
  ]
  readonly property int enabledCount: {
    var n = 0
    for (var i = 0; i < apps.length; i++) if (apps[i].enabled) n++
    return n
  }
  readonly property string headerSummary: root.loaded
    ? (apps.length + " items · " + enabledCount + " syncing")
    : "scanning…"

  function shorten(text) {
    var home = String((root.stateData && root.stateData.home) || "")
    if (home && text.indexOf(home) === 0) text = "~" + text.slice(home.length)
    if (text.length > 38) text = text.slice(0, 18) + "…" + text.slice(-17)
    return text
  }

  function run(args) {
    root.busy = true
    root.busyKind = String(args[0] || "")
    cmdProc.command = ["python3", root.scriptPath].concat(args)
    cmdProc.running = true
  }

  function refresh() {
    if (stateProc.running) { root.refreshOwed = true; return }
    stateProc.command = ["python3", root.scriptPath, "state"]
    stateProc.running = true
  }

  function refreshRepos() {
    if (reposProc.running) return
    root.reposBusy = true
    reposProc.command = ["python3", root.scriptPath, "repos"]
    reposProc.running = true
  }

  function requestSoftwarePlan() {
    if (planProc.running) return
    planProc.command = ["python3", root.scriptPath, "install-software", "--plan"]
    planProc.running = true
  }

  function focusActiveList() {
    Qt.callLater(function() {
      if (root.tab === "repos") { if (repoList) repoList.forceActiveFocus() }
      else if (list) list.forceActiveFocus()
    })
  }

  function setTab(value) {
    if (root.tab === value) return
    root.tab = value
    if (value === "repos") root.refreshRepos()
    root.focusActiveList()
  }

  function cycleTab(direction) {
    var order = ["items", "repos"]
    var i = order.indexOf(root.tab)
    var next = order[(i + (direction < 0 ? order.length - 1 : 1)) % order.length]
    root.setTab(next)
    Qt.callLater(function() {
      var view = root.tab === "repos" ? repoList : list
      if (view) view.positionViewAtBeginning()
    })
  }

  // Shared Page Up/Down, Home/End and arrow scrolling for whichever list is
  // showing; Tab walks the tabs.
  function handleListKeys(view, event) {
    var page = Math.max(1, view.height - Style.space(48))
    var maxY = Math.max(0, view.contentHeight - view.height)
    if (event.key === Qt.Key_PageDown) {
      view.contentY = Math.min(maxY, view.contentY + page); event.accepted = true
    } else if (event.key === Qt.Key_PageUp) {
      view.contentY = Math.max(0, view.contentY - page); event.accepted = true
    } else if (event.key === Qt.Key_Home) {
      view.positionViewAtBeginning(); event.accepted = true
    } else if (event.key === Qt.Key_End) {
      view.positionViewAtEnd(); event.accepted = true
    } else if (event.key === Qt.Key_Down) {
      view.contentY = Math.min(maxY, view.contentY + Style.space(40)); event.accepted = true
    } else if (event.key === Qt.Key_Up) {
      view.contentY = Math.max(0, view.contentY - Style.space(40)); event.accepted = true
    } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
      var back = event.key === Qt.Key_Backtab || (event.modifiers & Qt.ShiftModifier)
      root.cycleTab(back ? -1 : 1); event.accepted = true
    } else if (event.key === Qt.Key_Escape) {
      root.close(); event.accepted = true
    }
  }

  // Replace the state but keep the list where the reader left it — a target
  // change or a toggle must not throw them back to the top.
  function applyState(next) {
    var keepY = root.loaded ? list.contentY : 0
    var keepTab = root.tab
    root.stateData = next
    root.loaded = true
    root.seedBackends()
    Qt.callLater(function() {
      if (!list) return
      list.forceLayout()
      if (root.tab !== keepTab) { list.positionViewAtBeginning(); return }
      var maxY = Math.max(0, list.contentHeight - list.height)
      list.contentY = Math.max(0, Math.min(keepY, maxY))
    })
  }

  function toggleApp(app) {
    root.run(["set-enabled", String(app.id), app.enabled ? "false" : "true"])
  }

  function setTarget(app, value) {
    if (value !== app.target) root.run(["set-target", String(app.id), value])
  }

  function removeApp(app) {
    root.run(["remove", String(app.id)])
  }

  function addPath() {
    var p = String(addField.text || "").trim()
    if (p === "") return
    addField.text = ""
    root.run(["add", p])
  }

  function toggleWatch() {
    // Starts or stops the rsw watchers and the pass timer in one step.
    root.run(["watch", root.watchOn ? "--off" : "--on"])
  }

  function openStatus(kind) {
    root.statusDetail = kind
    statusPopup.open()
  }

  function closeStatus() {
    statusPopup.close()
    root.statusDetail = ""
  }

  function loadSnapshots() {
    if (snapshotsProc.running) return
    root.snapshotsBusy = true
    snapshotsProc.command = ["python3", root.scriptPath, "snapshot", "list", "--json"]
    snapshotsProc.running = true
  }
  function openSnapshots() {
    root.resumeArmed = false
    root.loadSnapshots()
    snapshotsPopup.open()
  }
  function askSnapshotName(from) {
    root.snapshotRenameFrom = from || ""
    root.snapshotDraft = from || ("snapshot-" + Qt.formatDateTime(new Date(), "yyyyMMdd-HHmm"))
    namePopup.open()
    namePopup.contentItem.forceActiveFocus()
  }
  function submitSnapshotName() {
    var name = String(root.snapshotDraft || "").trim()
    if (!name) return
    var from = root.snapshotRenameFrom
    root.snapshotRenameFrom = ""
    namePopup.close()
    snapshotsPopup.close()
    root.run(from ? ["snapshot", "rename", from, name] : ["snapshot", "create", name])
  }
  // A resume overwrites local files, so it takes two clicks: the first arms it
  // and says what will happen, the second does it.
  function armResume(name) {
    if (root.resumeArmed && root.resumeTarget === name) {
      root.resumeArmed = false
      root.resumeTarget = ""
      snapshotsPopup.close()
      root.run(["snapshot", "resume", name, "--yes"])
      return
    }
    root.resumeTarget = name
    root.resumeArmed = true
    resumeTimer.restart()
  }
  function rearmWatchers() {
    root.run(["watch", "--ensure"])
  }

  function resetPlugin() {
    if (!root.resetArmed) {
      root.resetArmed = true
      resetTimer.restart()
      return
    }
    root.resetArmed = false
    root.run(["reset"])
  }

  function seedBackends() {
    var git = root.gitInfo
    var drive = root.driveInfo
    root.gitDraft = String(git.remote || "")
    root.gdriveDraft = String(drive.remote || "")
    if (!gitField.activeFocus) gitField.text = root.gitDraft
    if (!gdriveField.activeFocus) gdriveField.text = root.gdriveDraft
  }

  Process {
    id: cmdProc
    onRunningChanged: if (!running) { root.busy = false; root.busyKind = ""; root.refresh() }
  }

  Process {
    id: stateProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var next = JSON.parse(text)
          if (next && typeof next === "object" && next.apps) root.applyState(next)
        } catch (e) {
          // Keep the last good state on a partial read.
        }
      }
    }
    onRunningChanged: if (!running && root.refreshOwed) { root.refreshOwed = false; root.refresh() }
  }

  Process {
    id: reposProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var list = JSON.parse(text)
          if (list && list.length !== undefined) root.reposData = list
        } catch (e) {
          // Leave the last inventory on screen.
        }
      }
    }
    onRunningChanged: if (!running) root.reposBusy = false
  }

  // Nothing is installed until the plan has been on screen: the manifest comes
  // from a synced repository, so it is data to confirm, not data to trust.
  Process {
    id: planProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var plan = JSON.parse(text)
          if (plan && plan.ready !== undefined) {
            root.softwarePlan = plan
            softwarePopup.open()
          }
        } catch (e) {
          root.softwarePlan = null
        }
      }
    }
  }

  Process {
    id: snapshotsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var points = JSON.parse(text)
          if (points && points.length !== undefined) root.snapshots = points
        } catch (e) {
          // Leave the last list on screen.
        }
      }
    }
    onRunningChanged: if (!running) root.snapshotsBusy = false
  }

  Timer {
    id: resumeTimer
    interval: 6000
    onTriggered: { root.resumeArmed = false; root.resumeTarget = "" }
  }

  Timer {
    id: resetTimer
    interval: 4000
    onTriggered: root.resetArmed = false
  }

  onOpenedChanged: {
    if (!opened) return
    root.refresh()
    if (root.tab === "repos") root.refreshRepos()
  }
  Component.onCompleted: {
    root.refresh()
    root.refreshRepos()
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: root.tab === "repos" ? repoList : list
    contentWidth: panel.fittedContentWidth(Style.space(520))
    contentHeight: panel.fittedContentHeight(Style.space(640))

    ColumnLayout {
      anchors.fill: parent
      spacing: Style.space(10)

      // ---- header ----------------------------------------------------------
      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(12)

        Text {
          text: "󰓦"
          color: root.contentForeground
          font.family: root.contentFontFamily
          font.pixelSize: Style.space(30)
          Layout.alignment: Qt.AlignVCenter
        }

        ColumnLayout {
          Layout.fillWidth: true
          Layout.minimumWidth: 0
          Layout.alignment: Qt.AlignVCenter
          spacing: Style.space(2)

          Label {
            text: "CONFIG SYNC"
            color: root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.title * 1.5
            font.bold: true
            Layout.fillWidth: true
          }

          Label {
            text: root.headerSummary
            textFormat: Text.PlainText
            color: Qt.darker(root.contentForeground, 1.4)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.bodySmall
            elide: Label.ElideRight
            Layout.fillWidth: true
          }
        }

        Button {
          iconText: "󰓦"
          text: "Sync now"
          tooltipText: "Send local changes and bring back the ones made elsewhere"
          bordered: true
          enabled: !root.busy
          foreground: root.contentForeground
          accent: Color.accent
          fontFamily: root.contentFontFamily
          fontSize: Style.font.caption
          horizontalPadding: Style.space(8)
          verticalPadding: Style.space(4)
          Layout.alignment: Qt.AlignVCenter
          onClicked: root.run(["sync"])
        }

        Button {
          id: overflowButton
          iconText: "⋯"
          tooltipText: "More actions"
          bordered: true
          foreground: root.contentForeground
          accent: Color.accent
          fontFamily: root.contentFontFamily
          horizontalPadding: Style.space(8)
          verticalPadding: Style.space(4)
          Layout.alignment: Qt.AlignVCenter
          onClicked: overflowMenu.opened ? overflowMenu.close() : overflowMenu.open()
        }

        Popup {
          id: overflowMenu
          parent: overflowButton
          x: overflowButton.width - width
          y: overflowButton.height + Style.space(6)
          padding: Style.space(6)
          modal: false
          closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

          background: BorderSurface {
            color: Color.popups.background
            borderSpec: Border.localOrSurfaceSpec("popups", "border", Color.popups.border, Color.popups.border, Math.max(1, Style.space(2)))
            radius: Style.cornerRadius
          }

          contentItem: Column {
            id: menuColumn
            spacing: Style.space(1)
            width: Style.space(232)

            Button {
              width: menuColumn.width
              height: Style.space(30)
              text: "Rescan apps"
              tooltipText: "Look for config folders and dotfiles again"
              enabled: !root.busy
              leftAlign: true
              fontSize: Style.font.bodySmall
              horizontalPadding: Style.space(8)
              verticalPadding: 0
              foreground: root.contentForeground
              accent: Color.accent
              fontFamily: root.contentFontFamily
              onClicked: { overflowMenu.close(); root.run(["scan"]) }
            }

            Button {
              width: menuColumn.width
              height: Style.space(30)
              text: "Backends…"
              tooltipText: "Where synced items are stored: a git repo and a Drive folder"
              enabled: !root.busy
              leftAlign: true
              fontSize: Style.font.bodySmall
              horizontalPadding: Style.space(8)
              verticalPadding: 0
              foreground: root.contentForeground
              accent: Color.accent
              fontFamily: root.contentFontFamily
              onClicked: { overflowMenu.close(); root.backendsOpen = true }
            }

            Rectangle {
              width: menuColumn.width
              height: 1
              color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.12)
            }

            Button {
              width: menuColumn.width
              height: Style.space(30)
              text: "Reinstall software"
              tooltipText: {
                var s = root.stateData.software || {}
                if (!s.captured) return "Run Sync first to record your plugins and packages"
                return "Show the plan first: " + s.plugins + " plugin(s), " + s.packages + " package(s)"
              }
              enabled: !root.busy && !!(root.stateData.software && root.stateData.software.captured)
              leftAlign: true
              fontSize: Style.font.bodySmall
              horizontalPadding: Style.space(8)
              verticalPadding: 0
              foreground: root.contentForeground
              accent: Color.accent
              fontFamily: root.contentFontFamily
              onClicked: { overflowMenu.close(); root.requestSoftwarePlan() }
            }

            Button {
              width: menuColumn.width
              height: Style.space(30)
              text: "Snapshot now…"
              tooltipText: "Keep this exact state as a named point you can go back to"
              enabled: !root.busy
              leftAlign: true
              fontSize: Style.font.bodySmall
              horizontalPadding: Style.space(8)
              verticalPadding: 0
              foreground: root.contentForeground
              accent: Color.accent
              fontFamily: root.contentFontFamily
              onClicked: { overflowMenu.close(); root.askSnapshotName("") }
            }

            Button {
              width: menuColumn.width
              height: Style.space(30)
              text: "Snapshots…"
              tooltipText: "The latest state and your named points: rename, or go back to one"
              enabled: !root.busy
              leftAlign: true
              fontSize: Style.font.bodySmall
              horizontalPadding: Style.space(8)
              verticalPadding: 0
              foreground: root.contentForeground
              accent: Color.accent
              fontFamily: root.contentFontFamily
              onClicked: { overflowMenu.close(); root.openSnapshots() }
            }

            Rectangle {
              width: menuColumn.width
              height: 1
              color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.12)
            }

            Button {
              width: menuColumn.width
              height: Style.space(30)
              text: "Re-arm watchers"
              tooltipText: "Start any rsw watcher that is missing, stop stale ones"
              enabled: !root.busy && root.watchOn
              leftAlign: true
              fontSize: Style.font.bodySmall
              horizontalPadding: Style.space(8)
              verticalPadding: 0
              foreground: root.contentForeground
              accent: Color.accent
              fontFamily: root.contentFontFamily
              onClicked: { overflowMenu.close(); root.rearmWatchers() }
            }

            Rectangle {
              width: menuColumn.width
              height: 1
              color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.12)
            }

            Button {
              width: menuColumn.width
              height: Style.space(30)
              text: root.resetArmed ? "Sure? Reset plugin" : "Reset plugin"
              tooltipText: "Reset toggles and settings to defaults"
              leftAlign: true
              fontSize: Style.font.bodySmall
              horizontalPadding: Style.space(8)
              verticalPadding: 0
              foreground: root.resetArmed ? Color.urgent : root.contentForeground
              accent: root.resetArmed ? Color.urgent : Color.accent
              fontFamily: root.contentFontFamily
              onClicked: {
                if (root.resetArmed) {
                  overflowMenu.close()
                  root.resetPlugin()
                } else {
                  root.resetPlugin()  // arms the confirm; the menu stays open
                }
              }
            }
          }
        }
      }

      // ---- backend fields, opened from a status chip or the ⋯ menu ---------
      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(10)
        visible: root.backendsOpen

        ColumnLayout {
          Layout.fillWidth: true
          Layout.minimumWidth: 0
          spacing: Style.space(2)

          Label {
            text: "GIT REPO"
            color: Qt.darker(root.contentForeground, 1.4)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }

          TextField {
            id: gitField
            Layout.fillWidth: true
            placeholderText: "git@github.com:you/dotfiles.git"
            foreground: root.contentForeground
            verticalPadding: Style.space(4)
            onEditingFinished: if (text !== root.gitDraft) root.run(["set-backend", "git", "remote", text])
          }
        }

        ColumnLayout {
          Layout.fillWidth: true
          Layout.minimumWidth: 0
          spacing: Style.space(2)

          Label {
            text: "DRIVE FOLDER"
            color: Qt.darker(root.contentForeground, 1.4)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }

          TextField {
            id: gdriveField
            Layout.fillWidth: true
            placeholderText: "~/Drive/omarchy-configsync"
            foreground: root.contentForeground
            verticalPadding: Style.space(4)
            onEditingFinished: if (text !== root.gdriveDraft) root.run(["set-backend", "gdrive", "remote", text])
          }
        }

        Button {
          text: "Done"
          bordered: true
          foreground: root.contentForeground
          accent: Color.accent
          fontFamily: root.contentFontFamily
          fontSize: Style.font.caption
          horizontalPadding: Style.space(8)
          verticalPadding: Style.space(3)
          Layout.alignment: Qt.AlignBottom
          onClicked: root.backendsOpen = false
        }
      }

      // ---- tabs and the add field ------------------------------------------
      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(8)

        ButtonGroup {
          Layout.alignment: Qt.AlignVCenter
          focusable: false
          spacing: Style.space(6)
          fontSize: Style.font.bodySmall
          options: root.tabOptions
          value: root.tab
          foreground: root.contentForeground
          accent: Color.accent
          fontFamily: root.contentFontFamily
          onChanged: function(value) { root.setTab(value) }
        }

        Item { Layout.fillWidth: true; Layout.preferredHeight: 1 }

        Button {
          visible: root.tab === "repos"
          text: root.reposBusy ? "Scanning…" : "Refresh"
          tooltipText: "Rescan the git repositories on this machine"
          bordered: true
          enabled: !root.reposBusy
          foreground: root.contentForeground
          accent: Color.accent
          fontFamily: root.contentFontFamily
          fontSize: Style.font.caption
          horizontalPadding: Style.space(8)
          verticalPadding: Style.space(3)
          Layout.alignment: Qt.AlignVCenter
          onClicked: root.refreshRepos()
        }
      }

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(8)
        visible: root.tab !== "repos"

        TextField {
          id: addField
          Layout.fillWidth: true
          placeholderText: "Add a folder or file of your own  (e.g. ~/Documents/notes)"
          foreground: root.contentForeground
          verticalPadding: Style.space(4)
          onAccepted: root.addPath()
        }

        Button {
          text: "Add"
          bordered: true
          foreground: root.contentForeground
          accent: Color.accent
          fontFamily: root.contentFontFamily
          fontSize: Style.font.caption
          horizontalPadding: Style.space(10)
          verticalPadding: Style.space(4)
          onClicked: root.addPath()
        }
      }

      // ---- item list -------------------------------------------------------
      Item {
        Layout.fillWidth: true
        Layout.fillHeight: true
        Layout.minimumHeight: Style.space(160)

        ListView {
          id: list
          anchors.fill: parent
          visible: root.tab !== "repos"
          clip: true
          model: root.shown
          boundsBehavior: Flickable.StopAtBounds
          reuseItems: true
          focus: root.tab !== "repos"
          keyNavigationEnabled: false

          delegate: Cells.AppCell {
            width: list.width
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
            onToggleRequested: function(app) { root.toggleApp(app) }
            onTargetRequested: function(app, value) { root.setTarget(app, value) }
            onRemoveRequested: function(app) { root.removeApp(app) }
          }

          Keys.priority: Keys.BeforeItem
          Keys.onPressed: function(event) { root.handleListKeys(list, event) }
        }

        ListView {
          id: repoList
          anchors.fill: parent
          visible: root.tab === "repos"
          clip: true
          model: root.reposData
          boundsBehavior: Flickable.StopAtBounds
          reuseItems: true
          focus: root.tab === "repos"
          keyNavigationEnabled: false

          delegate: Cells.RepoCell {
            width: repoList.width
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
          }

          Keys.priority: Keys.BeforeItem
          Keys.onPressed: function(event) { root.handleListKeys(repoList, event) }
        }
      }

      // ---- footer: status chips -------------------------------------------
      ColumnLayout {
        id: footer
        Layout.fillWidth: true
        spacing: Style.space(6)

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(6)

          Cells.StatusChip {
            id: gitChip
            icon: "\uf126"
            label: root.gitChipLabel
            tone: root.gitChipTone
            tooltipText: "Git — " + root.gitChipLabel + ". Click for details and actions."
            foreground: root.contentForeground
            accent: Color.accent
            fontFamily: root.contentFontFamily
            onClicked: root.openStatus("git")
          }

          Cells.StatusChip {
            id: driveChip
            icon: "\uf0c2"
            label: root.driveChipLabel
            tone: root.driveChipTone
            tooltipText: "Google Drive — " + root.driveChipLabel + ". Click for details and actions."
            foreground: root.contentForeground
            accent: Color.accent
            fontFamily: root.contentFontFamily
            onClicked: root.openStatus("drive")
          }

          Cells.StatusChip {
            id: watchChip
            icon: "\uf06e"
            label: root.watchChipLabel
            tone: root.watchChipTone
            tooltipText: "Watchers — " + root.watchChipLabel + ". Click to turn watching on or off."
            foreground: root.contentForeground
            accent: Color.accent
            fontFamily: root.contentFontFamily
            onClicked: root.openStatus("watch")
          }

          Cells.StatusChip {
            id: softwareChip
            icon: "󰏗"
            label: root.softwareChipLabel
            tone: root.softwareChipTone
            tooltipText: "Plugins and packages recorded in the synced manifest. Click to reinstall."
            foreground: root.contentForeground
            accent: Color.accent
            fontFamily: root.contentFontFamily
            onClicked: root.openStatus("software")
          }

          Cells.StatusChip {
            id: trashChip
            visible: root.trashCount > 0
            icon: "\uf1f8"
            label: root.trashChipLabel
            tone: "warn"
            tooltipText: "Files a sync removed. Click to restore them."
            foreground: root.contentForeground
            accent: Color.accent
            fontFamily: root.contentFontFamily
            onClicked: root.openStatus("trash")
          }

          Item { Layout.fillWidth: true; Layout.preferredHeight: 1 }
        }

        Label {
          Layout.fillWidth: true
          Layout.minimumWidth: 0
          text: root.lastLine
          textFormat: Text.PlainText
          elide: Label.ElideRight
          color: root.lastInfo.ok === false ? Color.urgent : Qt.darker(root.contentForeground, 1.4)
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.openStatus("last")
          }
        }

        Popup {
          id: statusPopup
          parent: footer
          x: 0
          y: -height - Style.space(6)
          width: footer.width
          padding: Style.space(10)
          modal: false
          closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
          onClosed: root.statusDetail = ""

          background: BorderSurface {
            color: Color.popups.background
            borderSpec: Border.localOrSurfaceSpec("popups", "border", Color.popups.border, Color.popups.border, Math.max(1, Style.space(2)))
            radius: Style.cornerRadius
          }

          contentItem: ColumnLayout {
            spacing: Style.space(6)
            implicitWidth: footer.width - Style.space(20)

            Label {
              text: root.statusTitle
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.subtitle
              font.bold: true
              Layout.fillWidth: true
            }

            Label {
              Layout.fillWidth: true
              Layout.minimumWidth: 0
              text: root.statusBody
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              color: Qt.darker(root.contentForeground, 1.3)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
            }

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(6)

              Button {
                visible: root.statusDetail === "git" || root.statusDetail === "drive"
                text: "Sync now"
                bordered: true
                enabled: !root.busy
                foreground: root.contentForeground
                accent: Color.accent
                fontFamily: root.contentFontFamily
                fontSize: Style.font.caption
                horizontalPadding: Style.space(8)
                verticalPadding: Style.space(3)
                onClicked: { root.closeStatus(); root.run(["sync"]) }
              }

              Button {
                visible: root.statusDetail === "git" || root.statusDetail === "drive"
                text: "Download"
                tooltipText: "Pull the git backend into the local store, without writing to home"
                bordered: true
                enabled: !root.busy
                foreground: root.contentForeground
                accent: Color.accent
                fontFamily: root.contentFontFamily
                fontSize: Style.font.caption
                horizontalPadding: Style.space(8)
                verticalPadding: Style.space(3)
                onClicked: { root.closeStatus(); root.run(["download"]) }
              }

              Button {
                visible: root.statusDetail === "git" || root.statusDetail === "drive"
                text: "Deploy"
                tooltipText: "Write the backend's copy over the local files"
                bordered: true
                enabled: !root.busy
                foreground: root.contentForeground
                accent: Color.accent
                fontFamily: root.contentFontFamily
                fontSize: Style.font.caption
                horizontalPadding: Style.space(8)
                verticalPadding: Style.space(3)
                onClicked: { root.closeStatus(); root.run(["deploy"]) }
              }

              Button {
                visible: root.statusDetail === "git" || root.statusDetail === "drive"
                text: "Edit backend"
                bordered: true
                foreground: root.contentForeground
                accent: Color.accent
                fontFamily: root.contentFontFamily
                fontSize: Style.font.caption
                horizontalPadding: Style.space(8)
                verticalPadding: Style.space(3)
                onClicked: { root.closeStatus(); root.backendsOpen = true }
              }

              Button {
                visible: root.statusDetail === "watch"
                text: root.watchOn ? "Stop watching" : "Start watching"
                bordered: true
                enabled: !root.busy
                foreground: root.contentForeground
                accent: Color.accent
                fontFamily: root.contentFontFamily
                fontSize: Style.font.caption
                horizontalPadding: Style.space(8)
                verticalPadding: Style.space(3)
                onClicked: { root.closeStatus(); root.toggleWatch() }
              }

              Button {
                visible: root.statusDetail === "watch"
                text: "Re-arm"
                tooltipText: "Start any watcher that is missing, stop stale ones"
                bordered: true
                enabled: !root.busy && root.watchOn
                foreground: root.contentForeground
                accent: Color.accent
                fontFamily: root.contentFontFamily
                fontSize: Style.font.caption
                horizontalPadding: Style.space(8)
                verticalPadding: Style.space(3)
                onClicked: { root.closeStatus(); root.rearmWatchers() }
              }

              Button {
                visible: root.statusDetail === "software"
                text: "Show plan & reinstall"
                bordered: true
                enabled: !root.busy && !!root.softwareInfo.captured
                foreground: root.contentForeground
                accent: Color.accent
                fontFamily: root.contentFontFamily
                fontSize: Style.font.caption
                horizontalPadding: Style.space(8)
                verticalPadding: Style.space(3)
                onClicked: { root.closeStatus(); root.requestSoftwarePlan() }
              }

              Button {
                visible: root.statusDetail === "trash"
                text: "Restore latest"
                bordered: true
                enabled: !root.busy
                foreground: root.contentForeground
                accent: Color.accent
                fontFamily: root.contentFontFamily
                fontSize: Style.font.caption
                horizontalPadding: Style.space(8)
                verticalPadding: Style.space(3)
                onClicked: { root.closeStatus(); root.run(["trash", "restore"]) }
              }

              Button {
                visible: root.statusDetail === "trash"
                text: "Restore all"
                bordered: true
                enabled: !root.busy
                foreground: root.contentForeground
                accent: Color.accent
                fontFamily: root.contentFontFamily
                fontSize: Style.font.caption
                horizontalPadding: Style.space(8)
                verticalPadding: Style.space(3)
                onClicked: { root.closeStatus(); root.run(["trash", "restore-all"]) }
              }

              Button {
                visible: root.statusDetail === "last"
                text: "Sync now"
                bordered: true
                enabled: !root.busy
                foreground: root.contentForeground
                accent: Color.accent
                fontFamily: root.contentFontFamily
                fontSize: Style.font.caption
                horizontalPadding: Style.space(8)
                verticalPadding: Style.space(3)
                onClicked: { root.closeStatus(); root.run(["sync"]) }
              }

              Item { Layout.fillWidth: true; Layout.preferredHeight: 1 }
            }
          }
        }
      }
    }
  }

  // ---- software plan confirmation ----------------------------------------
  Popup {
    id: snapshotsPopup
    parent: overflowButton
    x: Math.max(0, overflowButton.width - width)
    y: overflowButton.height + Style.space(4)
    padding: Style.space(8)
    modal: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    background: BorderSurface {
      color: Color.popups.background
      borderSpec: Border.localOrSurfaceSpec("popups", "border", Color.popups.border, Color.popups.border, Math.max(1, Style.space(2)))
      radius: Style.cornerRadius
    }
    contentItem: ColumnLayout {
      spacing: Style.space(6)
      implicitWidth: Style.space(360)

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(6)

        Label {
          text: "Snapshots"
          color: root.contentForeground
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.body
          font.bold: true
          Layout.fillWidth: true
        }

        Button {
          text: "New…"
          tooltipText: "Keep the state this machine holds now, under a name you choose"
          bordered: true
          foreground: root.contentForeground
          accent: Color.accent
          fontFamily: root.contentFontFamily
          fontSize: Style.font.caption
          horizontalPadding: Style.space(6)
          verticalPadding: Style.space(3)
          onClicked: { snapshotsPopup.close(); root.askSnapshotName("") }
        }
      }

      Label {
        text: root.snapshotsBusy
              ? "reading…"
              : (root.snapshots.length
                 ? "Going back writes the chosen point over this machine's files. What is replaced moves to the trash, and the other machines follow on their next sync."
                 : "No snapshots yet — “New…” keeps this state under a name.")
        textFormat: Text.PlainText
        color: Qt.darker(root.contentForeground, 1.3)
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
        Layout.fillWidth: true
        Layout.maximumWidth: Style.space(330)
      }

      Repeater {
        model: root.snapshots

        delegate: RowLayout {
          required property var modelData
          Layout.fillWidth: true
          spacing: Style.space(6)

          ColumnLayout {
            Layout.fillWidth: true
            Layout.minimumWidth: 0
            spacing: 0

            Label {
              text: modelData.label
              textFormat: Text.PlainText
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: !!modelData.latest
              elide: Label.ElideRight
              Layout.fillWidth: true
            }

            Label {
              text: (modelData.latest ? "the rolling commit · " : "")
                    + String(modelData.when).replace("T", " ").slice(0, 16)
              textFormat: Text.PlainText
              color: Qt.darker(root.contentForeground, 1.5)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              elide: Label.ElideRight
              Layout.fillWidth: true
            }
          }

          Button {
            visible: !modelData.latest
            text: "Rename"
            tooltipText: "Give this snapshot another name"
            bordered: true
            foreground: root.contentForeground
            accent: Color.accent
            fontFamily: root.contentFontFamily
            fontSize: Style.font.caption
            horizontalPadding: Style.space(6)
            verticalPadding: Style.space(3)
            onClicked: { snapshotsPopup.close(); root.askSnapshotName(modelData.name) }
          }

          Button {
            text: (root.resumeArmed && root.resumeTarget === modelData.name) ? "Sure?" : "Go back"
            tooltipText: "Write this point over this machine's files"
            bordered: true
            foreground: (root.resumeArmed && root.resumeTarget === modelData.name) ? Color.urgent : root.contentForeground
            accent: (root.resumeArmed && root.resumeTarget === modelData.name) ? Color.urgent : Color.accent
            fontFamily: root.contentFontFamily
            fontSize: Style.font.caption
            horizontalPadding: Style.space(6)
            verticalPadding: Style.space(3)
            onClicked: root.armResume(modelData.name)
          }
        }
      }
    }
  }

  Popup {
    id: namePopup
    parent: overflowButton
    x: Math.max(0, overflowButton.width - width)
    y: overflowButton.height + Style.space(4)
    padding: Style.space(8)
    modal: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    background: BorderSurface {
      color: Color.popups.background
      borderSpec: Border.localOrSurfaceSpec("popups", "border", Color.popups.border, Color.popups.border, Math.max(1, Style.space(2)))
      radius: Style.cornerRadius
    }
    contentItem: ColumnLayout {
      spacing: Style.space(6)
      implicitWidth: Style.space(320)

      Label {
        text: root.snapshotRenameFrom ? "Rename snapshot" : "Name this snapshot"
        color: root.contentForeground
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.body
        font.bold: true
      }

      TextField {
        Layout.fillWidth: true
        text: root.snapshotDraft
        placeholderText: "before-theme-change"
        foreground: root.contentForeground
        verticalPadding: Style.space(4)
        onTextEdited: root.snapshotDraft = text
        onAccepted: root.submitSnapshotName()
      }

      Label {
        text: "This becomes the git tag, so letters, digits, . - and _ only, with no spaces."
        textFormat: Text.PlainText
        color: Qt.darker(root.contentForeground, 1.3)
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
        Layout.fillWidth: true
        Layout.maximumWidth: Style.space(300)
      }

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(6)

        Button {
          text: "Cancel"
          bordered: true
          foreground: root.contentForeground
          accent: Color.accent
          fontFamily: root.contentFontFamily
          fontSize: Style.font.caption
          onClicked: namePopup.close()
        }

        Button {
          text: root.snapshotRenameFrom ? "Rename" : "Keep"
          bordered: true
          foreground: root.contentForeground
          accent: Color.accent
          fontFamily: root.contentFontFamily
          fontSize: Style.font.caption
          Layout.fillWidth: true
          onClicked: root.submitSnapshotName()
        }
      }
    }
  }

  Popup {
    id: softwarePopup
    parent: overflowButton
    x: Math.max(0, overflowButton.width - width)
    y: overflowButton.height + Style.space(4)
    padding: Style.space(8)
    modal: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

    background: BorderSurface {
      color: Color.popups.background
      borderSpec: Border.localOrSurfaceSpec("popups", "border", Color.popups.border, Color.popups.border, Math.max(1, Style.space(2)))
      radius: Style.cornerRadius
    }

    contentItem: ColumnLayout {
      spacing: Style.space(6)
      implicitWidth: Style.space(340)

      Label {
        text: "Reinstall software"
        color: root.contentForeground
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.body
        font.bold: true
      }

      Label {
        Layout.fillWidth: true
        Layout.minimumWidth: 0
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        text: {
          var p = root.softwarePlan || ({})
          if (!p.ready) return "No software manifest yet — run Sync on a machine that already has your setup."
          return "From the manifest captured on " + String(p.host || "another machine") + " on "
            + String(p.capturedAt || "?") + ". Only what is missing gets installed."
        }
        color: Qt.darker(root.contentForeground, 1.4)
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.caption
      }

      Label {
        Layout.fillWidth: true
        Layout.minimumWidth: 0
        visible: !!(root.softwarePlan && root.softwarePlan.ready)
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        maximumLineCount: 6
        elide: Text.ElideRight
        text: {
          var p = root.softwarePlan || ({})
          var lines = []
          var plugins = p.plugins || []
          var packages = p.packages || []
          for (var i = 0; i < plugins.length && i < 4; i++) lines.push("plugin  " + plugins[i].source)
          for (var j = 0; j < packages.length && j < 4; j++) lines.push("package " + packages[j].name)
          if (lines.length === 0) lines.push("Nothing is missing.")
          var extra = (plugins.length + packages.length) - lines.length
          if (extra > 0) lines.push("… and " + extra + " more")
          return lines.join("\n")
        }
        color: root.contentForeground
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.caption
      }

      Label {
        Layout.fillWidth: true
        Layout.minimumWidth: 0
        visible: {
          var r = (root.softwarePlan && root.softwarePlan.rejected) || null
          return !!(r && ((r.packages || []).length + (r.plugins || []).length) > 0)
        }
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        text: {
          var r = (root.softwarePlan && root.softwarePlan.rejected) || ({})
          var n = (r.packages || []).length + (r.plugins || []).length
          return "⚠  " + n + " entr(ies) in the manifest are not valid names and will be ignored."
        }
        color: Color.urgent
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.caption
      }

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(6)

        Item { Layout.fillWidth: true; Layout.preferredHeight: 1 }

        Button {
          text: "Cancel"
          bordered: true
          foreground: root.contentForeground
          accent: Color.accent
          fontFamily: root.contentFontFamily
          fontSize: Style.font.caption
          horizontalPadding: Style.space(10)
          verticalPadding: Style.space(4)
          onClicked: softwarePopup.close()
        }

        Button {
          text: "Install"
          enabled: !root.busy && !!(root.softwarePlan && root.softwarePlan.ready)
          foreground: root.contentForeground
          accent: Color.accent
          fontFamily: root.contentFontFamily
          fontSize: Style.font.caption
          horizontalPadding: Style.space(10)
          verticalPadding: Style.space(4)
          onClicked: {
            softwarePopup.close()
            root.run(["install-software", "--yes"])
          }
        }
      }
    }
  }
}
