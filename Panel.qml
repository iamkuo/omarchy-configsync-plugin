pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "panel" as Cells

// Config Sync popup: apps and folders split into two subtabs. Each card carries
// the on/off switch (does it sync?) and a Git/Drive picker (where?), so turning
// sync off is the switch, never a cycling button. Actions pull from the
// backends (Download), write them to the system (Deploy), run the two-way sync,
// rescan, and reset the plugin. The Folders tab has a field to add your own
// paths. Every interaction is a CLI call followed by a re-read, and a re-read
// keeps the list where it was.
Panel {
  id: root
  moduleName: "io.github.ryankuo.configsync"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null

  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string scriptPath: Qt.resolvedUrl("bin/configsync").toString().replace("file://", "")

  property var stateData: ({ apps: [], git: {}, gdrive: {}, auto: {}, lastSync: {} })
  property var reposData: []
  property bool reposBusy: false
  property bool loaded: false
  property bool busy: false
  property bool refreshOwed: false
  property bool resetArmed: false
  property string tab: "apps"
  property int autoInterval: 30

  // Drafts for the two backend fields, so a refresh does not clobber typing.
  property string gitDraft: ""
  property string gdriveDraft: ""

  readonly property var apps: root.stateData.apps || []
  readonly property var appEntries: {
    var out = []
    for (var i = 0; i < apps.length; i++) {
      var k = apps[i].kind
      if (k === "config" || k === "dotfile" || k === "omarchy") out.push(apps[i])
    }
    return out
  }
  readonly property var folderEntries: {
    var out = []
    for (var i = 0; i < apps.length; i++) {
      var k = apps[i].kind
      if (k === "personal" || k === "custom") out.push(apps[i])
    }
    return out
  }
  readonly property var shown: root.sortItems(root.tab === "folders" ? folderEntries : appEntries)
  // Enabled items float to the top, then alphabetical — so what is syncing is
  // always the first thing in view.
  function sortItems(items) {
    var out = items.slice()
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
    { value: "apps", label: "Apps · " + appEntries.length },
    { value: "folders", label: "Folders · " + folderEntries.length },
    { value: "repos", label: "Repos · " + root.reposData.length }
  ]
  readonly property int enabledCount: {
    var n = 0
    for (var i = 0; i < apps.length; i++) if (apps[i].enabled) n++
    return n
  }
  readonly property bool autoOn: !!(root.stateData.auto && root.stateData.auto.enabled)
  readonly property string headerSummary: root.loaded
    ? (apps.length + " items · " + enabledCount + " syncing")
    : "scanning…"
  readonly property string statusLine: {
    var s = root.stateData.lastSync || {}
    var prefix = s.ok === false ? "⚠  " : ""
    return prefix + String(s.message || "never synced") + (s.at ? " · " + s.at : "")
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
    var order = ["apps", "folders", "repos"]
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
    var git = root.stateData.git || {}
    var drive = root.stateData.gdrive || {}
    var auto = root.stateData.auto || {}
    root.gitDraft = String(git.remote || "")
    root.gdriveDraft = String(drive.remote || "")
    root.autoInterval = Math.round(Number(auto.intervalMinutes) || 30)
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
    contentWidth: panel.fittedContentWidth(Style.space(540))
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
          iconText: "󰑐"
          tooltipText: "Rescan installed apps"
          bordered: true
          enabled: !root.busy
          foreground: root.contentForeground
          accent: Color.accent
          fontFamily: root.contentFontFamily
          horizontalPadding: Style.space(8)
          verticalPadding: Style.space(4)
          Layout.alignment: Qt.AlignVCenter
          onClicked: root.run(["scan"])
        }

        Button {
          iconText: "󰓦"
          text: "Sync now"
          tooltipText: "Capture, push and apply the enabled items"
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
            implicitWidth: Style.space(220)

            Button {
              text: "Download from backends"
              tooltipText: "Pull the backends' files into the local store"
              enabled: !root.busy
              leftAlign: true
              Layout.fillWidth: true
              fontSize: Style.font.bodySmall
              horizontalPadding: Style.space(8)
              verticalPadding: Style.space(5)
              foreground: root.contentForeground
              accent: Color.accent
              fontFamily: root.contentFontFamily
              onClicked: { overflowMenu.close(); root.run(["download"]) }
            }

            Button {
              text: "Deploy to system"
              tooltipText: "Write the local store into your home directory"
              enabled: !root.busy
              leftAlign: true
              Layout.fillWidth: true
              fontSize: Style.font.bodySmall
              horizontalPadding: Style.space(8)
              verticalPadding: Style.space(5)
              foreground: root.contentForeground
              accent: Color.accent
              fontFamily: root.contentFontFamily
              onClicked: { overflowMenu.close(); root.run(["deploy"]) }
            }

            Button {
              text: "Reinstall software"
              tooltipText: {
                var s = root.stateData.software || {}
                if (!s.captured) return "Run Sync first to capture your plugins and packages"
                return s.plugins + " plugin(s), " + s.packages + " package(s)"
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
              onClicked: { overflowMenu.close(); root.run(["install-software"]) }
            }

            Rectangle {
              Layout.fillWidth: true
              Layout.preferredHeight: 1
              color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.12)
            }

            Button {
              text: "Rescan apps"
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

      // ---- backends --------------------------------------------------------
      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(10)

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
      }

      // ---- subtabs ---------------------------------------------------------
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

      // ---- add your own path (Folders tab) ---------------------------------
      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(8)
        visible: root.tab === "folders"

        TextField {
          id: addField
          Layout.fillWidth: true
          placeholderText: "Add a folder or file to sync  (e.g. ~/Documents/notes)"
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

        // The last-sync message gets the full width and wraps, so it is never
        // cut off beside the Auto switch.
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
            text: "Auto sync"
            color: Qt.darker(root.contentForeground, 1.4)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.bodySmall
          }

          ToggleSwitch {
            id: autoSwitch
            Layout.alignment: Qt.AlignVCenter
            checked: root.autoOn
            foreground: root.contentForeground
            accent: Color.accent
            onToggled: root.run(["set-backend", "auto", "enabled", autoSwitch.checked ? "false" : "true"])
          }

          Label {
            visible: root.autoOn
            Layout.leftMargin: Style.space(8)
            text: "every"
            color: Qt.darker(root.contentForeground, 1.4)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.bodySmall
          }

          PanelSlider {
            visible: root.autoOn
            Layout.fillWidth: true
            Layout.minimumWidth: Style.space(80)
            Layout.preferredHeight: Style.spacing.controlHeight
            Layout.alignment: Qt.AlignVCenter
            bar: root.bar
            minimum: 5
            maximum: 180
            step: 5
            integer: true
            tickCount: 0
            value: root.autoInterval
            onReleased: function(value) {
              root.autoInterval = Math.round(value)
              root.run(["set-backend", "auto", "interval", String(root.autoInterval)])
            }
          }

          Label {
            visible: root.autoOn
            Layout.preferredWidth: Style.space(56)
            text: root.autoInterval + " min"
            color: root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Item {
            visible: !root.autoOn
            Layout.fillWidth: true
            Layout.preferredHeight: 1
          }
        }
      }
    }
  }
}
