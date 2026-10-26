import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui

// Plugin Installer wizard overlay.
// Summoned by the native messaging host (browser button click) with payload
// {id, repo, name}. The payload is treated as a hint only: the catalog entry
// and the repository manifest are re-fetched and cross-checked before
// anything is displayed, and nothing is installed until the user clicks
// Install in this overlay.

Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  property bool opened: false
  // review | installing | placement | enabling | done | error
  property string stage: "review"

  property string pluginId: ""
  property string pluginRepo: ""
  property string pluginName: ""
  // "install" (default) | "uninstall" — decided by the native host from live
  // local state, never by the page.
  property string mode: "install"

  property bool catalogLoaded: false
  property bool manifestLoaded: false
  property var catalogEntry: null
  property var pluginManifest: null
  property string catalogError: ""
  property string manifestError: ""

  property string installOutput: ""
  property bool isBarWidget: false
  property string defaultSection: "center"
  property string enabledSection: ""

  readonly property var manifestKinds: pluginManifest && pluginManifest.kinds
    ? pluginManifest.kinds : []
  readonly property bool summonable:
    manifestKinds.indexOf("overlay") !== -1
    || manifestKinds.indexOf("panel") !== -1
    || manifestKinds.indexOf("menu") !== -1

  readonly property string reviewBlocked: {
    if (catalogError.length > 0) return catalogError
    if (root.mode === "install" && manifestError.length > 0) return manifestError
    if (!catalogLoaded) return "Loading marketplace data\u2026"
    if (root.mode === "install" && !manifestLoaded) return "Loading marketplace data\u2026"
    return ""
  }
  readonly property bool canInstall: reviewBlocked.length === 0 && stage === "review"

  function open(payloadJson) {
    var payload = {}
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }

    pluginId = String(payload.id || "")
    pluginRepo = String(payload.repo || "")
    pluginName = String(payload.name || pluginId)
    mode = String(payload.mode || "install")
    if (mode !== "uninstall" && mode !== "enable" && mode !== "disable") mode = "install"

    stage = "review"
    catalogLoaded = false
    manifestLoaded = false
    catalogEntry = null
    pluginManifest = null
    catalogError = ""
    manifestError = ""
    installOutput = ""
    isBarWidget = false
    defaultSection = "center"
    enabledSection = ""

    opened = true

    catalogProc.running = true
    manifestProc.command = ["curl", "-fsS", "--max-time", "15", manifestUrl()]
    manifestProc.running = true
    if (mode !== "install") listProc.running = true
  }

  function close() {
    // The registry invokes close() as the plugin's hide handler; hide() in
    // turn calls close(). Clearing `opened` first makes that re-entry a no-op.
    if (!root.opened) return
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "dev.bram.plugin-installer")
  }

  // github.com/<owner>/<repo>[.git] -> owner/repo (empty when not parseable)
  function ownerRepo(url) {
    var match = /^https:\/\/github\.com\/([A-Za-z0-9._-]+)\/([A-Za-z0-9._-]+?)(\.git)?\/?$/.exec(url || "")
    return match ? match[1] + "/" + match[2] : ""
  }

  function manifestUrl() {
    var slug = ownerRepo(root.pluginRepo)
    if (!slug) return ""
    return "https://raw.githubusercontent.com/" + slug + "/HEAD/manifest.json"
  }

  function sameRepo(a, b) {
    var na = String(a || "").replace(/\.git$/, "").replace(/\/$/, "")
    var nb = String(b || "").replace(/\.git$/, "").replace(/\/$/, "")
    return na.length > 0 && na === nb
  }

  function finishLoads() {
    if (!root.catalogLoaded || !root.manifestLoaded) return
  }

  function shortSha(sha) {
    return /^[a-f0-9]{40}$/i.test(sha || "") ? sha.slice(0, 7) : "unknown"
  }

  function install() {
    if (!root.canInstall) return
    root.stage = "installing"
    addProc.command = ["omarchy", "plugin", "add", root.pluginRepo, "--yes"]
    addProc.running = true
  }

  function enable(section) {
    root.enabledSection = section
    root.stage = "enabling"
    var args = ["omarchy", "plugin", "enable", root.pluginId]
    if (section) args = args.concat(["--section", section])
    enableProc.command = args
    enableProc.running = true
  }

  function runUninstall() {
    if (root.catalogError.length > 0) return
    root.stage = "removing"
    removeProc.command = ["omarchy", "plugin", "remove", root.pluginId, "--yes"]
    removeProc.running = true
  }

  function confirmEnable() {
    if (root.catalogError.length > 0) return
    if (root.isBarWidget) root.stage = "placement"
    else root.enable("")
  }

  function runDisable() {
    if (root.catalogError.length > 0) return
    root.stage = "disabling"
    disableProc.command = ["omarchy", "plugin", "disable", root.pluginId]
    disableProc.running = true
  }

  function leaveDisabled() {
    Quickshell.execDetached([
      root.omarchyPath + "/bin/omarchy-notification-send",
      "Plugin not enabled",
      root.pluginName + " was installed disabled. Enable with: omarchy plugin enable " + root.pluginId
    ])
    root.close()
  }

  function openPlugin() {
    Quickshell.execDetached(["omarchy-shell", "shell", "summon", root.pluginId, "{}"])
    root.close()
  }

  function notifyInstalled() {
    var where = root.enabledSection ? " on the bar (" + root.enabledSection + " section)" : ""
    Quickshell.execDetached([
      root.omarchyPath + "/bin/omarchy-notification-send",
      root.mode === "install" ? "Plugin installed" : "Plugin enabled",
      root.pluginName + " is enabled" + where
    ])
  }

  // ---- data fetching ------------------------------------------------------

  Process {
    id: catalogProc
    command: ["curl", "-fsS", "--max-time", "15", "https://plugins.omarchy.org/catalog.json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (!raw) {
          root.catalogError = "Marketplace catalog could not be fetched"
        } else {
          var entry = null
          try {
            var catalog = JSON.parse(raw)
            entry = (catalog.plugins || []).filter(function (item) {
              return item && String(item.id) === root.pluginId
            })[0] || null
          } catch (e) {
            entry = null
          }
          if (!entry) {
            root.catalogError = "Plugin not found in the marketplace catalog"
          } else if (!entry.installAvailable
                     || entry.upstreamCheckStatus === "failed"
                     || entry.builtIn
                     || !(entry.installCommand || "")) {
            root.catalogError = "This plugin is not one-click installable ("
              + (entry.status || "unavailable") + ")"
          } else if (!root.sameRepo(root.pluginRepo, entry.repo)) {
            root.catalogError = "Repository mismatch between the request and the catalog; aborting"
          } else {
            root.catalogEntry = entry
          }
        }
        root.catalogLoaded = true
        root.finishLoads()
      }
    }
    onExited: function (exitCode) {
      if (exitCode !== 0 && !root.catalogLoaded) {
        root.catalogError = "Marketplace catalog could not be fetched"
        root.catalogLoaded = true
        root.finishLoads()
      }
    }
  }

  Process {
    id: manifestProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (!raw) {
          root.manifestError = "Plugin manifest.json could not be fetched"
        } else {
          var m = null
          try { m = JSON.parse(raw) } catch (e) { m = null }
          if (!m) {
            root.manifestError = "Plugin manifest.json is not valid JSON"
          } else if (String(m.id) !== root.pluginId) {
            root.manifestError = "Manifest id mismatch (" + String(m.id) + ")"
          } else {
            root.pluginManifest = m
            root.isBarWidget = (m.kinds || []).indexOf("bar-widget") !== -1
            root.defaultSection = (m.barWidget && m.barWidget.defaultSection) || "center"
          }
        }
        root.manifestLoaded = true
        root.finishLoads()
      }
    }
    onExited: function (exitCode) {
      if (exitCode !== 0 && !root.manifestLoaded) {
        root.manifestError = "Plugin manifest.json could not be fetched"
        root.manifestLoaded = true
        root.finishLoads()
      }
    }
  }

  // ---- install / enable ---------------------------------------------------

  Process {
    id: addProc
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.installOutput = String(text || "") }
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: root.installOutput += "\n" + String(text || "") }
    onExited: function (exitCode) {
      if (exitCode !== 0) {
        root.stage = "error"
        return
      }
      if (root.isBarWidget) root.stage = "placement"
      else root.enable("")
    }
  }

  Process {
    id: enableProc
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.installOutput += "\n" + String(text || "") }
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: root.installOutput += "\n" + String(text || "") }
    onExited: function (exitCode) {
      if (exitCode !== 0) {
        root.stage = "error"
        return
      }
      root.stage = "done"
      root.notifyInstalled()
    }
  }

  // ---- uninstall / enable / disable: local state check + actions ----------

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
            return item && String(item.id) === root.pluginId
          })[0] || null
        } catch (e) {
          entry = null
        }
        if (!entry || entry.firstParty) {
          root.catalogError = "Plugin is not installed as a user plugin; nothing to do"
        } else if (root.mode === "enable" && entry.enabled) {
          root.catalogError = "Plugin is already enabled"
        } else if (root.mode === "disable" && !entry.enabled) {
          root.catalogError = "Plugin is already disabled"
        } else if (root.mode === "uninstall"
                   && root.manifest && String(root.manifest.id) === root.pluginId) {
          root.catalogError = "The installer cannot uninstall itself. Remove it in a terminal: omarchy plugin remove dev.bram.plugin-installer --yes"
        } else if (root.mode === "enable") {
          root.stage = "enable-confirm"
        } else if (root.mode === "disable") {
          root.stage = "disable-confirm"
        } else {
          root.stage = "uninstall-confirm"
        }
      }
    }
    onExited: function (exitCode) {
      if (exitCode !== 0 && root.stage === "review") {
        root.catalogError = "Could not read the local plugin list"
      }
    }
  }

  Process {
    id: removeProc
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.installOutput += "\n" + String(text || "") }
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: root.installOutput += "\n" + String(text || "") }
    onExited: function (exitCode) {
      if (exitCode !== 0) {
        root.stage = "error"
        return
      }
      root.stage = "done"
      Quickshell.execDetached([
        root.omarchyPath + "/bin/omarchy-notification-send",
        "Plugin uninstalled",
        root.pluginName + " was removed and disabled"
      ])
    }
  }

  Process {
    id: disableProc
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.installOutput += "\n" + String(text || "") }
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: root.installOutput += "\n" + String(text || "") }
    onExited: function (exitCode) {
      if (exitCode !== 0) {
        root.stage = "error"
        return
      }
      root.stage = "done"
      Quickshell.execDetached([
        root.omarchyPath + "/bin/omarchy-notification-send",
        "Plugin disabled",
        root.pluginName + " is disabled. Enable it again from the plugin page"
      ])
    }
  }
  // ---- UI -----------------------------------------------------------------

  // All chrome below is painted from the Omarchy theme (qs.Commons: the
  // active theme's palette + typography/spacing/rounding tokens; qs.Ui: the
  // shared BorderSurface), so the wizard follows theme switches instantly.

  component PiButton: BorderSurface {
    id: piButton
    property string label: ""
    property bool primary: false
    property bool danger: false
    readonly property color tone: danger
      ? Commons.Color.urgent
      : primary ? Commons.Color.accent : Commons.Color.foreground
    readonly property bool hot: piMouse.containsMouse
    signal clickedPi

    width: labelText.implicitWidth + Style.space(36)
    height: Style.space(34)
    radius: Style.cornerRadius
    color: !enabled ? "transparent"
      : primary || danger
        ? (hot ? Util.alpha(tone, 0.22) : Util.alpha(tone, 0.1))
        : (hot ? Style.hoverFill : "transparent")
    borderSpec: Border.flat(enabled
      ? Util.alpha(tone, hot ? 1 : (primary || danger ? 0.6 : 0.38))
      : Util.alpha(Commons.Color.foreground, 0.2),
      Math.max(1, Style.normalBorderWidth))

    Text {
      id: labelText
      anchors.centerIn: parent
      text: piButton.label
      color: piButton.enabled
        ? (piButton.primary || piButton.danger ? piButton.tone : Commons.Color.foreground)
        : Util.alpha(Commons.Color.foreground, 0.35)
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      font.bold: piButton.primary || piButton.danger
    }
    MouseArea {
      id: piMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: piButton.clickedPi()
    }
  }

  component PiLine: Text {
    width: cardColumn.width
    wrapMode: Text.Wrap
    color: Util.alpha(Commons.Color.foreground, 0.75)
    font.family: Style.font.family
    font.pixelSize: Style.font.body
  }

  Shortcut {
    sequence: "Escape"
    enabled: root.opened
    onActivated: root.close()
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "dev-bram-plugin-installer"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: Commons.Color.menu.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.close()
    }

    BorderSurface {
      id: card
      anchors.centerIn: parent
      width: Math.min(parent.width - Style.space(48), Style.space(420))
      height: cardColumn.implicitHeight + Style.space(48)
      radius: Style.cornerRadius
      color: Commons.Color.popups.background
      borderSpec: Border.flat(Commons.Color.popups.border, Math.max(1, Style.normalBorderWidth))

      // Swallow clicks over the card so the scrim MouseArea below doesn't close.
      MouseArea { anchors.fill: parent; onClicked: {} }

      Column {
        id: cardColumn
        anchors {
          top: parent.top
          left: parent.left
          right: parent.right
          margins: Style.spacing.panelPadding
        }
        spacing: Style.spacing.panelGap

        Text {
          width: parent.width
          text: ({ install: "Install plugin", uninstall: "Uninstall plugin",
                   enable: "Enable plugin", disable: "Disable plugin" })[root.mode]
          color: Commons.Color.foreground
          font.family: Style.font.family
          font.bold: true
          font.pixelSize: Style.font.heading
        }
        PiLine {
          text: root.pluginName + "  \u00b7  " + root.pluginId
          color: Commons.Color.foreground
          font.bold: true
          font.pixelSize: Style.font.title
        }

        // ---- stage: review ----
        Column {
          visible: root.stage === "review"
          width: cardColumn.width
          spacing: Style.spacing.lg
          PiLine {
            visible: root.catalogEntry !== null
            text: {
              var e = root.catalogEntry || {}
              var bits = []
              if (e.author) bits.push("by " + e.author)
              if (e.version) bits.push("v" + e.version)
              if (e.license) bits.push(e.license)
              var kinds = root.manifestKinds
              if (kinds.length) bits.push(kinds.join(", "))
              return bits.join("  \u00b7  ")
            }
          }
          PiLine {
            visible: root.catalogEntry !== null
            text: "Source: " + root.pluginRepo
          }
          PiLine {
            visible: root.catalogEntry !== null
            text: {
              var e = root.catalogEntry
              if (!e) return ""
              var verification = e.verificationStatus === "verified" ? "verified" : "unverified"
              var snapshot = e.verificationSnapshotStatus === "verified" ? "snapshot verified" : "snapshot unverified"
              return "Marketplace status: " + verification + " \u00b7 " + snapshot
                + " at " + root.shortSha(e.listingValidatedCommit)
            }
          }
          PiLine {
            visible: root.catalogEntry !== null
            color: Commons.Color.accent
            text: "Installs the repository's current HEAD, which may differ from the verified snapshot."
          }
          PiLine {
            visible: root.reviewBlocked.length > 0
            color: Commons.Color.urgent
            text: root.reviewBlocked
          }
        }

        // ---- stage: installing / enabling ----
        PiLine {
          visible: root.stage === "installing"
          text: "Cloning and validating the plugin\u2026"
        }
        PiLine {
          visible: root.stage === "enabling"
          text: "Enabling the plugin\u2026"
          + (root.enabledSection ? " (bar section: " + root.enabledSection + ")" : "")
        }
        PiLine {
          visible: root.stage === "uninstall-confirm"
          text: "Installed as a user plugin. Uninstalling removes the plugin files, "
            + "disables it, and removes its bar layout entry."
        }
        PiLine {
          visible: root.stage === "removing"
          text: "Removing the plugin\u2026"
        }
        PiLine {
          visible: root.stage === "enable-confirm"
          text: root.isBarWidget
            ? "Installed and disabled. Enable it and pick the bar section for its icon."
            : "Installed and disabled. Enable it to load it into the shell."
        }
        PiLine {
          visible: root.stage === "disable-confirm"
          text: "Installed and enabled. Disabling unloads it from the shell; "
            + "the plugin files stay installed."
        }
        PiLine {
          visible: root.stage === "disabling"
          text: "Disabling the plugin\u2026"
        }

        // ---- stage: placement ----
        Column {
          visible: root.stage === "placement"
          width: cardColumn.width
          spacing: Style.spacing.rowGap
          PiLine {
            text: root.mode === "install"
              ? "Installed (disabled). Where should the bar icon go?"
              : "Where should the bar icon go?"
          }
          Row {
            spacing: Style.spacing.controlGap
            PiButton { label: "Left"; onClickedPi: root.enable("left") }
            PiButton { label: "Center"; onClickedPi: root.enable("center") }
            PiButton { label: "Right"; onClickedPi: root.enable("right") }
            PiButton {
              label: "Keep default (" + root.defaultSection + ")"
              onClickedPi: root.enable("")
            }
          }
        }

        // ---- stage: done ----
        PiLine {
          visible: root.stage === "done"
          color: Commons.Color.accent
          text: {
            if (root.mode === "uninstall")
              return "Uninstalled. Reinstall from the plugin page at any time."
            if (root.mode === "disable")
              return "Disabled. Enable it again from the plugin page at any time."
            if (root.mode === "enable")
              return "Enabled." + (root.enabledSection ? " Bar section: " + root.enabledSection + "." : "")
            return "Installed and enabled. Move later with: omarchy bar move "
              + root.pluginId + " --section left|center|right"
          }
        }

        // ---- stage: error ----
        PiLine {
          visible: root.stage === "error"
          color: Commons.Color.urgent
          text: ({ install: "Installation failed.", uninstall: "Uninstall failed.",
                   enable: "Enabling failed.", disable: "Disabling failed." })[root.mode]
        }
        PiLine {
          visible: root.stage === "error" && root.installOutput.length > 0
          color: Util.alpha(Commons.Color.foreground, 0.55)
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
          maximumLineCount: 8
          text: root.installOutput
        }

        Item { width: 1; height: Style.spacing.xs }

        // ---- footer ----
        Row {
          spacing: Style.spacing.controlGap
          PiButton {
            visible: root.mode === "install" && root.stage === "review"
            enabled: root.canInstall
            primary: true
            label: "Install plugin"
            onClickedPi: root.install()
          }
          PiButton {
            visible: root.mode === "uninstall" && root.stage === "uninstall-confirm"
            enabled: root.catalogError.length === 0
            danger: true
            primary: true
            label: "Uninstall plugin"
            onClickedPi: root.runUninstall()
          }
          PiButton {
            visible: root.mode === "enable" && root.stage === "enable-confirm"
            enabled: root.catalogError.length === 0
            primary: true
            label: "Enable plugin"
            onClickedPi: root.confirmEnable()
          }
          PiButton {
            visible: root.mode === "disable" && root.stage === "disable-confirm"
            enabled: root.catalogError.length === 0
            primary: true
            label: "Disable plugin"
            onClickedPi: root.runDisable()
          }
          PiButton {
            visible: root.mode === "install" && root.stage === "placement"
            label: "Keep disabled"
            onClickedPi: root.leaveDisabled()
          }
          PiButton {
            visible: root.stage === "done" && root.summonable
              && root.mode !== "uninstall" && root.mode !== "disable"
            primary: true
            label: "Open plugin"
            onClickedPi: root.openPlugin()
          }
          PiButton {
            visible: root.stage === "review" || root.stage === "uninstall-confirm"
              || root.stage === "enable-confirm" || root.stage === "disable-confirm"
              || root.stage === "done" || root.stage === "error"
            label: root.stage === "done" ? "Done" : "Cancel"
            onClickedPi: root.close()
          }
        }
      }
    }
  }
}
