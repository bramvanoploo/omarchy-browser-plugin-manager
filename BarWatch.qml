import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Omarchy Browser Plugin Manager bar widget (watcher mode).
//
// The icon lights up while a focused browser window has an installable
// plugin page on its active tab: the extension renews a beacon record with
// the native host every few seconds, the host writes it to
// browser-watch.json in the state dir, and this widget reads that file. A
// beacon that stops (tab closed, browser switched to the background,
// browser killed) goes stale and the icon dims.
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

  // What the popup shows. The popup freezes on the plugin captured when it
  // opens: the menu must never swap or lose its content mid-interaction
  // (the record can die while open: a 12s app-switch staleness, the tab
  // closed). Two capture windows stay open: the reload issued on open
  // (captureOnOpen: a tab switch right before opening must be picked up,
  // the 2s poll may not have run), and a popup showing the placeholder (a
  // switched-to page renews its beacon ~1s after the switch, so a fresh
  // record can fill the open popup). The icon follows beaconLive.
  readonly property bool popupLive: beaconLive || (root.opened && root.watchState !== null)
  // One capture allowed right after the popup opens (consumed by
  // applyWatch; kept on transient read hiccups so the next poll retries).
  property bool captureOnOpen: false

  // Live local state for the watched plugin, refreshed while the popup is
  // open (the wizard can change it while the dropdown sits there).
  property bool statusChecked: false
  property bool pluginInstalled: false
  property bool pluginEnabled: false
  property string statusForId: ""
  property string moveSection: ""
  property string moveOutput: ""
  property string enabledOutput: ""

  // Installed plugin version, from the local plugin manifest (display gate
  // for the Update button: show it only when the catalog version is newer).
  property string installedVersion: ""

  readonly property string pluginsDir: {
    var base = Quickshell.env("HOME") || "/tmp"
    return base + "/.config/omarchy/plugins"
  }
  readonly property string installedManifestPath: {
    var s = root.statusForId
    // statusForId is set from the shape-checked beacon id; belt: no traversal.
    return s && s.indexOf("..") === -1 ? root.pluginsDir + "/" + s + "/manifest.json" : ""
  }

  // Catalog version vs installed version (numeric semver-ish compare).
  readonly property bool hasUpdate: {
    var e = root.catalogEntry
    if (!e || e.id !== root.statusForId || !root.pluginInstalled) return false
    var remote = String(e.version || "")
    var local = root.installedVersion
    if (!remote || !local) return false
    return root.compareVersions(remote, local) > 0
  }

  function compareVersions(a, b) {
    var pa = String(a).split(".")
    var pb = String(b).split(".")
    for (var i = 0; i < Math.max(pa.length, pb.length); i++) {
      var na = parseInt(pa[i], 10)
      var nb = parseInt(pb[i], 10)
      na = isNaN(na) ? 0 : na
      nb = isNaN(nb) ? 0 : nb
      if (na !== nb) return na > nb ? 1 : -1
    }
    return 0
  }

  // Marketplace catalog entry for the watched plugin (display only: the
  // preview thumbnail, description, author, version). Fetched while the
  // popup is open, cached per plugin id.
  property var catalogEntry: null
  property string catalogForId: ""

  readonly property string catalogThumb: {
    var e = root.catalogEntry
    var t = e ? String(e.previewThumbnail || "") : ""
    // Only same-site relative asset paths are ever loaded as images.
    return /^assets\/[A-Za-z0-9._\/-]+$/.test(t) ? t : ""
  }
  // Marketplace card proportion (same as plugins.omarchy.org: every card
  // thumb is a 16:9 box with object-fit: cover), not the entry's native
  // size: 320x720 portrait thumbnails must not tower over the popup.
  readonly property real catalogThumbRatio: 9 / 16
  // Native thumbnail proportion (h/w) from the catalog entry: the cover
  // crop needs it to size the image so a portrait thumb shows its TOP
  // (the box clips the overflow at the bottom) and a landscape thumb
  // stays vertically centered.
  readonly property real catalogThumbNative: {
    var e = root.catalogEntry
    var w = e ? Number(e.previewThumbnailWidth) || 0 : 0
    var h = e ? Number(e.previewThumbnailHeight) || 0 : 0
    return w > 0 && h > 0 ? h / w : root.catalogThumbRatio
  }
  readonly property string catalogBlurb: {
    var e = root.catalogEntry
    return e && e.id === root.catalogForId ? String(e.description || "") : ""
  }
  readonly property string catalogMeta: {
    var e = root.catalogEntry
    if (!e || e.id !== root.catalogForId) return ""
    var bits = []
    if (e.author) bits.push("by " + String(e.author))
    if (e.version) bits.push("v" + String(e.version))
    if (String(e.verificationStatus || "") === "verified") bits.push("verified")
    return bits.join("  \u00b7  ")
  }

  // Section of the omarchy bar layout ("left"/"center"/"right") that holds
  // the watched plugin's icon, "" when unknown. Bar layout entries carry
  // the plugin id; omarchy bar move writes the same file we read.
  property string iconSection: ""
  function parseIconSection(raw) {
    var sec = ""
    var id = root.watchState ? String(root.watchState.id) : ""
    try {
      var d = JSON.parse(raw)
      var lay = d && d.bar && d.bar.layout ? d.bar.layout : {}
      var order = ["left", "center", "right"]
      for (var i = 0; i < order.length && !sec; i++) {
        var arr = lay[order[i]]
        if (!Array.isArray(arr)) continue
        for (var j = 0; j < arr.length; j++) {
          if (arr[j] && String(arr[j].id || "") === id) { sec = order[i]; break }
        }
      }
    } catch (e) {
      sec = ""
    }
    root.iconSection = id ? sec : ""
  }

  function applyWatch(raw, fileGone) {
    // Freeze the popup on the plugin captured at open time (see popupLive).
    // A popup that currently shows the placeholder is never frozen: filling
    // in content loses nothing, and the switched-to page's first beacon
    // renewal lands ~1s after the switch, while the popup is already open.
    if (root.opened && root.watchState !== null && !root.captureOnOpen) return
    var s = String(raw || "").trim()
    var obj = null
    if (s) {
      try { obj = JSON.parse(s) } catch (e) { obj = null }
    }
    // Shape-checked: the file is host-written, but a corrupt/foreign file
    // must never render as a plugin identity.
    var accepted = obj && typeof obj === "object"
      && /^[a-z0-9][a-z0-9.-]{0,127}$/.test(String(obj.id || ""))
      && String(obj.id || "").indexOf("..") === -1
      && /^https:\/\/github\.com\/[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+(\.git)?\/?$/.test(String(obj.repo || ""))
      && typeof obj.ts === "number"
    var newId = accepted ? String(obj.id) : ""
    var oldId = root.watchState ? String(root.watchState.id) : ""
    // A failed/partial read (the file is renamed-replaced while we reload,
    // which Qt's file watching reports as gone) is transient: keep the last
    // record and let ts staleness end it. A file that is really gone
    // (FileNotFound) is an intentional unwatch: the extension ended the
    // beacon (tab hidden, page closed), so the placeholder must show right
    // away, not survive 12s on the kept record.
    if (root.watchState !== null && !accepted && !fileGone) {
      if (root.opened) return // hiccup during an open capture: stay frozen, next poll retries
      console.warn("BarWatch: transient beacon read failure, keeping last record")
      root.nowMs = Date.now()
      return
    }
    root.captureOnOpen = false
    root.watchState = accepted ? obj : null
    root.nowMs = Date.now()
    // Status and catalog are per watched plugin: re-check them when the
    // beacon switches plugin, not on every 5s renewal.
    if (newId !== oldId) {
      root.statusChecked = false
      root.pluginInstalled = false
      root.pluginEnabled = false
      root.statusForId = ""
      root.installedVersion = ""
      root.catalogEntry = null
      root.catalogForId = ""
      root.iconSection = ""
      shellFile.reload()
      if (root.opened && newId !== "") {
        // The popup stayed open across a tab switch: re-read the new plugin.
        Qt.callLater(root.refreshStatus)
        Qt.callLater(root.refreshCatalog)
      }
    }
  }

  function refreshStatus() {
    if (!root.opened || !root.watchState) return
    root.statusForId = String(root.watchState.id)
    listProc.running = true
  }

  // Marketplace metadata for the watched plugin (preview image, blurb).
  function refreshCatalog() {
    if (!root.opened || !root.watchState) return
    var id = String(root.watchState.id)
    if (root.catalogForId === id) return
    root.catalogForId = id
    root.catalogEntry = null
    catalogProc.running = true
  }

  function openMarketplace() {
    Quickshell.execDetached(["xdg-open", root.marketplaceUrl])
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

  // Enable / Disable is plugin state, not an install: the browser page's own
  // buttons route the same way through the host, which runs the official CLI
  // commands directly. The popup stays open and the status row refreshes.
  function setEnabledForWatch(activate) {
    if (!root.watchState) return
    root.enabledOutput = ""
    enabledProc.command = [
      "omarchy", "plugin", activate ? "enable" : "disable", String(root.watchState.id)
    ]
    enabledProc.running = true
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

  // The host rewrites the beacon atomically (temp file + rename), which
  // drops Qt's inode-based file watch after the first change. So the beacon
  // is polled on the staleness timer below instead of watched: a 2s reload
  // of a tiny file is cheap and never goes stale.
  FileView {
    id: watchFile
    path: root.watchPath
    printErrors: false
    onLoaded: root.applyWatch(text())
    onLoadFailed: function (error) {
      // FileNotFound means the host deliberately removed the record
      // (unwatch); any other failure is a transient read hiccup.
      root.applyWatch("", error === FileViewError.FileNotFound)
    }
  }

  // Local manifest of the watched plugin (installed version for the
  // Update-button gate). Path follows statusForId, so it reloads per plugin.
  FileView {
    id: manifestFile
    path: root.installedManifestPath
    printErrors: false
    onLoaded: {
      try {
        var m = JSON.parse(text())
        root.installedVersion = String(m.version || "")
      } catch (e) {
        root.installedVersion = ""
      }
    }
    onLoadFailed: root.installedVersion = ""
  }

  // Bar layout config: which section (left/center/right) the watched
  // plugin's icon currently sits in. Read when the popup opens and after a
  // move, so the move buttons can disable the active section.
  FileView {
    id: shellFile
    path: (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") || "/tmp") + "/.config")
      + "/omarchy/shell.json"
    printErrors: false
    onLoaded: root.parseIconSection(text())
    onLoadFailed: root.iconSection = ""
  }

  // Re-evaluates beaconLive as the 5s beacon renews and time passes, so
  // the icon lights within seconds of a tab opening and dims when it dies.
  Timer {
    interval: 2000
    repeat: true
    running: true
    onTriggered: {
      root.nowMs = Date.now()
      watchFile.reload()
    }
  }

  onOpenedChanged: {
    if (root.opened) {
      root.nowMs = Date.now()
      // Capture the current beacon record for this opening (the async
      // reload lands while opened is already true; applyWatch honors this
      // flag exactly once so the capture is not frozen away).
      root.captureOnOpen = true
      watchFile.reload()
      shellFile.reload()
      Qt.callLater(root.refreshStatus)
      Qt.callLater(root.refreshCatalog)
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
        var parsed = false
        try {
          var plugins = JSON.parse(String(text || "[]"))
          if (Array.isArray(plugins)) {
            parsed = true
            entry = plugins.filter(function (item) {
              return item && String(item.id) === root.statusForId
            })[0] || null
          }
        } catch (e) {
          parsed = false
        }
        // A malformed read must never render as "not installed": leave the
        // buttons unconfirmed (and re-read on the next open) instead.
        if (parsed) {
          root.pluginInstalled = !!entry && entry.firstParty !== true
          root.pluginEnabled = !!entry && entry.enabled === true
          root.statusChecked = true
        }
      }
    }
    onExited: function (exitCode) {
      if (exitCode !== 0) root.statusChecked = false
    }
  }

  // Marketplace catalog, same fetch the wizard validates against; used here
  // for display only (preview thumbnail, description, author, version).
  Process {
    id: catalogProc
    command: ["curl", "-fsSL", "--proto", "=https", "--max-time", "15", "--", "https://plugins.omarchy.org/catalog.json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var entry = null
        try {
          var catalog = JSON.parse(String(text || "{}"))
          // The catalog root is an object ({generatedAt, plugins: [...]});
          // a bare top-level array is accepted too, like the wizard.
          var items = Array.isArray(catalog) ? catalog
            : (catalog && Array.isArray(catalog.plugins) ? catalog.plugins : [])
          entry = items.filter(function (item) {
            return item && String(item.id) === root.catalogForId
          })[0] || null
        } catch (e) {
          entry = null
        }
        root.catalogEntry = entry
      }
    }
    onExited: function (exitCode) {
      if (exitCode !== 0) root.catalogEntry = null
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
      shellFile.reload() // reflect the new section in the move buttons
      if (exitCode === 0) {
        root.notify("Bar icon moved", name + "'s icon now sits in the " + root.moveSection + " section.")
      } else {
        root.notify("Bar icon move failed",
                    name + ": omarchy bar move exited with code " + exitCode
                    + (root.moveOutput.trim() ? ": " + root.moveOutput.trim() : ""))
      }
    }
  }

  Process {
    id: enabledProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.enabledOutput += "\n" + String(text || "")
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.enabledOutput += "\n" + String(text || "")
    }
    onExited: function (exitCode) {
      var name = root.watchedName()
      var verb = String(enabledProc.command[2] || "")
      if (exitCode === 0) {
        root.notify("Plugin " + verb + "d", name + " " + verb + "d.")
      } else {
        root.notify("Plugin " + verb + " failed",
                    name + ": omarchy plugin " + verb + " exited with code " + exitCode
                    + (root.enabledOutput.trim() ? ": " + root.enabledOutput.trim() : ""))
      }
      // Re-read the live state so the popup's buttons follow the change.
      root.statusChecked = false
      Qt.callLater(root.refreshStatus)
    }
  }

  // Browser-window glyph (Nerd Font md "web_asset", U+F05C5): a browser
  // page frame, the thing the manager watches. BarIconButton draws it at
  // the bar's optical canvas size; the color follows the button defaults:
  // dim normally, active (accent) color while a beacon is live ("lit up").
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\uF05C5"
    active: root.beaconLive
    tooltipText: root.beaconLive
      ? root.watchedName() + " \u00b7 open in browser \u00b7 click to manage"
      : "Browser Plugin Manager \u00b7 lights up on installable plugin pages"

    onPressed: function (code) {
      if (code === Qt.LeftButton) root.toggle()
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
    padding: Style.space(24)
    contentWidth: popup.fittedContentWidth(Style.space(360))
    contentHeight: popup.fittedContentHeight(popupColumn.implicitHeight, Style.space(560))

    Column {
      id: popupColumn
      width: parent ? parent.width : 0
      spacing: Style.space(14)

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
          spacing: Style.space(4)

          Text {
            text: root.popupLive ? root.watchedName() : "Browser Plugin Manager"
            font.family: Style.font.family
            font.pixelSize: Style.font.title
            font.bold: true
            color: Color.foreground
          }
          Text {
            text: root.popupLive
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
        visible: root.popupLive
        text: root.watchedName() + "  \u00b7  " + String(root.watchState ? root.watchState.id : "")
        color: Color.foreground
        font.bold: true
        font.pixelSize: Style.font.body
      }

      // Preview thumbnail from the marketplace catalog, card proportions.
      Rectangle {
        visible: root.popupLive && root.catalogThumb !== ""
        width: popupColumn.width
        // Proportional height at the full panel width, capped at the
        // marketplace card's 16:9: wide-short thumbs (e.g. 499x48 banners)
        // get their own short box; taller images (e.g. 320x720) cap here
        // and overflow, hidden by clip.
        height: visible
          ? Math.round((width - 2) * Math.min(root.catalogThumbNative, root.catalogThumbRatio)) + 2
          : 0
        radius: Style.cornerRadius
        color: Util.alpha(Color.foreground, 0.05)
        border.color: Util.alpha(Color.foreground, 0.15)
        border.width: 1
        clip: true

        Image {
          // Full-width, proportional (h/w from the catalog entry), anchored
          // at the TOP: only images that exceed the capped box height
          // overflow, and the box's clip hides the BOTTOM overflow, so the
          // top of the image always stays visible. No side cropping.
          x: 1
          y: 1
          width: parent.width - 2
          height: Math.max(parent.height - 2, width * root.catalogThumbNative)
          source: root.catalogThumb !== "" ? root.marketplaceUrl + root.catalogThumb : ""
          sourceSize.width: width * 2
          fillMode: Image.Stretch
          asynchronous: true
          cache: true
          smooth: true
        }
      }

      // Catalog blurb + author/version line.
      BWLine {
        visible: root.popupLive && root.catalogBlurb !== ""
        text: root.catalogBlurb
      }
      BWLine {
        visible: root.popupLive && root.catalogMeta !== ""
        text: root.catalogMeta
        font.pixelSize: Style.font.caption
        color: Color.muted
      }

      BWLine {
        visible: !root.popupLive
        text: "Open an installable plugin page on plugins.omarchy.org and the "
          + "icon lights up; click it here to install, uninstall, update, or "
          + "move that plugin's bar icon."
      }

      Row {
        visible: !root.popupLive
        spacing: Style.spacing.controlGap

        BWButton {
          label: "Open plugins.omarchy.org"
          onClickedBw: root.openMarketplace()
        }
      }

      // Manage buttons: from live local state only, enabled once the list
      // read landed, so the dropdown can never offer a stale action set.
      // Two visible buttons (the common case) each take half the panel row.
      GridLayout {
        visible: root.popupLive
        width: popupColumn.width
        columns: 2
        columnSpacing: Style.spacing.controlGap

        BWButton {
          visible: root.statusChecked && !root.pluginInstalled
          enabled: root.statusChecked
          primary: true
          label: "Install"
          Layout.fillWidth: true
          Layout.preferredHeight: Style.space(30)
          onClickedBw: root.summonWizard("install")
        }
        BWButton {
          visible: root.statusChecked && root.pluginInstalled && root.hasUpdate
          enabled: root.statusChecked
          label: "Update"
          Layout.fillWidth: true
          Layout.preferredHeight: Style.space(30)
          onClickedBw: root.summonWizard("update")
        }
        BWButton {
          visible: root.statusChecked && root.pluginInstalled && !root.pluginEnabled
          enabled: root.statusChecked
          primary: true
          label: "Enable"
          Layout.fillWidth: true
          Layout.preferredHeight: Style.space(30)
          onClickedBw: root.setEnabledForWatch(true)
        }
        BWButton {
          visible: root.statusChecked && root.pluginInstalled && root.pluginEnabled
          enabled: root.statusChecked
          label: "Disable"
          Layout.fillWidth: true
          Layout.preferredHeight: Style.space(30)
          onClickedBw: root.setEnabledForWatch(false)
        }
        BWButton {
          visible: root.statusChecked && root.pluginInstalled
          enabled: root.statusChecked
          danger: true
          label: "Uninstall"
          Layout.fillWidth: true
          Layout.preferredHeight: Style.space(30)
          onClickedBw: root.summonWizard("uninstall")
        }
      }

      BWLine {
        visible: root.popupLive && root.statusChecked && root.pluginInstalled && root.pluginEnabled
        text: "Move this plugin's bar icon:"
      }
      GridLayout {
        visible: root.popupLive && root.statusChecked && root.pluginInstalled && root.pluginEnabled
        width: popupColumn.width
        columns: 3
        columnSpacing: Style.spacing.controlGap
        // Three equal-width buttons spanning the full panel row; the
        // section the icon currently sits in is disabled and marked
        // "(active)" (iconSection from the bar layout config).
        BWButton {
          Layout.fillWidth: true
          Layout.preferredHeight: Style.space(30)
          label: "Left" + (root.iconSection === "left" ? " (active)" : "")
          enabled: root.iconSection !== "left"
          onClickedBw: root.moveIcon("left")
        }
        BWButton {
          Layout.fillWidth: true
          Layout.preferredHeight: Style.space(30)
          label: "Center" + (root.iconSection === "center" ? " (active)" : "")
          enabled: root.iconSection !== "center"
          onClickedBw: root.moveIcon("center")
        }
        BWButton {
          Layout.fillWidth: true
          Layout.preferredHeight: Style.space(30)
          label: "Right" + (root.iconSection === "right" ? " (active)" : "")
          enabled: root.iconSection !== "right"
          onClickedBw: root.moveIcon("right")
        }
      }
    }
  }
}
