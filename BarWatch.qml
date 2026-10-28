import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Omarchy Browser Plugin Manager bar widget (watcher mode).
//
// The icon lights up while a browser tab is open on an installable plugin
// page: the extension renews a beacon record with the native host every few
// seconds, the host writes it to browser-watch.json in the state dir, and
// this widget reads that file. A beacon that stops (tab closed, browser
// killed) goes stale and the icon dims.
//
// Left click opens a dropdown with the watched plugin's header title (the
// same identity line the wizard dialogs show) and buttons to manage it:
// Install, Uninstall, Update, and moving its bar icon (Left/Center/Right).
// Install, Uninstall, and Update summon the wizard overlay: the beacon
// record is a display hint only, and every action is re-validated and
// confirmed there, exactly like the browser buttons. Moving the icon is a
// plain layout change, so it runs the official `omarchy bar move` directly.
Panel {
  id: root
  moduleName: "bramvanoploo.omarchy-browser-plugin-manager"
  ipcTarget: "bramvanoploo.omarchy-browser-plugin-manager"

  readonly property string managerId: "bramvanoploo.omarchy-browser-plugin-manager"
  readonly property string marketplaceUrl: "https://plugins.omarchy.org/"
  // Must match the beacon interval/staleness in the host and extension:
  // the record is renewed every 5s, so 12s without a renewal means gone.
  readonly property int beaconStaleMs: 12000

  readonly property string stateDir: {
    var base = Quickshell.env("XDG_STATE_HOME")
    if (!base) base = (Quickshell.env("HOME") || "/tmp") + "/.local/state"
    return base + "/omarchy/" + managerId
  }
  readonly property string watchPath: stateDir + "/browser-watch.json"

  // Parsed beacon record ({id, repo, name, pid, ts}) or null.
  property var watchState: null
  property real nowMs: 0
  readonly property bool beaconLive: watchState !== null && nowMs > 0
    && (nowMs - Number(watchState.ts) * 1000) < beaconStaleMs

  // Live local state for the watched plugin, refreshed while the popup is
  // open (the wizard can change it while the dropdown sits there).
  property bool statusChecked: false
  property bool pluginInstalled: false
  property bool pluginEnabled: false
  property string statusForId: ""
  property string moveSection: ""
  property string moveOutput: ""

  function applyWatch(raw) {
    var s = String(raw || "").trim()
    var obj = null
    if (s) {
      try { obj = JSON.parse(s) } catch (e) { obj = null }
    }
    // Shape-checked: the file is host-written, but a corrupt/foreign file
    // must never render as a plugin identity.
    if (obj && typeof obj === "object"
        && /^[a-z0-9][a-z0-9.-]{0,127}$/.test(String(obj.id || ""))
        && String(obj.id || "").indexOf("..") === -1
        && /^https:\/\/github\.com\/[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+(\.git)?\/?$/.test(String(obj.repo || ""))
        && typeof obj.ts === "number") {
      root.watchState = obj
    } else {
      root.watchState = null
    }
    root.nowMs = Date.now()
    root.statusChecked = false
    root.pluginInstalled = false
    root.pluginEnabled = false
    root.statusForId = ""
  }

  function refreshStatus() {
    if (!root.opened || !root.watchState) return
    root.statusForId = String(root.watchState.id)
    listProc.running = true
  }

  function openPluginPage() {
    var url = root.watchState
      ? root.marketplaceUrl + "plugin.html?id=" + encodeURIComponent(String(root.watchState.id))
      : root.marketplaceUrl
    Quickshell.execDetached(["xdg-open", url])
  }

  // Install / Uninstall / Update go through the wizard (the project's
  // consent gate: it re-validates catalog, repo manifest, and live state
  // before acting). Summon this plugin's own overlay with the beacon's
  // id/repo/name as a hint.
  function summonWizard(mode) {
    if (!root.watchState) return
    var w = root.watchState
    var payload = JSON.stringify({
      source: "bar", mode: mode,
      id: String(w.id), repo: String(w.repo), name: String(w.name || w.id)
    })
    var summoned = false
    if (root.bar && root.bar.shell && typeof root.bar.shell.summon === "function")
      summoned = root.bar.shell.summon(root.moduleName, payload) === true
    if (!summoned)
      Quickshell.execDetached(["omarchy-shell", "-q", "shell", "summon", root.moduleName, payload])
    root.close()
  }

  // Bar-section placement is layout config, not an install: no wizard gate,
  // the official CLI command runs directly.
  function moveIcon(section) {
    if (!root.watchState) return
    root.moveSection = section
    root.moveOutput = ""
    moveProc.command = ["omarchy", "bar", "move", String(root.watchState.id), "--section", section]
    moveProc.running = true
    root.close()
  }

  function notify(title, body) {
    var cmd = Quickshell.env("OMARCHY_PATH")
      ? Quickshell.env("OMARCHY_PATH") + "/bin/omarchy-notification-send"
      : "omarchy-notification-send"
    Quickshell.execDetached([
      cmd,
      "--app-name", "omarchy-browser-plugin-manager",
      "--expire-time", "8000",
      String(title || ""),
      String(body || "")
    ])
  }

  function watchedName() {
    return root.watchState ? String(root.watchState.name || root.watchState.id) : ""
  }

  FileView {
    id: watchFile
    path: root.watchPath
    watchChanges: true
    printErrors: false
    onLoaded: root.applyWatch(text())
    onLoadFailed: root.applyWatch("")
    onFileChanged: reload()
  }

  // Re-evaluates beaconLive as the 5s beacon renews and time passes, so
  // the icon lights within seconds of a tab opening and dims when it dies.
  Timer {
    interval: 2000
    repeat: true
    running: true
    onTriggered: root.nowMs = Date.now()
  }

  onOpenedChanged: {
    if (root.opened) {
      root.nowMs = Date.now()
      watchFile.reload()
      Qt.callLater(root.refreshStatus)
    }
  }

  // Local plugin list, read like the host's status: the dropdown shows and
  // enables buttons from live state, never from the page.
  Process {
    id: listProc
    command: ["omarchy", "plugin", "list", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var entry = null
        try {
          var plugins = JSON.parse(String(text || "[]"))
          entry = plugins.filter(function (item) {
            return item && String(item.id) === root.statusForId
          })[0] || null
        } catch (e) {
          entry = null
        }
        root.pluginInstalled = !!entry && entry.firstParty !== true
        root.pluginEnabled = !!entry && entry.enabled === true
        root.statusChecked = true
      }
    }
    onExited: function (exitCode) {
      if (exitCode !== 0) root.statusChecked = true
    }
  }

  Process {
    id: moveProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.moveOutput += "\n" + String(text || "")
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.moveOutput += "\n" + String(text || "")
    }
    onExited: function (exitCode) {
      var name = root.watchedName()
      if (exitCode === 0) {
        root.notify("Bar icon moved", name + "'s icon now sits in the " + root.moveSection + " section.")
      } else {
        root.notify("Bar icon move failed",
                    name + ": omarchy bar move exited with code " + exitCode
                    + (root.moveOutput.trim() ? ": " + root.moveOutput.trim() : ""))
      }
    }
  }

  // Download-tray glyph: the extension's Install-button icon (.pi-icon-install
  // in content.js, also the wizard header icon): 13px box, stem 1x7 at x6.5,
  // tray walls/floor border 1 inset 1, no top side. Painted at the bar's
  // optical canvas size; the color is the button foreground: dim normally,
  // accent while a beacon is live ("lit up").
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    hasVisualContent: true
    foreground: root.beaconLive ? Color.accent : Qt.darker(root.barForeground, 1.6)
    tooltipText: root.beaconLive
      ? root.watchedName() + " \u00b7 open in browser \u00b7 click to manage"
      : "Browser Plugin Manager \u00b7 lights up on installable plugin pages"

    onPressed: function (code) {
      if (code === Qt.LeftButton) root.toggle()
    }

    Item {
      id: glyphCanvas
      anchors.centerIn: parent
      width: Style.bar.iconCanvas
      height: Style.bar.iconCanvas

      readonly property real u: width / 13
      readonly property real bw: Math.max(1, Math.round(u))

      Rectangle {  // stem
        x: Math.round(glyphCanvas.u * 6.5 - glyphCanvas.bw / 2)
        width: glyphCanvas.bw
        height: Math.round(glyphCanvas.u * 7)
        color: button.foreground
      }
      Rectangle {  // tray: left wall
        x: Math.round(glyphCanvas.u)
        y: Math.round(glyphCanvas.width - glyphCanvas.u * 6)
        width: glyphCanvas.bw
        height: Math.round(glyphCanvas.u * 5)
        color: button.foreground
      }
      Rectangle {  // tray: right wall
        x: Math.round(glyphCanvas.width - glyphCanvas.u - glyphCanvas.bw)
        y: Math.round(glyphCanvas.width - glyphCanvas.u * 6)
        width: glyphCanvas.bw
        height: Math.round(glyphCanvas.u * 5)
        color: button.foreground
      }
      Rectangle {  // tray: floor
        x: Math.round(glyphCanvas.u)
        y: Math.round(glyphCanvas.width - glyphCanvas.u * 2)
        width: Math.round(glyphCanvas.width - glyphCanvas.u * 2)
        height: glyphCanvas.bw
        color: button.foreground
      }
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  component BWButton: BorderSurface {
    id: bwButton
    property string label: ""
    property bool primary: false
    property bool danger: false
    readonly property color tone: danger
      ? (root.bar ? root.bar.urgent : Color.urgent)
      : Color.accent
    readonly property bool hot: bwMouse.containsMouse
    signal clickedBw

    width: bwLabel.implicitWidth + Style.space(28)
    height: Style.space(30)
    radius: Style.cornerRadius
    color: !enabled ? "transparent"
      : primary || danger
        ? (hot ? Util.alpha(tone, 0.2) : Util.alpha(tone, 0.12))
        : (hot ? Util.alpha(Color.foreground, 0.12) : Util.alpha(Color.foreground, 0.05))
    borderSpec: Border.flat(enabled
      ? (primary || danger ? tone : Util.alpha(Color.foreground, 0.3))
      : Util.alpha(Color.foreground, 0.2),
      1)

    Text {
      id: bwLabel
      anchors.centerIn: parent
      text: bwButton.label
      color: bwButton.enabled
        ? (bwButton.primary || bwButton.danger ? bwButton.tone : Color.foreground)
        : Util.alpha(Color.foreground, 0.35)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: bwButton.primary || bwButton.danger
    }
    MouseArea {
      id: bwMouse
      anchors.fill: parent
      hoverEnabled: true
      enabled: bwButton.enabled
      cursorShape: Qt.PointingHandCursor
      onClicked: bwButton.clickedBw()
    }
  }

  component BWLine: Text {
    width: popupColumn.width
    wrapMode: Text.Wrap
    color: Util.alpha(Color.foreground, 0.75)
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
  }

  PopupCard {
    id: popup
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    contentWidth: popup.fittedContentWidth(Style.space(340))
    contentHeight: popup.fittedContentHeight(popupColumn.implicitHeight, Style.space(460))

    Column {
      id: popupColumn
      width: parent ? parent.width : 0
      spacing: Style.spacing.md

      // Header: the wizard dialog's identity block (icon + name + subtitle).
      Row {
        width: popupColumn.width
        spacing: Style.space(12)

        Rectangle {
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(26)
          height: Style.space(26)
          radius: Style.cornerRadius > 0 ? 4 : 0
          color: Util.alpha(Color.accent, 0.12)
          border.color: Util.alpha(Color.accent, 0.4)
          border.width: 1

          Text {
            anchors.centerIn: parent
            text: "\u2913"   // downwards arrow to bar: the install gesture
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            font.bold: true
            color: Color.accent
          }
        }

        Column {
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(2)

          Text {
            text: root.beaconLive ? root.watchedName() : "Browser Plugin Manager"
            font.family: Style.font.family
            font.pixelSize: Style.font.title
            font.bold: true
            color: Color.foreground
          }
          Text {
            text: root.beaconLive
              ? (root.statusChecked
                 ? (root.pluginInstalled
                    ? (root.pluginEnabled ? "Installed \u00b7 enabled" : "Installed \u00b7 disabled")
                    : "Not installed")
                 : "Checking installed state\u2026")
              : "No plugin page is open in the browser"
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            color: Color.muted
          }
        }
      }

      // Live page: the wizard's identity line (name \u00b7 id).
      BWLine {
        visible: root.beaconLive
        text: root.watchedName() + "  \u00b7  " + String(root.watchState ? root.watchState.id : "")
        color: Color.foreground
        font.bold: true
        font.pixelSize: Style.font.body
      }

      BWLine {
        visible: !root.beaconLive
        text: "Open an installable plugin page on plugins.omarchy.org and the "
          + "icon lights up; click it here to install, uninstall, update, or "
          + "move that plugin's bar icon."
      }

      Text {
        visible: !root.beaconLive
        text: "<a href=\"" + root.marketplaceUrl + "\">Open plugins.omarchy.org</a>"
        textFormat: Text.RichText
        color: Color.accent
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        onLinkActivated: function (link) { Quickshell.execDetached(["xdg-open", String(link)]) }
      }

      // Manage buttons: from live local state only, enabled once the list
      // read landed, so the dropdown can never offer a stale action set.
      Row {
        visible: root.beaconLive
        spacing: Style.spacing.controlGap

        BWButton {
          visible: root.statusChecked && !root.pluginInstalled
          enabled: root.statusChecked
          primary: true
          label: "Install"
          onClickedBw: root.summonWizard("install")
        }
        BWButton {
          visible: root.statusChecked && root.pluginInstalled
          enabled: root.statusChecked
          label: "Update"
          onClickedBw: root.summonWizard("update")
        }
        BWButton {
          visible: root.statusChecked && root.pluginInstalled
          enabled: root.statusChecked
          danger: true
          label: "Uninstall"
          onClickedBw: root.summonWizard("uninstall")
        }
      }

      BWLine {
        visible: root.beaconLive && root.statusChecked && root.pluginInstalled && root.pluginEnabled
        text: "Move this plugin's bar icon:"
      }
      Row {
        visible: root.beaconLive && root.statusChecked && root.pluginInstalled && root.pluginEnabled
        spacing: Style.spacing.controlGap
        BWButton { label: "Left"; onClickedBw: root.moveIcon("left") }
        BWButton { label: "Center"; onClickedBw: root.moveIcon("center") }
        BWButton { label: "Right"; onClickedBw: root.moveIcon("right") }
      }

      Text {
        visible: root.beaconLive
        text: "<a href=\"open\">Open plugin page</a>"
        textFormat: Text.RichText
        color: Color.accent
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        onLinkActivated: root.openPluginPage()
      }
    }
  }
}
