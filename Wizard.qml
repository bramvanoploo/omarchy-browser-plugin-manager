import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui

// Plugin Installer wizard overlay.
// Summoned by the native messaging host (browser button click) with payload
// {mode, id, repo, name}. The payload is treated as a hint only: the catalog
// entry and the repository manifest are re-fetched and cross-checked before
// anything is displayed, and the user confirms the action in this overlay.
// When the action finishes, the result is a desktop notification only: no
// completion dialog is shown and the overlay closes itself.

Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  property bool opened: false
  // review | enable-confirm | disable-confirm | uninstall-confirm
  // | enabling | placement | disabling
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

  // enableProc's own output, reset per attempt, so a discovery-race failure
  // is detected from this run rather than from accumulated output.
  property string enableOutput: ""
  // Detached worker for install/uninstall (see spawnWorker).
  property string workerFile: ""
  property string workerContent: ""
  property bool isBarWidget: false
  property string defaultSection: "center"
  property string enabledSection: ""
  property int enableTries: 0
  property bool finalCheck: false

  readonly property var manifestKinds: pluginManifest && pluginManifest.kinds
    ? pluginManifest.kinds : []

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
    enableOutput = ""
    isBarWidget = false
    defaultSection = "center"
    enabledSection = ""
    enableTries = 0
    finalCheck = false

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

  function shortSha(sha) {
    return /^[a-f0-9]{40}$/i.test(sha || "") ? sha.slice(0, 7) : "unknown"
  }

  function notify(title, body) {
    Quickshell.execDetached([
      root.omarchyPath + "/bin/omarchy-notification-send", title, body
    ])
  }

  // The action failed: report it as a notification and close; no dialog.
  function fail(reason) {
    var t = ({ install: "Plugin install failed", uninstall: "Plugin uninstall failed",
               enable: "Plugin enable failed", disable: "Plugin disable failed" })[root.mode]
    root.notify(t, root.pluginName + ": " + reason)
    root.close()
  }

  function install() {
    if (!root.canInstall) return
    root.spawnWorker("install")
  }

  function enable(section) {
    root.enabledSection = section
    root.enableOutput = ""
    console.log("pi: enable start", root.pluginId, "tries", root.enableTries, "finalCheck", root.finalCheck)
    root.stage = "enabling"
    var args = ["omarchy", "plugin", "enable", root.pluginId]
    if (section) args = args.concat(["--section", section])
    enableProc.command = args
    enableProc.running = true
  }

  function runUninstall() {
    if (root.catalogError.length > 0) return
    root.spawnWorker("uninstall")
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
      }
    }
    onExited: function (exitCode) {
      if (exitCode !== 0 && !root.catalogLoaded) {
        root.catalogError = "Marketplace catalog could not be fetched"
        root.catalogLoaded = true
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
      }
    }
    onExited: function (exitCode) {
      if (exitCode !== 0 && !root.manifestLoaded) {
        root.manifestError = "Plugin manifest.json could not be fetched"
        root.manifestLoaded = true
      }
    }
  }

  // Local state check for uninstall/enable/disable: validates and, when the
  // plugin is in the right state, moves to the mode's confirm stage.
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

  // Every action ends in a notification + close; there is no completion
  // stage. ---- install / uninstall (detached workers) ----------------------
  // Install/uninstall touch the watched plugins directory: the clone (or
  // removal) event makes the shell reload all plugins, which destroys this
  // wizard overlay and kills the Processes it owns mid-action. These two
  // actions therefore run as a detached bash worker that outlives the
  // wizard: it performs the CLI work, retries the enable through the
  // shell's post-clone discovery race ("is not known"), verifies the end
  // state, and finishes with the usual desktop notification.

  function shellQuote(value) {
    return "'" + String(value).replace(/'/g, "'\\''") + "'"
  }

  function runtimeDir() {
    var base = Quickshell.env("XDG_RUNTIME_DIR")
    if (!base) base = "/tmp"
    return base + "/omarchy-plugin-installer"
  }

  function buildWorkerScript(kind) {
    var q = root.shellQuote
    var s = [
      "#!/usr/bin/env bash",
      "set -u",
      "ID=" + q(root.pluginId),
      "NAME=" + q(root.pluginName),
      "REPO=" + q(root.pluginRepo),
      "trap 'rm -f \"$0\"' EXIT",
      "notify() {",
      "  omarchy-notification-send --app-name omarchy-plugin-installer --expire-time 8000 \"$1\" \"$2\"",
      "}",
      "list() { omarchy plugin list --json 2>/dev/null; }",
      "enabled() { list | jq -e --arg id \"$ID\" 'any(.[]; .id == $id and .enabled == true)' >/dev/null 2>&1; }",
      "OUT=''"
    ]
    if (kind === "install") {
      s = s.concat([
        "if ! OUT=\"$(omarchy plugin add \"$REPO\" --enable --yes 2>&1)\"; then",
        "  # The clone can land while the add's internal enable fails; only",
        "  # re-add when the plugin directory did not arrive.",
        "  if [ ! -d \"$HOME/.config/omarchy/plugins/$ID\" ]; then",
        "    if ! OUT=\"$(omarchy plugin add \"$REPO\" --yes 2>&1)\"; then",
        "      notify \"Plugin install failed\" \"$NAME: $OUT\"",
        "      exit 1",
        "    fi",
        "  fi",
        "fi",
        "# The clone storm triggers a shell-wide rescan that can keep the",
        "# fresh plugin unknown (\"is not known\") well past the add's 2s",
        "# discovery window; wait for discovery, then enable (the shell IPC",
        "# is idempotent) until the state reads enabled.",
        "for _ in $(seq 1 15); do enabled && break; sleep 1; done",
        "for _ in $(seq 1 10); do",
        "  enabled && break",
        "  OUT=\"$(omarchy plugin enable \"$ID\" 2>&1)\"",
        "  sleep 1",
        "done",
        "if enabled; then",
        "  # The scan's config sweep re-persists shell.json from the",
        "  # registry snapshot seconds later and can revert the fresh",
        "  # enable; re-check after the sweep and re-enable once if it did.",
        "  sleep 3",
        "  if ! enabled; then",
        "    omarchy plugin enable \"$ID\" >/dev/null 2>&1",
        "    sleep 2",
        "  fi",
        "fi",
        "if enabled; then",
        "  notify \"Plugin installed\" \"$NAME is installed and enabled.\"",
        "else",
        "  notify \"Plugin install incomplete\" \"$NAME was installed but failed to enable. Retry: omarchy plugin enable $ID\"",
        "fi"
      ])
    } else {
      s = s.concat([
        "if ! OUT=\"$(omarchy plugin remove \"$ID\" --yes 2>&1)\"; then",
        "  notify \"Plugin uninstall failed\" \"$NAME: $OUT\"",
        "  exit 1",
        "fi",
        "notify \"Plugin uninstalled\" \"$NAME has been removed.\""
      ])
    }
    return s.join("\n") + "\n"
  }

  function spawnWorker(kind) {
    var dir = root.runtimeDir()
    var safeId = root.pluginId.replace(/[^A-Za-z0-9._-]/g, "-")
    root.workerFile = dir + "/worker-" + kind + "-" + safeId
      + "-" + Math.floor(Date.now() / 1000) + ".sh"
    root.workerContent = root.buildWorkerScript(kind)
    // Content travels as a positional argument: no shell quoting needed.
    writeProc.command = ["bash", "-c",
      'mkdir -p "$0" && printf %s "$1" > "$2"',
      dir, root.workerContent, root.workerFile]
    writeProc.running = true
  }

  Process {
    id: writeProc
    onExited: function (exitCode) {
      if (exitCode !== 0) {
        root.fail("worker script could not be written (exit " + exitCode + ")")
        return
      }
      Quickshell.execDetached(["bash", root.workerFile])
      root.close()
    }
  }

  Process {
    id: enableProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.enableOutput += "\n" + String(text || "")
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.enableOutput += "\n" + String(text || "")
    }
    onExited: function (exitCode) {
      console.log("pi: enableProc exit", exitCode)
      if (exitCode !== 0) {
        // Same discovery race as the add's internal enable: the shell's
        // registry scan may not have reached the fresh clone yet. Retry
        // within the shared enableTries budget; the enable IPC is idempotent.
        if (root.enableTries < 8 && /is not known/.test(root.enableOutput)) {
          root.enableTries++
          console.log("pi: enable not known, retry", root.enableTries)
          enableRetryTimer.restart()
          return
        }
        root.fail("omarchy plugin enable exited with code " + exitCode)
        return
      }
      // Confirm the state is live: the shell's plugin-file watcher (150ms
      // debounce, storming during a clone) can persist shell.json from a
      // snapshot that predates the enable IPC and revert the flag.
      root.runVerify()
    }
  }

  // Poll the live plugin list; on divergence re-run the enable (the shell
  // IPC is idempotent), up to enableTries times, then fail loudly. Once the
  // state reads enabled, re-check once after 2.5s: the shell's plugin scan
  // finishes seconds after a clone and its sync sweep persists shell.json
  // from the registry snapshot, which can drop the fresh entry — the final
  // check lands after that sweep and re-enables if it did.
  function runVerify() {
    verifyProc.running = true
  }

  Timer {
    id: enableRetryTimer
    interval: 700
    onTriggered: enableProc.running = true
  }

  Timer {
    id: finalVerifyTimer
    interval: 2500
    onTriggered: verifyProc.running = true
  }

  Process {
    id: verifyProc
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
        console.log("pi: verify enabled", entry ? entry.enabled : "no-entry", "finalCheck", root.finalCheck, "tries", root.enableTries)
        if (entry && entry.enabled) {
          if (!root.finalCheck) {
            root.finalCheck = true
            finalVerifyTimer.restart()
            return
          }
          var where = root.enabledSection
            ? " on the bar (" + root.enabledSection + " section)"
            : root.isBarWidget ? " on the bar (" + root.defaultSection + " section)" : ""
          root.notify(root.mode === "install" ? "Plugin installed" : "Plugin enabled",
                      root.pluginName + " is enabled" + where)
          root.close()
        } else if (root.enableTries >= 8) {
          root.fail("plugin is not enabled after repeated enable attempts (the shell config reverted it)")
        } else {
          root.finalCheck = false
          root.enableTries++
          enableRetryTimer.restart()
        }
      }
    }
    onExited: function (exitCode) {
      if (exitCode !== 0) root.fail("omarchy plugin list exited with code " + exitCode)
    }
  }

  Process {
    id: disableProc
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.enableOutput += "\n" + String(text || "") }
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: root.enableOutput += "\n" + String(text || "") }
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
  // After an action finishes, a notification is sent and this overlay closes;
  // it never shows a completion screen.

  component PiButton: BorderSurface {
    id: piButton
    property string label: ""
    property bool primary: false
    property bool danger: false
    readonly property color tone: danger
      ? Color.urgent
      : primary ? Color.accent : Color.foreground
    readonly property bool hot: piMouse.containsMouse
    signal clickedPi

    width: labelText.implicitWidth + Style.space(36)
    height: Style.space(34)
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
      id: labelText
      anchors.centerIn: parent
      text: piButton.label
      color: piButton.enabled
        ? (piButton.primary || piButton.danger ? piButton.tone : Color.foreground)
        : Util.alpha(Color.foreground, 0.35)
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
      width: Math.min(Style.space(560), panel.width - Style.space(48))
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
          text: ({ install: "Install plugin", uninstall: "Uninstall plugin",
                   enable: "Enable plugin", disable: "Disable plugin" })[root.mode]
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

        // ---- stage: review (install confirmation) ----
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
            color: Color.accent
            text: "Installs the repository's current HEAD, which may differ from the verified snapshot."
          }
          PiLine {
            visible: root.reviewBlocked.length > 0
            color: Color.urgent
            text: root.reviewBlocked
          }
        }

        // ---- stages: mode confirmations ----
        PiLine {
          visible: root.stage === "uninstall-confirm"
          text: "Installed as a user plugin. Uninstalling removes the plugin files, "
            + "disables it, and removes its bar layout entry."
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

        // ---- stages: in progress ----
        PiLine {
          visible: root.stage === "enabling"
          text: "Enabling the plugin\u2026"
          + (root.enabledSection ? " (bar section: " + root.enabledSection + ")" : "")
        }
        PiLine {
          visible: root.stage === "disabling"
          text: "Disabling the plugin\u2026"
        }

        // ---- stage: placement (enable mode, bar widgets) ----
        Column {
          visible: root.stage === "placement"
          width: cardColumn.width
          spacing: Style.spacing.rowGap
          PiLine {
            text: "Where should the bar icon go?"
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

        Item { width: 1; height: Style.spacing.xs }

        // ---- footer: confirm / cancel ----
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
            visible: root.stage === "review" || root.stage === "uninstall-confirm"
              || root.stage === "enable-confirm" || root.stage === "disable-confirm"
            label: "Cancel"
            onClickedPi: root.close()
          }
        }
      }
    }
  }
}
