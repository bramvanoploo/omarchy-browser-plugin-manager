import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui

// Plugin Installer wizard overlay.
// Summoned by the native messaging host (browser button click) with payload
// {mode, id, repo, name}. There is no confirmation step: the host validated
// the request against the live catalog, and this overlay re-validates (catalog
// entry, repository manifest, local plugin list) and then runs the omarchy
// plugin command immediately. Success and validation failures are reported as
// desktop notifications; nothing is executed on a failed validation.

Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  property bool opened: false
  // validating | installing | enabling | removing | disabling
  property string stage: "validating"

  property string pluginId: ""
  property string pluginRepo: ""
  property string pluginName: ""
  // "install" (default) | "uninstall" | "enable" | "disable" — decided by the
  // native host from live local state, never by the page.
  property string mode: "install"

  property bool catalogLoaded: false
  property bool manifestLoaded: false
  property bool listChecked: false
  property bool actionStarted: false
  property var catalogEntry: null
  property var pluginManifest: null
  property string catalogError: ""
  property string manifestError: ""
  property string listError: ""

  property string installOutput: ""
  property string enabledSection: ""

  readonly property string title: ({
    install: "Installing plugin", uninstall: "Uninstalling plugin",
    enable: "Enabling plugin", disable: "Disabling plugin" })[root.mode]

  function open(payloadJson) {
    var payload = {}
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }

    pluginId = String(payload.id || "")
    pluginRepo = String(payload.repo || "")
    pluginName = String(payload.name || pluginId)
    mode = String(payload.mode || "install")
    if (mode !== "uninstall" && mode !== "enable" && mode !== "disable") mode = "install"

    stage = "validating"
    catalogLoaded = false
    manifestLoaded = false
    listChecked = false
    actionStarted = false
    catalogEntry = null
    pluginManifest = null
    catalogError = ""
    manifestError = ""
    listError = ""
    installOutput = ""
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

  function notify(title, body) {
    Quickshell.execDetached([
      root.omarchyPath + "/bin/omarchy-notification-send", title, body
    ])
  }

  function fail(reason) {
    var t = ({ install: "Plugin install failed", uninstall: "Plugin uninstall failed",
               enable: "Plugin enable failed", disable: "Plugin disable failed" })[root.mode]
    root.notify(t, root.pluginName + ": " + reason)
    root.close()
  }

  // Run once all validation inputs are in; executes the requested action
  // immediately (no confirmation UI).
  function tryStart() {
    if (root.actionStarted) return
    if (root.catalogError.length > 0) { root.fail(root.catalogError); return }
    if (root.listError.length > 0) { root.fail(root.listError); return }
    if (root.mode === "install" && root.manifestError.length > 0) {
      root.fail(root.manifestError)
      return
    }
    if (!root.catalogLoaded) return
    if (!root.manifestLoaded) return
    if (root.mode !== "install" && !root.listChecked) return

    root.actionStarted = true
    if (root.mode === "install") {
      root.stage = "installing"
      addProc.command = ["omarchy", "plugin", "add", root.pluginRepo, "--yes"]
      addProc.running = true
    } else if (root.mode === "enable") {
      root.enable("")
    } else if (root.mode === "disable") {
      root.runDisable()
    } else {
      root.runUninstall()
    }
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
    root.stage = "removing"
    removeProc.command = ["omarchy", "plugin", "remove", root.pluginId, "--yes"]
    removeProc.running = true
  }

  function runDisable() {
    root.stage = "disabling"
    disableProc.command = ["omarchy", "plugin", "disable", root.pluginId]
    disableProc.running = true
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
        root.tryStart()
      }
    }
    onExited: function (exitCode) {
      if (exitCode !== 0 && !root.catalogLoaded) {
        root.catalogError = "Marketplace catalog could not be fetched"
        root.catalogLoaded = true
        root.tryStart()
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
          } else if (root.mode === "uninstall" && String(m.id) === "dev.bram.plugin-installer") {
            root.manifestError = "The installer cannot uninstall itself. Remove it in a terminal: omarchy plugin remove dev.bram.plugin-installer --yes"
          } else {
            root.pluginManifest = m
          }
        }
        root.manifestLoaded = true
        root.tryStart()
      }
    }
    onExited: function (exitCode) {
      if (exitCode !== 0 && !root.manifestLoaded) {
        root.manifestError = "Plugin manifest.json could not be fetched"
        root.manifestLoaded = true
        root.tryStart()
      }
    }
  }

  // Local state check for uninstall/enable/disable; gates the action.
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
          root.listError = "Plugin is not installed as a user plugin; nothing to do"
        } else if (root.mode === "enable" && entry.enabled) {
          root.listError = "Plugin is already enabled"
        } else if (root.mode === "disable" && !entry.enabled) {
          root.listError = "Plugin is already disabled"
        }
        root.listChecked = true
        root.tryStart()
      }
    }
    onExited: function (exitCode) {
      if (exitCode !== 0 && !root.listChecked) {
        root.listError = "Could not read the local plugin list"
        root.listChecked = true
        root.tryStart()
      }
    }
  }

  // ---- actions --------------------------------------------------------------

  Process {
    id: addProc
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.installOutput = String(text || "") }
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: root.installOutput += "\n" + String(text || "") }
    onExited: function (exitCode) {
      if (exitCode !== 0) {
        root.fail("omarchy plugin add exited with code " + exitCode)
        return
      }
      root.enable("")
    }
  }

  Process {
    id: enableProc
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.installOutput += "\n" + String(text || "") }
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: root.installOutput += "\n" + String(text || "") }
    onExited: function (exitCode) {
      if (exitCode !== 0) {
        root.fail("omarchy plugin enable exited with code " + exitCode)
        return
      }
      var where = root.enabledSection ? " on the bar (" + root.enabledSection + " section)" : ""
      root.notify(root.mode === "install" ? "Plugin installed" : "Plugin enabled",
                  root.pluginName + " is enabled" + where)
      root.close()
    }
  }

  Process {
    id: removeProc
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.installOutput += "\n" + String(text || "") }
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: root.installOutput += "\n" + String(text || "") }
    onExited: function (exitCode) {
      if (exitCode !== 0) {
        root.fail("omarchy plugin remove exited with code " + exitCode)
        return
      }
      root.notify("Plugin uninstalled", root.pluginName + " was removed and disabled")
      root.close()
    }
  }

  Process {
    id: disableProc
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.installOutput += "\n" + String(text || "") }
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: root.installOutput += "\n" + String(text || "") }
    onExited: function (exitCode) {
      if (exitCode !== 0) {
        root.fail("omarchy plugin disable exited with code " + exitCode)
        return
      }
      root.notify("Plugin disabled",
                  root.pluginName + " is disabled. Enable it again from the plugin page")
      root.close()
    }
  }

  // ---- UI -----------------------------------------------------------------

  // All chrome below is painted from the Omarchy theme (qs.Commons: the
  // active theme's palette + typography/spacing/rounding tokens; qs.Ui: the
  // shared BorderSurface), so the wizard follows theme switches instantly.
  // The overlay is a progress indicator only: the action runs by itself and
  // the result arrives as a desktop notification.

  component PiLine: Text {
    width: cardColumn.width
    wrapMode: Text.Wrap
    color: Util.alpha(Color.foreground, 0.75)
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
      color: Qt.rgba(0, 0, 0, 0.65)
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.close()
    }

    BorderSurface {
      id: card
      anchors.centerIn: parent
      width: Math.min(Style.space(460), panel.width - Style.space(48))
      height: Math.min(cardColumn.implicitHeight + Style.space(48),
                       panel.height - Style.space(48))
      clip: true
      radius: Style.cornerRadius
      color: Color.popups.background
      borderSpec: Border.flat(Color.accent, Style.normalBorderWidth)
      padding: Style.space(24)

      // Swallow clicks over the card so the scrim MouseArea below doesn't close.
      MouseArea { anchors.fill: parent; onClicked: {} }

      Column {
        id: cardColumn
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: Style.spacing.panelGap

        Text {
          width: parent.width
          text: root.title
          color: Color.foreground
          font.family: Style.font.family
          font.bold: true
          font.pixelSize: Style.font.heading
        }
        PiLine {
          text: root.pluginName + "  \u00b7  " + root.pluginId
          color: Color.foreground
          font.bold: true
          font.pixelSize: Style.font.title
        }

        PiLine {
          visible: root.stage === "validating"
          text: "Validating the request against the marketplace\u2026"
        }
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
          visible: root.stage === "removing"
          text: "Removing the plugin\u2026"
        }
        PiLine {
          visible: root.stage === "disabling"
          text: "Disabling the plugin\u2026"
        }
      }
    }
  }
}
