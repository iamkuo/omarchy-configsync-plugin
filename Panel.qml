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

  readonly property string statusLine: {
    var s = root.stateData.lastSync || {}
    var prefix = s.ok === false ? "⚠  " : ""
    var extra = (s.conflicts || 0) > 0 ? " · " + s.conflicts + " conflict copy(ies) kept" : ""
    return prefix + String(s.message || "never synced") + extra + (s.at ? " · " + s.at : "")
  }

  readonly property string watchLine: {
    if (!root.watchOn) return "Watching off — sync runs when you press Sync now"
    if (!root.watchInfo.running) return "⚠  Watching is on but the watcher is not running"
    var svc = root.watchInfo.service || ({})
    var how = root.watchInfo.mode === "inotify" ? "inotify" : "polling"
    var where = svc.active ? "systemd service" : "inside the shell"
    return "Watching " + (root.watchInfo.trees || 0) + " path(s) · " + how + " · " + where
  }

  readonly property string backendsSummary: {
    var git = root.gitInfo.configured ? root.shorten(String(root.gitInfo.remote || "")) : "not set"
    var drive = "not set"
    if (root.driveInfo.configured) {
      drive = root.shorten(String(root.driveInfo.remote || ""))
      if (!root.driveInfo.available) drive += " (not found)"
    }
    return "Git " + git + "   ·   Drive " + drive
  }

  function shorten(text) {
    var home = String((root.stateData && root.stateData.home) || "")
    if (home && text.indexOf(home) === 0) text = "~" + text.slice(home.length)
    if (text.length > 38) text = text.slice(0, 18) + "…" + text.slice(-17)
    return text
  }

  function run(args) {
    root.busy = true
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
    root.run(["set-backend", "watch", "enabled", root.watchOn ? "false" : "true"])
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
    onRunningChanged: if (!running) { root.busy = false; root.refresh() }
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
          y: overflowButton.height + Style.space(4)
          padding: Style.space(4)
          modal: false
          closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

          background: BorderSurface {
            color: Color.popups.background
            borderSpec: Border.localOrSurfaceSpec("popups", "border", Color.popups.border, Color.popups.border, Math.max(1, Style.space(2)))
            radius: Style.cornerRadius
          }

          contentItem: ColumnLayout {
            spacing: Style.space(2)
            implicitWidth: Style.space(230)

            Button {
              text: "Rescan apps"
              tooltipText: "Look for config folders and dotfiles again"
              enabled: !root.busy
              leftAlign: true
              Layout.fillWidth: true
              fontSize: Style.font.bodySmall
              horizontalPadding: Style.space(8)
              verticalPadding: Style.space(5)
              foreground: root.contentForeground
              accent: Color.accent
              fontFamily: root.contentFontFamily
              onClicked: { overflowMenu.close(); root.run(["scan"]) }
            }

            Button {
              text: "Reinstall software"
              tooltipText: {
                var s = root.stateData.software || {}
                if (!s.captured) return "Run Sync first to record your plugins and packages"
                return "Show the plan first: " + s.plugins + " plugin(s), " + s.packages + " package(s)"
              }
              enabled: !root.busy && !!(root.stateData.software && root.stateData.software.captured)
              leftAlign: true
              Layout.fillWidth: true
              fontSize: Style.font.bodySmall
              horizontalPadding: Style.space(8)
              verticalPadding: Style.space(5)
              foreground: root.contentForeground
              accent: Color.accent
              fontFamily: root.contentFontFamily
              onClicked: { overflowMenu.close(); root.requestSoftwarePlan() }
            }

            Rectangle {
              Layout.fillWidth: true
              Layout.preferredHeight: 1
              color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.12)
            }

            Button {
              text: root.resetArmed ? "Sure? Reset plugin" : "Reset plugin"
              tooltipText: "Reset toggles and settings to defaults"
              leftAlign: true
              Layout.fillWidth: true
              fontSize: Style.font.bodySmall
              horizontalPadding: Style.space(8)
              verticalPadding: Style.space(5)
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

      // ---- backends, collapsed once they are set ---------------------------
      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(8)
        visible: !root.backendsOpen

        Label {
          Layout.fillWidth: true
          Layout.minimumWidth: 0
          text: root.backendsSummary
          textFormat: Text.PlainText
          elide: Label.ElideRight
          color: (root.gitInfo.configured || root.driveInfo.configured)
            ? Qt.darker(root.contentForeground, 1.4) : Color.urgent
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
        }

        Button {
          text: "Backends"
          tooltipText: "Where synced items are stored"
          bordered: true
          foreground: root.contentForeground
          accent: Color.accent
          fontFamily: root.contentFontFamily
          fontSize: Style.font.caption
          horizontalPadding: Style.space(8)
          verticalPadding: Style.space(3)
          Layout.alignment: Qt.AlignVCenter
          onClicked: root.backendsOpen = true
        }
      }

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

      // ---- footer ----------------------------------------------------------
      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(6)

        Label {
          Layout.fillWidth: true
          Layout.minimumWidth: 0
          text: root.statusLine
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          maximumLineCount: 2
          elide: Text.ElideRight
          color: (root.stateData.lastSync && root.stateData.lastSync.ok === false)
            ? Color.accent : Qt.darker(root.contentForeground, 1.4)
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.bodySmall
        }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)

          Label {
            text: "Watch for changes"
            color: Qt.darker(root.contentForeground, 1.4)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.bodySmall
          }

          ToggleSwitch {
            id: watchSwitch
            Layout.alignment: Qt.AlignVCenter
            checked: root.watchOn
            foreground: root.contentForeground
            accent: Color.accent
            onToggled: root.toggleWatch()
          }

          Label {
            Layout.fillWidth: true
            Layout.minimumWidth: 0
            text: root.watchLine
            textFormat: Text.PlainText
            elide: Label.ElideRight
            color: (root.watchOn && !root.watchInfo.running)
              ? Color.urgent : Qt.darker(root.contentForeground, 1.4)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }

        Label {
          Layout.fillWidth: true
          visible: (root.stateData.trash || 0) > 0
          text: (root.stateData.trash || 0) + " file(s) in the trash — `configsync trash` restores them"
          textFormat: Text.PlainText
          elide: Label.ElideRight
          color: Qt.darker(root.contentForeground, 1.6)
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }

  // ---- software plan confirmation ----------------------------------------
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
