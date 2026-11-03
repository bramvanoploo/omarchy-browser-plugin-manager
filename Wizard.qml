import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui

// Omarchy Browser Plugin Manager wizard overlay.
// Summoned by the native messaging host (browser button click) or by the
// bar widget's dropdown with payload {mode, id, repo, name}; the modes are
// install / uninstall / enable / disable (host) and update (bar widget).
// The payload is treated as a hint only: the catalog
// entry and the repository manifest are re-fetched and cross-checked before
// anything is displayed, and the user confirms the action in this overlay.
// Installing a bar widget adds a placement step: a horizontal grid offers
// every bar section the shell knows (Util.barSections); the manifest's
// default section is labelled "(default)" and styled as the primary action,
// and the install worker enables the plugin with the section chosen. Nothing
// is installed yet at that point, so Cancel is a plain close.
// When the action finishes, the result is a desktop notification only: no
// completion dialog is shown and the overlay closes itself.
// Exception: finishing an install of this manager itself summons the
// browser-extension prompt (once, via the install worker). The Omarchy plugin
// is only half the system; the Install buttons in the browser come from the
// matching browser extension.
// The prompt detects the default browser, sends the user to the Firefox
// add-on page (addons.mozilla.org) for Firefox-based browsers, or to the
// Chrome Web Store page for Chromium-based ones, and explains what happens
// there and why. Cancelling shows a follow-up stage: the plugin does nothing
// without its browser extension, with options to open the extension page,
// cancel, or uninstall the Omarchy plugin (detached worker, since removing
// this plugin unloads the wizard).
// The native messaging host registration is automated: registering on every
// load is idempotent, the uninstall worker unregisters before removing the
// plugin, and a destruction-time watcher unregisters after a terminal
// removal (self-cleanup copy parked in the state dir).

Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  // Directory this overlay was loaded from (the installed plugin folder),
  // as a filesystem path: the plugin's bin/ scripts live next to Wizard.qml.
  readonly property string pluginDir: {
    var u = String(Qt.resolvedUrl("."))
    return u.startsWith("file://") ? decodeURIComponent(u.slice(7)) : u
  }

  // This manager plugin's own id: the browser-extension prompt targets its
  // own extension, never the plugin passed in the payload.
  readonly property string managerId: (root.manifest && root.manifest.id)
    ? String(root.manifest.id) : "bramvanoploo.omarchy-browser-plugin-manager"

  // Browser extension pages: Firefox-based browsers install the add-on from
  // AMO; Chromium-based browsers that support Chrome Web Store extensions
  // install from the CWS listing page (store-assigned item id URL).
  readonly property string amoUrl:
    "https://addons.mozilla.org/nl/firefox/addon/omarchy-browser-plugin-manager/"
  readonly property string cwsUrl:
    "https://chromewebstore.google.com/detail/nalcgjmbglkcmohokidcmogcbpmhkdjf"

  // Default browser (.desktop id) behind the extension prompt; detected
  // when the prompt opens, empty when detection failed (fallback: Firefox).
  property string defaultBrowserId: ""
  property bool defaultBrowserLoaded: false

  property bool opened: false
  // review | enable-confirm | disable-confirm | uninstall-confirm
  // | update-confirm | enabling | placement | disabling
  // | browser-prompt | browser-defer | running
  property string stage: "review"

  property string pluginId: ""
  property string pluginRepo: ""
  property string pluginName: ""
  // "install" (default) | "uninstall" | "enable" | "disable" | "update"
  // | "running" — decided by the native host from live local state, never
  // by the page. "running" is the in-progress system panel: summoned by a
  // detached worker, it shows the themed globe animation until the worker's
  // marker file lands in the state dir's in-progress/ directory disappears.
  property string mode: "install"

  // Running-stage state: the action ("install" | "uninstall" | "update"),
  // the display target (plugin name, or a batch summary like "3 plugins"),
  // the rotating caption index, and the epoch ms the panel opened.
  property string runningAction: "install"
  property string runningName: ""
  property int runningCaption: 0
  property real runningT0: 0

  // Settings mode: the bar widget publishes a settings snapshot (settings,
  // check state, update lists) to settings-payload.json and dispatches
  // commands this overlay writes to settings-cmd.json; the widget owns
  // settings.json, the catalog poll, and the detached workers.
  // settingsConfirm arms the settings-confirm stage (update/uninstall).
  property var settingsSnap: null
  // Keys patched by a click with the value the click chose. The widget
  // republishes snapshots on its own cadence, and a click takes up to a
  // second to land (cmd poll, apply, republish, this reload), so an
  // incoming snapshot that has not caught up must not repaint the control
  // back to the pre-click value: pending values are re-asserted over every
  // snapshot until one confirms them, which retires it.
  property var settingsPending: ({})
  property var settingsConfirm: null
  readonly property string settingsPayloadPath: stateDir + "/settings-payload.json"
  readonly property string settingsCmdPath: stateDir + "/settings-cmd.json"

  property bool catalogLoaded: false
  property bool manifestLoaded: false
  property var catalogEntry: null
  property var pluginManifest: null
  property string catalogError: ""
  property string manifestError: ""

  // enableProc's own output, reset per attempt, so a discovery-race failure
  // is detected from this run rather than from accumulated output.
  property string enableOutput: ""
  property bool isBarWidget: false
  property string defaultSection: "centerEnd"
  property string enabledSection: ""
  property int enableTries: 0
  property bool finalCheck: false

  // Update pinning: the marketplace catalog pins each verified plugin to the
  // reviewed commit (verificationCommit). The update worker fast-forwards to
  // exactly that commit and fails closed when upstream has advanced past it,
  // mirroring the bar widget's poll and updater (BarWatch.qml). The shared
  // settings.json (same file the bar widget's settings panel writes) carries
  // the allowUnverified opt-in that permits unpinned updates.
  readonly property string stateDir: {
    var base = Quickshell.env("XDG_STATE_HOME")
    if (!base) base = (Quickshell.env("HOME") || "/tmp") + "/.local/state"
    return base + "/omarchy/" + root.managerId
  }
  readonly property string settingsPath: stateDir + "/settings.json"
  property bool allowUnverified: false

  function applySettings(raw) {
    var value = false
    try {
      var d = JSON.parse(String(raw || ""))
      if (d && typeof d.allowUnverified === "boolean")
        value = d.allowUnverified
    } catch (e) {
      value = false
    }
    root.allowUnverified = value
  }

  // The catalog's reviewed commit for this plugin; empty when the plugin is
  // not verified (missing entry, unverified status, no/short pin).
  readonly property string updateVerifiedSha: {
    var e = root.catalogEntry
    if (!e || String(e.verificationStatus) !== "verified") return ""
    var sha = String(e.verificationCommit || "")
    return /^[a-f0-9]{40}$/.test(sha) ? sha : ""
  }

  // Unverified update under the default verified-only policy: block the
  // action with an explanation until the user opts in via the bar widget's
  // settings toggle.
  readonly property string updateVerifyBlocked: {
    if (root.mode !== "update" || !root.catalogLoaded || !root.catalogEntry)
      return ""
    if (root.updateVerifiedSha.length > 0 || root.allowUnverified)
      return ""
    return "This plugin's latest upstream commit is no longer the commit a "
      + "marketplace maintainer reviewed, so an update would install "
      + "unreviewed code. Allow unverified updates in the plugin manager's "
      + "bar widget settings to proceed."
  }

  readonly property var manifestKinds: pluginManifest && pluginManifest.kinds
    ? pluginManifest.kinds : []

  readonly property bool needsManifest: root.mode === "install" || root.mode === "enable"

  readonly property string reviewBlocked: {
    if (catalogError.length > 0) return catalogError
    if (updateVerifyBlocked.length > 0) return updateVerifyBlocked
    if (needsManifest && manifestError.length > 0) return manifestError
    if (!catalogLoaded) return "Loading marketplace data\u2026"
    if (needsManifest && !manifestLoaded) return "Loading marketplace data\u2026"
    return ""
  }
  readonly property bool canAct: reviewBlocked.length === 0
  readonly property bool canInstall: canAct && stage === "review"

  // Header subtitle: the action this dialog performs, under the plugin
  // identity (name + version pill).
  readonly property string headerSubtitle: {
    if (root.stage === "browser-prompt" || root.stage === "browser-defer")
      return "Browser extension setup"
    if (root.stage === "placement")
      return (root.mode === "enable" ? "Enable plugin" : "Install plugin")
        + " \u2014 choose bar section"
    if (root.stage === "enabling") return "Enabling plugin\u2026"
    if (root.stage === "disabling") return "Disabling plugin\u2026"
    if (root.stage === "running")
      return (root.runningAction === "uninstall" ? "Uninstalling plugin"
        : root.runningAction === "update" ? "Updating plugin"
        : "Installing plugin") + "\u2026"
    if (root.stage === "settings")
      return "Settings \u00b7 updates every " + root.settingsPollLabel()
        + (root.snapBool("updateChecking") ? "  \u00b7  checking\u2026"
          : root.snapStr("lastCheckText") !== "never"
            && root.snapStr("lastCheckText") !== ""
            ? "  \u00b7  last check " + root.snapStr("lastCheckText") : "")
    if (root.stage === "settings-confirm")
      return root.settingsConfirm && root.settingsConfirm.kind === "uninstall"
        ? "Confirm uninstall" : "Confirm update"
    var action = ({ install: "Install plugin", uninstall: "Uninstall plugin",
                    enable: "Enable plugin", disable: "Disable plugin",
                    update: "Update plugin" })[root.mode]
    return action || "Plugin setup"
  }

  function stopPending() {
    enableRetryTimer.stop()
    finalVerifyTimer.stop()
    markerTimer.stop()
    catalogProc.running = false
    manifestProc.running = false
    listProc.running = false
    verifyProc.running = false
    enableProc.running = false
    disableProc.running = false
    browserProc.running = false
  }

  function validPluginId(id) {
    return /^[a-z0-9][a-z0-9.-]{0,127}$/.test(id || "") && String(id).indexOf("..") === -1
  }

  // xdg default-browser id -> which extension family it consumes. Firefox
  // forks (Waterfox, LibreWolf, Tor Browser, IceCat, Zen) take AMO add-ons;
  // Chromium forks (Chrome, Brave, Vivaldi, Edge, ...) take CWS extensions.
  // Unrecognised browsers fall back to the Firefox (AMO) listing.
  function browserFamily(desktopId) {
    var s = String(desktopId || "").toLowerCase()
    if (/(chrome|chromium|brave|vivaldi|opera|edge|iridium|yandex|slimjet|slimbrowser)/.test(s))
      return "chromium"
    return "firefox"
  }

  readonly property string extensionFamily: root.browserFamily(root.defaultBrowserId)
  readonly property string primaryExtensionUrl:
    root.extensionFamily === "chromium" ? root.cwsUrl : root.amoUrl
  readonly property string primaryExtensionLabel:
    root.extensionFamily === "chromium" ? "Open in Chrome Web Store" : "Open in Firefox Add-ons"
  readonly property string primaryStoreName:
    root.extensionFamily === "chromium" ? "Chrome Web Store" : "Firefox Add-ons"
  // The extension for the other browser family, offered as a link.
  readonly property string otherStoreName:
    root.extensionFamily === "chromium" ? "Firefox add-on" : "Chrome Web Store extension"
  readonly property string otherFamilyName:
    root.extensionFamily === "chromium" ? "Firefox browsers" : "Chromium browsers"
  readonly property string otherExtensionUrl:
    root.extensionFamily === "chromium" ? root.amoUrl : root.cwsUrl
  readonly property string otherLinkText:
    root.extensionFamily === "chromium" ? "Firefox Add-ons page" : "Chrome Web Store page"

  function openUrl(url) {
    Quickshell.execDetached(["xdg-open", String(url || "")])
  }

  // RichText ignores Text.linkColor (StyledText only), so links carry an
  // inline color style built from the theme accent.
  function cssHexChannel(v) {
    var h = Math.round(Math.max(0, Math.min(1, v)) * 255).toString(16)
    return h.length === 1 ? "0" + h : h
  }
  readonly property string accentCss: "#"
    + cssHexChannel(Color.accent.r) + cssHexChannel(Color.accent.g) + cssHexChannel(Color.accent.b)
  function linkTag(href, label) {
    return "<a href=\"" + href + "\" style=\"color: " + root.accentCss
      + "; text-decoration: underline;\">" + label + "</a>"
  }

  // Opens the extension page for the default browser and dismisses the prompt.
  function openExtensionPage() {
    root.openUrl(root.primaryExtensionUrl)
    root.close()
  }

  // Self-removal from the defer stage: removing this plugin reloads the
  // shell and destroys this overlay, so it runs as the same detached
  // uninstall worker used for normal uninstalls (the notification is its
  // completion report).
  function uninstallManager() {
    if (root.pluginId !== root.managerId) return
    root.spawnWorker("uninstall", "")
  }

  function open(payloadJson) {
    stopPending()

    var payload = {}
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }

    var newMode = String(payload.mode || "install")
    if (newMode !== "uninstall" && newMode !== "enable" && newMode !== "disable"
        && newMode !== "update" && newMode !== "running"
        && newMode !== "browser-prompt" && newMode !== "browser-defer"
        && newMode !== "settings" && newMode !== "settings-confirm") newMode = "install"
    // Stage before mode: the title binding chooses its source from stage, and
    // assigning a browser-* mode while the old stage is still a confirm stage
    // would index the title map with it (undefined -> "Unable to assign
    // [undefined] to QString").
    stage = (newMode === "browser-prompt" || newMode === "browser-defer"
      || newMode === "running" || newMode === "settings"
      || newMode === "settings-confirm")
      ? (newMode === "settings-confirm" ? "settings-confirm" : newMode) : "review"
    mode = newMode

    pluginId = String(payload.id || "")
    pluginRepo = String(payload.repo || "")
    pluginName = String(payload.name || pluginId)
    if (mode === "browser-prompt" || mode === "browser-defer") pluginId = managerId
    if (!pluginName) pluginName = String((root.manifest && root.manifest.name) || pluginId)

    catalogLoaded = false
    manifestLoaded = false
    catalogEntry = null
    pluginManifest = null
    catalogError = ""
    manifestError = ""
    enableOutput = ""
    isBarWidget = false
    defaultSection = "centerEnd"
    enabledSection = ""
    enableTries = 0
    finalCheck = false
    settingsConfirm = null

    opened = true

    runningT0 = Date.now()
    // Fresh read of the shared settings (allowUnverified) on every summon.
    settingsFile.reload()

    if (mode === "running") {
      // In-progress system panel summoned by a detached worker. No
      // marketplace data: the payload names the action and the target, and
      // the worker's marker file in stateDir/in-progress/ is the live
      // signal. The panel closes itself when no fresh marker remains (the
      // worker finished), leaving the completion notification on screen.
      // Checked before the id validation: batch workers (the bar widget's
      // update-all / multi-uninstall runs) carry a summary label like
      // "3 plugins" and no plugin id at all.
      catalogLoaded = true
      manifestLoaded = true
      runningAction = (payload.action === "uninstall" || payload.action === "update")
        ? String(payload.action) : "install"
      runningName = String(payload.name || pluginName || pluginId)
      runningCaption = 0
      runningT0 = Date.now()
      markerProc.running = true
      markerTimer.start()
      return
    }

    if (mode === "settings" || mode === "settings-confirm") {
      // Bar widget settings panel as a system overlay: the snapshot
      // arrives with the summon and keeps updating from the payload file
      // while the panel is open; every control writes a command file the
      // widget dispatches. No marketplace fetch: the widget already knows
      // everything the panel shows.
      catalogLoaded = true
      manifestLoaded = true
      pluginId = managerId
      pluginName = String((root.manifest && root.manifest.name) || managerId)
      settingsCmdQueue = []
      settingsPending = ({})
      // Drop any log a previous session left on disk: this panel is the
      // only producer, and the widget dedupes live commands by seq.
      root.settingsCmdWriteText = ""
      root.flushSettingsCmd()
      settingsSession = String(payload.session || "")
      settingsSnap = (payload.snapshot && typeof payload.snapshot === "object")
        ? payload.snapshot : settingsSnap
      // Announce the open panel: the widget's open flag can drift from
      // this overlay's real state (summoned after a shell reload, by the
      // worker, or on any path that did not route through the bar's own
      // toggle), and while it is stale the widget never polls commands:
      // every control bounces back to the pre-click snapshot. The
      // announcement (and the heartbeat in the snapshot poll below) makes
      // the widget adopt this session and open its side of the channel.
      root.writeSettingsCmd({ action: "panel_open" })
      if (mode === "settings-confirm") {
        settingsConfirm = (payload.confirm && typeof payload.confirm === "object")
          ? payload.confirm : null
        if (!settingsConfirm) {
          mode = "settings"
          stage = "settings"
        }
      }
      return
    }

    if (!validPluginId(pluginId)) {
      catalogError = "Invalid plugin identifier"
      catalogLoaded = true
      manifestLoaded = true
      return
    }

    var mUrl = manifestUrl()
    if (!mUrl) {
      catalogError = "Invalid plugin repository URL"
      catalogLoaded = true
      manifestLoaded = true
      return
    }

    if (mode === "browser-prompt" || mode === "browser-defer") {
      // No marketplace data needed: the prompt shows this manager's own
      // name/version (from the shell-loaded manifest) and the detected
      // default browser.
      catalogLoaded = true
      manifestLoaded = true
      defaultBrowserLoaded = false
      defaultBrowserId = ""
      browserProc.running = true
      return
    }

    catalogProc.running = true
    if (needsManifest) {
      manifestProc.command = ["curl", "-fsSL", "--proto", "=https", "--max-time", "15", "--", mUrl]
      manifestProc.running = true
    } else {
      manifestLoaded = true
    }
    if (mode === "uninstall" || mode === "enable" || mode === "disable" || mode === "update") listProc.running = true
  }

  function close() {
    // The registry invokes close() as the plugin's hide handler; hide() in
    // turn calls close(). Clearing `opened` first makes that re-entry a no-op.
    if (!root.opened) return
    root.opened = false
    if (root.mode === "settings" || root.mode === "settings-confirm")
      root.writeSettingsCmd({ action: "closed", session: root.settingsSession })
    root.stopPending()
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "bramvanoploo.omarchy-browser-plugin-manager")
  }

  // github.com/<owner>/<repo>[.git] -> owner/repo (empty when not parseable)
  function ownerRepo(url) {
    var match = /^https:\/\/github\.com\/([A-Za-z0-9._-]+)\/([A-Za-z0-9._-]+?)(\.git)?\/?$/.exec(url || "")
    if (!match) return ""
    var owner = match[1]
    var repo = match[2]
    if (owner === "." || owner === ".." || repo === "." || repo === "..") return ""
    return owner + "/" + repo
  }

  function manifestUrl() {
    var slug = ownerRepo(root.pluginRepo)
    if (!slug) return ""
    return "https://raw.githubusercontent.com/" + slug + "/HEAD/manifest.json"
  }

  function sameRepo(a, b) {
    var na = String(a || "").replace(/\/+$/, "").replace(/\.git$/, "")
    var nb = String(b || "").replace(/\/+$/, "").replace(/\.git$/, "")
    return na.length > 0 && na === nb
  }

  function shortSha(sha) {
    return /^[a-f0-9]{40}$/i.test(sha || "") ? sha.slice(0, 7) : "unknown"
  }

  function notify(title, body) {
    var cmd = root.omarchyPath
      ? root.omarchyPath + "/bin/omarchy-notification-send"
      : "omarchy-notification-send"
    // No "--" separator: omarchy-notification-send has no end-of-options
    // marker; a literal "--" becomes the headline and pushes the real text
    // into an invalid trailing-argument position (exit 1, no notification).
    Quickshell.execDetached([
      cmd,
      "--app-name", "omarchy-browser-plugin-manager",
      "--expire-time", "8000",
      String(title || ""),
      String(body || "")
    ])
  }

  // The action failed: report it as a notification and close; no dialog.
  function fail(reason) {
    var t = ({ install: "Plugin install failed", uninstall: "Plugin uninstall failed",
               enable: "Plugin enable failed", disable: "Plugin disable failed",
               update: "Plugin update failed" })[root.mode]
    root.notify(t, root.pluginName + ": " + reason)
    root.close()
  }

  function install() {
    if (!root.canInstall) return
    // Bar widgets get a placement step first; the chosen section is applied
    // by the worker via `omarchy plugin enable --section`.
    if (root.isBarWidget) root.stage = "placement"
    else root.spawnWorker("install", "")
  }

  // Called from the placement step in install mode with an explicit
  // section (from barPlacementSections); the manifest default is marked
  // "(default)" on its own button, so there is no separate "keep default"
  // path.
  // Bar sections offered in the placement stage: the shell's own section
  // list (Util.barSections). All six are placeable (omarchy-plugin-enable
  // accepts each); the center box hosts widgets beside the clock behind a
  // hover reveal, and a manifest's "center" default maps to centerEnd
  // exactly like omarchy-plugin-add does.
  readonly property var barPlacementSections: {
    return (typeof Util !== "undefined" && Array.isArray(Util.barSections))
      ? Util.barSections
      : ["left", "centerBegin", "center", "centerEnd", "right", "tray"]
  }
  function sectionLabel(section) {
    if (section === "left") return "Left"
    if (section === "centerBegin") return "Center begin"
    if (section === "center") return "Center"
    if (section === "centerEnd") return "Center end"
    if (section === "right") return "Right"
    if (section === "tray") return "Tray"
    return String(section)
  }

  function installWithSection(section) {
    if (root.mode !== "install" || root.stage !== "placement") return
    if (root.barPlacementSections.indexOf(section) === -1) return
    root.spawnWorker("install", section)
  }

  function enable(section) {
    root.enabledSection = section
    root.enableOutput = ""
    root.stage = "enabling"
    var args = ["omarchy", "plugin", "enable", root.pluginId]
    if (section) args = args.concat(["--section", section])
    enableProc.command = args
    enableProc.running = true
  }

  function runUninstall() {
    if (!root.canAct) return
    root.spawnWorker("uninstall", "")
  }

  // Update runs detached like install/uninstall: a git pull touches the
  // watched plugins directory, and updating the manager itself reloads the
  // shell and destroys this overlay. The verified commit (empty when the
  // unverified opt-in applies) rides in the section slot ($4) and pins the
  // worker's fast-forward; an empty pin runs the plain CLI update.
  function runUpdate() {
    if (!root.canAct) return
    root.spawnWorker("update", root.updateVerifiedSha)
  }

  function confirmEnable() {
    if (!root.canAct) return
    if (root.isBarWidget) root.stage = "placement"
    else root.enable("")
  }

  function runDisable() {
    if (!root.canAct) return
    root.enableOutput = ""
    root.stage = "disabling"
    disableProc.command = ["omarchy", "plugin", "disable", root.pluginId]
    disableProc.running = true
  }

  // ---- data fetching ------------------------------------------------------

  Process {
    id: catalogProc
    command: ["curl", "-fsSL", "--proto", "=https", "--max-time", "15", "--", "https://plugins.omarchy.org/catalog.json"]
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
          } else if (root.mode === "install"
                     && (!entry.installAvailable
                         || entry.upstreamCheckStatus === "failed"
                         || entry.builtIn
                         || !(entry.installCommand || ""))) {
            root.catalogError = "This plugin is not one-click installable ("
              + (entry.status || "unavailable") + ")"
          } else if (!root.sameRepo(root.pluginRepo, entry.repo)) {
            root.catalogError = "Repository mismatch between the request and the catalog; aborting"
          } else {
            // Clear first: a killed previous-run process can deliver a
            // stale onExited that sets catalogError after open() reset it.
            root.catalogError = ""
            root.catalogEntry = entry
            if (entry.name) root.pluginName = String(entry.name)
          }
        }
        root.catalogLoaded = true
      }
    }
    onExited: function (exitCode) {
      if (!root.opened) return
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
            // Clear first: a killed previous-run process can deliver a
            // stale onExited that sets manifestError after open() reset it.
            root.manifestError = ""
            root.pluginManifest = m
            root.isBarWidget = (m.kinds || []).indexOf("bar-widget") !== -1
            root.defaultSection = (m.barWidget
              && m.barWidget.defaultSection === "center") ? "centerEnd"
              : (m.barWidget && m.barWidget.defaultSection)
                ? String(m.barWidget.defaultSection) : "centerEnd"
          }
        }
        root.manifestLoaded = true
      }
    }
    onExited: function (exitCode) {
      if (!root.opened) return
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
        } else if (root.mode === "enable") {
          root.catalogError = ""
          root.stage = "enable-confirm"
        } else if (root.mode === "disable") {
          root.catalogError = ""
          root.stage = "disable-confirm"
        } else if (root.mode === "update") {
          root.catalogError = ""
          root.stage = "update-confirm"
        } else {
          root.catalogError = ""
          root.stage = "uninstall-confirm"
        }
      }
    }
    onExited: function (exitCode) {
      if (!root.opened) return
      if (exitCode !== 0 && root.stage === "review") {
        root.catalogError = "Could not read the local plugin list"
      }
    }
  }

  // ---- bar widget settings panel (settings mode) ------------------------
  // The widget publishes a snapshot to settings-payload.json and keeps
  // republishing while the panel is open; every control here writes a
  // command to settings-cmd.json, which the widget dispatches (it owns
  // settings.json, the catalog poll, and the detached workers). Confirm-
  // ing an update/uninstall hands the plugin ids over and switches to the
  // running stage: the workers' marker files drive the close, exactly
  // like the other actions.
  // Payload updates: FileView's file watch does not fire on external
  // writes in this environment, so the file is re-read on demand (600ms
  // while the settings panel is open); the reload's onLoaded applies the
  // snapshot. The bar republishes every 400ms, so the overlay stays
  // within about a second of the widget's state.
  Timer {
    interval: 600
    running: root.opened && (root.mode === "settings" || root.mode === "settings-confirm")
    repeat: true
    triggeredOnStart: true
    onTriggered: settingsPayloadFile.reload()
  }

  FileView {
    id: settingsPayloadFile
    path: root.settingsPayloadPath
    printErrors: false
    onLoaded: root.applySettingsSnapshot(String(text() || ""))
    onLoadFailed: root.applySettingsSnapshot("")
  }

  // Command file writer: FileView writes silently skip whenever its
  // in-memory text matches (file watches never fire on external writes
  // here, so its view of the file goes stale the moment the widget
  // consumes it), which made clicks and announcements vanish. The content
  // rides to the writer as a process argument. A stdin-fed `cat > file`
  // does not work: Quickshell keeps the stdin pipe open, cat never sees
  // EOF, the process hangs, and every later send is stuck behind it.
  // `printf '%s' "$1" | head -c $2` exits after exactly $2 bytes, so each
  // send is deterministic. A send that wants to start while the previous
  // one is still running is chained by the onFinished handler, so rapid
  // clicks never lose a command.
  Process {
    id: settingsCmdWriteProc
    command: ["sh", "-c",
      'mkdir -p "${1%/*}" && printf %s "$3" | head -c "$2" > "$1"',
      "sh", root.settingsCmdPath,
      // Byte bound: 3x the JS string length (each UTF-16 unit is at most
      // 3 UTF-8 bytes) plus one, so the bound is always above the real
      // byte count and printf's EOF ends the stream. The cap keeps the
      // argument under the kernel's per-arg limit.
      String(Math.min(65536, root.settingsCmdWriteText.length * 3 + 1)),
      root.settingsCmdWriteText]
    // Quickshell Process exposes its exit notification as the overridable
    // onExited handler (onFinished: is not a signal here: assigning it
    // fails the component load); the flush chain continues queued sends
    // from it.
    onExited: function (exitCode) {
      root.flushSettingsCmd()
    }
  }
  property string settingsCmdWriteText: ""
  property string settingsCmdStarted: "\u0000"

  function flushSettingsCmd() {
    if (settingsCmdWriteProc.running) return
    if (root.settingsCmdWriteText === root.settingsCmdStarted) return
    root.settingsCmdStarted = root.settingsCmdWriteText
    settingsCmdWriteProc.running = true
  }

  function applySettingsSnapshot(raw) {
    if (root.mode !== "settings" && root.mode !== "settings-confirm") return
    // Heartbeat: every snapshot poll also re-announces the open panel, so
    // a widget that restarted (its flag reset) adopts this session and the
    // command channel self-heals while the panel stays open.
    root.writeSettingsCmd({ action: "panel_open" })
    var d = null
    try { d = JSON.parse(raw) } catch (e) { /* keep the last good snapshot */ }
    if (!d || typeof d !== "object") return
    // Re-assert values the user just clicked: the widget applies commands
    // on its own cadence, and a snapshot that has not caught up must not
    // repaint a control back to its pre-click value. A snapshot that
    // confirms a pending value retires it.
    var p = root.settingsPending
    var keys = Object.keys(p)
    if (keys.length > 0) {
      var next = {}
      for (var k in p) next[k] = p[k]
      var retired = false
      for (var i = 0; i < keys.length; i++) {
        var key = keys[i]
        if (d[key] === next[key]) { delete next[key]; retired = true }
        else d[key] = next[key]
      }
      if (retired) root.settingsPending = next
    }
    root.settingsSnap = d
  }

  // The command file is an append log (one JSON object per line): clicks
  // can fire several commands back-to-back (a confirm action plus the
  // "closed" the panel sends when it shuts), and a single-slot file would
  // let a fast write clobber a command the widget has not polled yet. The
  // widget consumes (truncates) the file once it has dispatched a batch,
  // so the queue here only carries the commands written since.
  property var settingsCmdQueue: []
  // Bar-widget minted id of the current settings session, received with
  // the summon payload and echoed in the "closed" command so the widget
  // can tell a live close from a stale one left on disk.
  property string settingsSession: ""
  function writeSettingsCmd(obj) {
    var o = obj || {}
    o.seq = String(Date.now()) + "-"
      + String(Math.floor(Math.random() * 1e6))
    // Session stamp: the widget ignores commands from any other session,
    // so lines a previous panel left on disk can never replay.
    o.session = root.settingsSession
    settingsCmdQueue = settingsCmdQueue.concat([o])
    // Bound the in-memory log: the widget consumes (removes) the file
    // after dispatch, and consumed lines only inflate the rewrite.
    if (settingsCmdQueue.length > 60)
      settingsCmdQueue = settingsCmdQueue.slice(settingsCmdQueue.length - 60)
    root.settingsCmdWriteText = settingsCmdQueue.map(function (c) {
      return JSON.stringify(c)
    }).join("\n") + "\n"
    root.flushSettingsCmd()
  }

  function snapStr(key) {
    var s = root.settingsSnap || {}
    return String(s[key] === undefined || s[key] === null ? "" : s[key])
  }
  function snapBool(key) {
    var s = root.settingsSnap || {}
    return s[key] === true
  }
  function snapList(key) {
    var s = root.settingsSnap || {}
    return Array.isArray(s[key]) ? s[key] : []
  }
  function snapPatch(props) {
    var s = root.settingsSnap || {}
    var out = {}
    for (var k in s) out[k] = s[k]
    for (var k2 in props) out[k2] = props[k2]
    root.settingsSnap = out
  }
  // Mark a clicked value as pending (see settingsPending): kept over every
  // snapshot that has not confirmed it, retired by one that has.
  function markPending(key, value) {
    var p = {}
    for (var k in root.settingsPending) p[k] = root.settingsPending[k]
    p[key] = value
    root.settingsPending = p
  }
  function settingsPollLabel() {
    var vals = root.snapList("pollValues")
    var labels = root.snapList("pollLabels")
    var i = vals.indexOf(Number(root.snapStr("pollMinutes")))
    return i >= 0 && labels[i] ? String(labels[i]) : "1h"
  }
  function settingsEligibleRows() {
    var rows = root.snapList("verified").slice()
    if (root.snapBool("allowUnverified"))
      rows = rows.concat(root.snapList("unverified"))
    return rows
  }
  // Every offered row, for the "all up to date" line: unverified rows
  // count as pending even while the toggle hides them (the widget keeps
  // polling them; hiding is a preference, not a resolution).
  function settingsAllRows() {
    return root.snapList("verified").concat(root.snapList("unverified"))
  }

  // Mirrors the bar popup's updatesGroupVisible: true when the status
  // lines, batch button, or lists have anything to show, so the rule
  // under the toggles only paints when there is a group to separate.
  function settingsUpdatesGroupVisible() {
    return root.settingsAllRows().length > 0
      || root.snapBool("updateCheckFailed")
      || root.snapBool("settingsSaveFailed")
      || (!root.snapBool("updateChecking")
          && root.snapStr("lastCheckText") !== "never"
          && root.snapStr("lastCheckText") !== "")
  }
  function toggleAllowUnverified() {
    var next = !root.snapBool("allowUnverified")
    root.snapPatch({ allowUnverified: next })
    root.markPending("allowUnverified", next)
    root.writeSettingsCmd({ action: "set_allow_unverified", on: next })
  }
  function toggleNotifyUpdates() {
    var next = !root.snapBool("notifyUpdates")
    root.snapPatch({ notifyUpdates: next })
    root.markPending("notifyUpdates", next)
    root.writeSettingsCmd({ action: "set_notify_updates", on: next })
  }
  function setPollIntervalMinutes(m) {
    root.snapPatch({ pollMinutes: Number(m) })
    root.markPending("pollMinutes", Number(m))
    root.writeSettingsCmd({ action: "set_poll_interval", minutes: Number(m) })
  }
  function beginUpdateConfirm(rows) {
    if (!rows || rows.length === 0) return
    var single = rows.length === 1 ? rows[0] : null
    var text = single
      ? "Updates " + String(single.name) + " from " + String(single.from)
        + " to " + String(single.to)
        + (single.verified === true
          ? ". The plugin's git repository is fast-forwarded to exactly"
            + " the reviewed commit (the update fails if upstream advanced"
            + " past it); the bar reloads when the manager itself updates."
          : " (unverified version). The plugin's git repository is pulled;"
            + " the bar reloads when the manager itself updates.")
      : "Updates " + rows.length + " plugins: verified ones are"
        + " fast-forwarded to exactly the reviewed commits, unverified"
        + " ones are pulled; the bar reloads when the manager itself"
        + " updates."
    root.settingsConfirm = {
      kind: "update",
      ids: rows.map(function (r) { return String(r.id) }),
      names: rows.map(function (r) { return String(r.name) }),
      text: text
    }
    root.stage = "settings-confirm"
  }
  function beginUninstallConfirm(row) {
    root.settingsConfirm = {
      kind: "uninstall",
      ids: [String(row.id)],
      names: [String(row.name)],
      text: "Runs omarchy plugin remove on " + String(row.name) + ": deletes"
        + " its folder in ~/.config/omarchy/plugins (a symlinked dev"
        + " folder is only unlinked), unloads it from the shell, and drops"
        + " its bar icon. The catalog entry lets you reinstall it"
        + " afterwards."
    }
    root.stage = "settings-confirm"
  }
  function confirmSettingsAction() {
    var c = root.settingsConfirm
    if (!c) return
    var ids = (c.ids || []).map(String).filter(function (x) { return x !== "" })
    if (ids.length === 0) return
    root.writeSettingsCmd(c.kind === "uninstall"
      ? { action: "run_uninstall", ids: ids }
      : { action: "run_update", ids: ids })
    root.runningAction = c.kind === "uninstall" ? "uninstall" : "update"
    root.runningName = c.names && c.names.length === 1
      ? String(c.names[0]) : ids.length + " plugins"
    root.runningCaption = 0
    root.runningT0 = Date.now()
    root.stage = "running"
    markerProc.running = true
    markerTimer.start()
  }
  function cancelSettingsConfirm() {
    root.settingsConfirm = null
    root.stage = "settings"
  }

  // The bar widget's settings file (allowUnverified opt-in for updates).
  // Read-only here: the widget owns writes; the wizard reloads on open.
  FileView {
    id: settingsFile
    path: root.settingsPath
    printErrors: false
    onLoaded: root.applySettings(text())
    onLoadFailed: root.applySettings("")
  }

  // Keep the native messaging host registration in sync with the plugin's
  // presence: registering on every load is idempotent (the script rewrites
  // its manifests, pinned to the published extension IDs), so installing the
  // plugin in Omarchy is all that is needed; the uninstall worker runs the
  // script with --uninstall before the plugin directory is removed.
  Process {
    id: hostSetupProc
    command: ["bash", root.pluginDir + "/bin/plugin-installer-setup"]
    // Prints extension-loading guidance on registration; nothing to consume.
  }

  Component.onCompleted: {
    hostSetupProc.running = true
    // Re-open the running panel if a detached worker is still active
    // (the shell reload triggered by the install destroyed the panel).
    bootScanProc.running = true
  }

  // Self-cleanup: removing the plugin (terminal `omarchy plugin remove`)
  // destroys this overlay on the shell reload; a detached watcher checks a
  // few seconds later that the plugin folder really is gone (a plain reload
  // or disable leaves it in place) and then unregisters the native
  // messaging host via the standalone copy of the setup script that
  // registration parks in the state dir. The wizard-driven uninstall path
  // already unregisters in its worker before removing.
  Component.onDestruction: {
    Quickshell.execDetached(["bash", "-c",
      "sleep 3;"
      + " d=\"${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/bramvanoploo.omarchy-browser-plugin-manager\";"
      + " [ -d \"$d\" ] && exit 0;"
      + " s=\"${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/bramvanoploo.omarchy-browser-plugin-manager/plugin-installer-setup\";"
      + " [ -f \"$s\" ] && bash \"$s\" --uninstall >/dev/null 2>&1; true"])
  }

  // Default browser behind the extension prompt: xdg-settings and the
  // x-scheme-handler/https association answer the same question; each fills
  // in when the other has no answer. An empty result keeps the Firefox
  // fallback.
  Process {
    id: browserProc
    command: ["bash", "-c",
      "xdg-settings get default-web-browser 2>/dev/null"
      + " || xdg-mime query default x-scheme-handler/https 2>/dev/null || true"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.defaultBrowserId = String(text || "").trim()
        root.defaultBrowserLoaded = true
      }
    }
    onExited: function (exitCode) {
      if (!root.opened) return
      if (exitCode !== 0 && !root.defaultBrowserLoaded) {
        root.defaultBrowserId = ""
        root.defaultBrowserLoaded = true
      }
    }
  }

  // ---- running stage: in-progress system panel ---------------------------
  // Detached workers publish one marker file per run into
  // stateDir/in-progress/ and summon this overlay on mode "running". The
  // worker's EXIT trap removes the marker at the very end of the run: after
  // the install/uninstall/update finished, the result was verified (bar
  // placement re-applied when needed), and the desktop notification was
  // sent - so the panel keeps showing until the action has fully completed
  // (bar icon visible, or failure), and closes on the next poll tick, at
  // most a second after the worker exits.
  // Markers older than 15 minutes are stale (a worker killed without its
  // trap, e.g. a self-uninstall that destroyed this very overlay): they are
  // deleted and ignored so the panel never sticks.
  readonly property string markerDir: stateDir + "/in-progress"
  property bool markerSweepQueued: false

  readonly property var runningCaptionsInstall: [
    "Spinning up the plugin axis\u2026",
    "Deploying the bar widget into orbit\u2026",
    "Persuading the shell to share its bar\u2026",
    "Gravity will do the rest\u2026",
    "Counting satellites, not seconds\u2026",
    "Cloning at orbital speed\u2026",
    "Bribing the plugin scanner with patience\u2026",
    "The satellites are doing their very best\u2026"
  ]
  readonly property var runningCaptionsUninstall: [
    "Undocking the bar widget\u2026",
    "Reeling in the satellites\u2026",
    "Telling the shell to forget about it\u2026",
    "No hard feelings, plugin\u2026",
    "Uninstalling at orbital speed\u2026",
    "Deletion is forever, so choose well\u2026",
    "The satellites are drifting away\u2026"
  ]
  readonly property var runningCaptionsUpdate: [
    "Fast-forwarding the plugin\u2026",
    "Fetching orbit updates\u2026",
    "Rewinding to the verified commit\u2026",
    "Reading the changelog in zero-g\u2026",
    "Recalibrating the bar widget\u2026"
  ]

  function runningCaptionText() {
    var caps = root.runningAction === "uninstall" ? root.runningCaptionsUninstall
      : root.runningAction === "update" ? root.runningCaptionsUpdate
      : root.runningCaptionsInstall
    return caps[root.runningCaption % caps.length]
  }

  // Fresh marker entries from a marker-directory dump (newest last); stale
  // ones (over 15 minutes) queue a sweep. Shared by the running-stage poll
  // and the boot scan.
  function freshMarkerEntries(text) {
    var lines = String(text).split("\n")
    var now = Math.floor(Date.now() / 1000)
    var entries = []
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].trim()
      if (!line) continue
      var e = null
      try { e = JSON.parse(line) } catch (err) { continue }
      if (!e || typeof e.started !== "number") continue
      if (now - e.started > 900) { root.markerSweepQueued = true; continue }
      entries.push(e)
    }
    if (root.markerSweepQueued) {
      root.markerSweepQueued = false
      staleSweepProc.running = true
    }
    entries.sort(function (a, b) { return a.started - b.started })
    return entries
  }

  function onMarkers(text) {
    if (!root.opened || root.stage !== "running") return
    var entries = root.freshMarkerEntries(text)
    if (entries.length === 0) {
      // Every worker finished: the panel's job is done.
      root.close()
      return
    }
    var newest = entries[entries.length - 1]
    if (newest.name) root.runningName = String(newest.name)
    if (newest.mode === "uninstall" || newest.mode === "update")
      root.runningAction = String(newest.mode)
  }

  // Re-summon after a shell reload: installing a plugin makes the shell
  // rescan plugins, and that reload destroys the overlay mid-action (the
  // worker survives it: detached process, marker file on disk). When the
  // overlay is instantiated again by the reload, scan the marker directory
  // once; a fresh marker means an action is still running, so reopen the
  // running panel directly. The panel then polls as usual and closes when
  // the worker removes its marker - i.e. once the action is fully done and
  // verified, which is also the moment the bar icon appears.
  Process {
    id: bootScanProc
    command: ["bash", "-c",
      "for f in \"$1\"/*.json; do [ -e \"$f\" ] || exit 0; jq -c . \"$f\" 2>/dev/null; done",
      "bpm-boot", root.markerDir]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (root.opened) return
        var entries = root.freshMarkerEntries(String(text || ""))
        if (entries.length === 0) return
        var newest = entries[entries.length - 1]
        var payload = { source: "boot", mode: "running",
          id: String(newest.id || ""), name: String(newest.name || ""),
          action: String(newest.mode || "install") }
        root.open(JSON.stringify(payload))
      }
    }
  }

  Process {
    id: markerProc
    command: ["bash", "-c",
      "for f in \"$1\"/*.json; do [ -e \"$f\" ] || exit 0; jq -c . \"$f\" 2>/dev/null; done",
      "bpm-marker", root.markerDir]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onMarkers(String(text || ""))
    }
    onExited: {
      if (root.opened && root.stage === "running") markerTimer.restart()
    }
  }

  Timer {
    id: markerTimer
    interval: 1000
    onTriggered: markerProc.running = true
  }

  Process {
    id: staleSweepProc
    command: ["bash", "-c",
      "find \"$1\" -name '*.json' -mmin +15 -delete 2>/dev/null; true",
      "bpm-sweep", root.markerDir]
  }

  // Ported from the browser panel: a wireframe lat/lon globe on a sphere
  // tilted 23 degrees, spun on its axis, orthographically projected (depth
  // decides alpha). Two satellites ride inclined co-rotating orbits with
  // fading trails, hidden behind the globe; stars twinkle. On de-orbit
  // (uninstall) the satellites spiral inward and fade. All colors come from
  // the live shell palette, so the panel follows the Omarchy theme.
  function paintGlobe(ctx, W, H, t, escape, gridCol, dotCol, starCol, sats) {
    // Scene scale relative to the reference 120px-tall canvas: the globe
    // radius, stroke widths, and satellite dots all follow it, so callers
    // get a proportionally identical scene at any canvas size.
    var sc = H / 120
    var cx = W / 2, cy = H / 2, R = 34 * sc
    var tilt = 0.41, cosT = Math.cos(tilt), sinT = Math.sin(tilt)
    var rgba = function (c, a) {
      return "rgba(" + c[0] + "," + c[1] + "," + c[2] + "," + a.toFixed(3) + ")"
    }
    var project = function (x, y, z) {
      return {
        x: cx + R * x,
        y: cy - R * (y * cosT - z * sinT),
        z: y * sinT + z * cosT
      }
    }
    var depthAlpha = function (z, boost) {
      var a = z >= 0 ? 0.16 + 0.5 * z : 0.07
      return boost ? Math.min(1, a * 1.6) : a
    }
    var SATS = [
      { r: 1.4, i: 0.55, n: 0.6, w: 0.75, p: 0 },
      { r: 1.72, i: -0.9, n: 2.2, w: 0.5, p: 2 }
    ]
    var orbitPoint = function (s, th, grow) {
      var r = s.r * grow
      var x = r * Math.cos(th), y = 0, z = r * Math.sin(th)
      var ci = Math.cos(s.i), si = Math.sin(s.i)
      var y2 = y * ci - z * si, z2 = y * si + z * ci
      var cn = Math.cos(s.n), sn = Math.sin(s.n)
      return project(x * cn + z2 * sn, y2, -x * sn + z2 * cn)
    }
    var drawArc = function (pt, n, boost) {
      var prev = null
      for (var i = 0; i <= n; i++) {
        var p = pt(i / n)
        if (prev) {
          ctx.beginPath()
          ctx.moveTo(prev.x, prev.y)
          ctx.lineTo(p.x, p.y)
          ctx.strokeStyle = rgba(gridCol, depthAlpha((p.z + prev.z) / 2, boost))
          ctx.stroke()
        }
        prev = p
      }
    }
    ctx.clearRect(0, 0, W, H)
    var spin = t * 0.22
    for (var i = 0; i < 26; i++) {
      var sx = (i * 97 + 31) % W, sy = (i * 53 + 17) % H
      var dx = sx - cx, dy = sy - cy
      if (dx * dx + dy * dy < (R + 6) * (R + 6)) continue
      ctx.fillStyle = rgba(starCol, 0.18 + 0.15 * Math.sin(t * 1.3 + i * 2.1))
      ctx.fillRect(sx, sy, 1.4, 1.4)
    }
    ctx.beginPath()
    ctx.arc(cx, cy, R, 0, 6.2832)
    ctx.lineWidth = 1
    ctx.strokeStyle = rgba(gridCol, 0.28)
    ctx.stroke()
    var lats = [-60, -30, 0, 30, 60]
    for (var li = 0; li < lats.length; li++) {
      var lat = lats[li] * Math.PI / 180
      drawArc(function (f) {
        var lon = f * 6.2832 + spin
        return project(Math.cos(lat) * Math.sin(lon), Math.sin(lat),
          Math.cos(lat) * Math.cos(lon))
      }, 64, lats[li] === 0)
    }
    for (var mi = 0; mi < 6; mi++) {
      var lon0 = mi * Math.PI / 6
      drawArc(function (f) {
        var la = f * Math.PI - Math.PI / 2
        return project(Math.cos(la) * Math.sin(lon0 + spin), Math.sin(la),
          Math.cos(la) * Math.cos(lon0 + spin))
      }, 48, false)
    }
    for (var si2 = 0; si2 < SATS.length; si2++) {
      var s = SATS[si2]
      if (escape) continue
      var prev = null
      for (var j = 0; j <= 72; j++) {
        var p = orbitPoint(s, j / 72 * 6.2832, 1)
        if (prev) {
          ctx.beginPath()
          ctx.moveTo(prev.x, prev.y)
          ctx.lineTo(p.x, p.y)
          ctx.strokeStyle = rgba(gridCol, (p.z + prev.z) / 2 >= 0 ? 0.16 : 0.05)
          ctx.stroke()
        }
        prev = p
      }
    }
    if (sats === false) return
    for (var si3 = 0; si3 < SATS.length; si3++) {
      var s2 = SATS[si3]
      // Slow de-orbit: ~3.8s per satellite, offset in phase.
      var cyc = escape ? (t * 0.28 + s2.p * 1.4) % 3.8 : 0
      var grow = 1 - (escape ? 0.048 * cyc : 0)
      var fade = escape ? Math.max(0, 1 - cyc / 3.8) : 1
      var th = s2.p + s2.w * t
      var pt = orbitPoint(s2, th, grow)
      var pdx = pt.x - cx, pdy = pt.y - cy
      if (pt.z < 0 && pdx * pdx + pdy * pdy < R * R) continue
      for (var k = 10; k >= 1; k--) {
        var q = orbitPoint(s2, th - 0.05 * k,
          1 - (escape ? 0.048 * Math.max(cyc - 0.04 * k, 0) : 0))
        ctx.fillStyle = rgba(dotCol, 0.055 * (11 - k) * fade)
        ctx.fillRect(q.x - 0.75, q.y - 0.75, 1.5, 1.5)
      }
      ctx.beginPath()
      ctx.arc(pt.x, pt.y, 2.2 * 2.2 * fade * sc, 0, 6.2832)
      ctx.fillStyle = rgba(dotCol, 0.1 * fade)
      ctx.fill()
      ctx.beginPath()
      ctx.arc(pt.x, pt.y, 2.2 * fade * sc, 0, 6.2832)
      ctx.fillStyle = rgba(dotCol, 0.95 * fade)
      ctx.fill()
    }
  }

  // Palette color -> [r,g,b] 0..255 array for the canvas painter.
  function globeRgb(c) {
    return [Math.round(c.r * 255), Math.round(c.g * 255), Math.round(c.b * 255)]
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
  // Positional parameters ($1=id, $2=name, $3=repo, $4=bar section) are
  // passed directly via execve argv, avoiding temporary script files and
  // shell interpolation.

  function buildWorkerScript(kind) {
    var s = [
      "set -u",
      "export PATH=\"${OMARCHY_PATH:-/usr/share/omarchy}/bin:$PATH\"",
      "ID=\"$1\"",
      "NAME=\"$2\"",
      "REPO=\"$3\"",
      "SECTION=\"$4\"",
      "notify_cmd=\"${OMARCHY_PATH:-/usr/share/omarchy}/bin/omarchy-notification-send\"",
      "command -v \"$notify_cmd\" >/dev/null 2>&1 || notify_cmd=\"$(command -v omarchy-notification-send 2>/dev/null || echo omarchy-notification-send)\"",
      "notify() {",
      "  \"$notify_cmd\" --app-name omarchy-browser-plugin-manager --expire-time 8000 \"$1\" \"$2\"",
      "}",
      "list() { omarchy plugin list --json 2>/dev/null; }",
      "enabled() { list | jq -e --arg id \"$ID\" 'any(.[]; .id == $id and .enabled == true)' >/dev/null 2>&1; }",
      // The bar layout entry is the real placement record; a missing
      // user config means defaults are in use and nothing verifies it.
      "placed() {",
      "  local f=\"${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/shell.json\"",
      "  [ -n \"$SECTION\" ] || return 0",
      "  [ -f \"$f\" ] || return 0",
      "  jq -e --arg id \"$ID\" --arg s \"$SECTION\" '(.bar.layout[$s] // []) | any(.[]; .id == $id)' \"$f\" >/dev/null 2>&1",
      "}",
      "OUT=''",
      // In-progress system panel: publish a marker file (one per worker,
      // removed on any exit) and summon the wizard on the running stage.
      // The panel polls this directory and closes itself once no fresh
      // marker remains; staleness (15min) guards workers that died without
      // their EXIT trap.
      "STATE_DIR=\"${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/bramvanoploo.omarchy-browser-plugin-manager\"",
      "MARK_DIR=\"$STATE_DIR/in-progress\"",
      "mkdir -p \"$MARK_DIR\" 2>/dev/null || true",
      "MARK=\"$MARK_DIR/$$-$(date +%s)-${RANDOM:-0}.json\"",
      "trap 'rm -f \"$MARK\"' EXIT",
      "jq -cn --arg mode \"" + kind + "\" --arg id \"$ID\" --arg name \"$NAME\" '{mode:$mode,id:$id,name:$name,started:(now|floor)}' > \"$MARK\" 2>/dev/null || true",
      "PAYLOAD=$(jq -cn --arg id \"$ID\" --arg name \"$NAME\" --arg action \"" + kind + "\" '{source:\"worker\",mode:\"running\",id:$id,name:$name,action:$action}' 2>/dev/null)",
      "[ -n \"$PAYLOAD\" ] && omarchy-shell -q shell summon bramvanoploo.omarchy-browser-plugin-manager \"$PAYLOAD\" >/dev/null 2>&1 || true"
    ]
    if (kind === "update") {
      // Pinned, fail-closed update mirroring the bar widget's updater: with
      // a verified commit ($4), fast-forward the clone to exactly that sha,
      // validate it, and roll back on validation failure. Upstream advanced
      // past the pin leaves the plugin untouched. An empty pin is the
      // explicit unverified opt-in: the plain CLI update. --yes because the
      // user already confirmed in this dialog; the shell reloads the plugin
      // itself, and a manager update reloads the shell, so this worker is
      // detached like install/uninstall.
      s = s.concat([
        "export GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=true",
        "export GIT_SSH_COMMAND=\"${GIT_SSH_COMMAND:-ssh -oBatchMode=yes}\"",
        "EXPECTED=\"$4\"",
        "D=\"${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/$ID\"",
        "if [ -n \"$EXPECTED\" ]; then",
        "  if [ ${#EXPECTED} -ne 40 ] || [ -n \"${EXPECTED//[0-9a-f]/}\" ]; then",
        "    notify \"Plugin update failed\" \"$NAME: the verified commit pin is malformed; refusing to update.\"",
        "    exit 1",
        "  fi",
        "  if [ ! -d \"$D/.git\" ]; then",
        "    notify \"Plugin update failed\" \"$NAME: no git clone to fast-forward at $D.\"",
        "    exit 1",
        "  fi",
        "  if ! timeout 30 git -C \"$D\" fetch --quiet origin HEAD; then",
        "    notify \"Plugin update failed\" \"$NAME: fetching the verified commit failed.\"",
        "    exit 1",
        "  fi",
        "  TIP=\"$(git -C \"$D\" rev-parse --verify FETCH_HEAD 2>/dev/null || true)\"",
        "  if [ \"$TIP\" != \"$EXPECTED\" ]; then",
        "    notify \"Update unavailable\" \"$NAME: upstream advanced past the verified commit; the plugin was left untouched.\"",
        "    exit 1",
        "  fi",
        "  if ! git -C \"$D\" merge --ff-only \"$EXPECTED\"; then",
        "    notify \"Plugin update failed\" \"$NAME: the clone could not fast-forward to the verified commit.\"",
        "    exit 1",
        "  fi",
        "  if ! OUT=\"$(omarchy plugin validate \"$D\" 2>&1)\"; then",
        "    git -C \"$D\" reset --hard ORIG_HEAD >/dev/null 2>&1 || true",
        "    notify \"Plugin update failed\" \"$NAME: the verified commit failed validation and was rolled back.\"",
        "    exit 1",
        "  fi",
        "  notify \"Plugin updated\" \"$NAME is updated to verified commit ${EXPECTED:0:7}.\"",
        "  exit 0",
        "fi",
        "if ! OUT=\"$(omarchy plugin update \"$ID\" --yes 2>&1)\"; then",
        "  notify \"Plugin update failed\" \"$NAME: $OUT\"",
        "  exit 1",
        "fi",
        "if printf '%s' \"$OUT\" | grep -qi 'up to date'; then",
        "  notify \"Plugin up to date\" \"$NAME was already at the latest version.\"",
        "else",
        "  notify \"Plugin updated\" \"$NAME is updated to the latest version.\"",
        "fi"
      ])
    } else if (kind === "install") {
      s = s.concat([
        "# The chosen bar section cannot ride on add's --enable, so clone",
        "# first and let the enable loop below apply --section.",
        "if ! OUT=\"$(omarchy plugin add \"$REPO\" --yes 2>&1)\"; then",
        "  # The clone can land while add fails on its own enable attempt;",
        "  # only re-add when the plugin directory did not arrive.",
        "  if [ ! -d \"${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/$ID\" ]; then",
        "    notify \"Plugin install failed\" \"$NAME: $OUT\"",
        "    exit 1",
        "  fi",
        "fi",
        "EN=(omarchy plugin enable \"$ID\")",
        "[ -n \"$SECTION\" ] && EN+=(--section \"$SECTION\")",
        "# The clone storm triggers a shell-wide rescan that can keep the",
        "# fresh plugin unknown (\"is not known\") well past the add's 2s",
        "# discovery window; wait for discovery, then enable (the shell IPC",
        "# is idempotent) until the state reads enabled.",
        "for _ in $(seq 1 15); do enabled && break; sleep 1; done",
        "for _ in $(seq 1 10); do",
        "  enabled && break",
        "  OUT=\"$(\"${EN[@]}\" 2>&1)\"",
        "  sleep 1",
        "done",
        "if enabled; then",
        "  # Land the placement through the scan's config sweep: the sweep",
        "  # re-persists shell.json from the registry snapshot and can revert",
        "  # the flag and drop the bar layout entry, so re-check both -- the",
        "  # layout entry, not just the flag -- and re-run the enable",
        "  # (idempotent, and it re-applies the section) while either lags.",
        "  for _ in $(seq 1 4); do",
        "    sleep 2",
        "    enabled && placed && break",
        "    \"${EN[@]}\" >/dev/null 2>&1",
        "  done",
        "fi",
        "if enabled && placed; then",
        "  if [ -n \"$SECTION\" ]; then",
        "    notify \"Plugin installed\" \"$NAME is installed and enabled on the bar ($SECTION section).\"",
        "  else",
        "    notify \"Plugin installed\" \"$NAME is installed and enabled.\"",
        "  fi",
        "  # Installing the manager itself is only half the system: its",
        "  # browser extension carries the Install buttons. Re-summon the",
        "  # (freshly reloaded) wizard on the browser-extension prompt.",
        "  if [ \"$ID\" = \"bramvanoploo.omarchy-browser-plugin-manager\" ]; then",
        "    PAYLOAD=$(jq -cn --arg id \"$ID\" --arg repo \"$REPO\" --arg name \"$NAME\" '{source:\"worker\",mode:\"browser-prompt\",id:$id,repo:$repo,name:$name}' 2>/dev/null) || PAYLOAD=\"{\\\"source\\\":\\\"worker\\\",\\\"mode\\\":\\\"browser-prompt\\\",\\\"id\\\":\\\"$ID\\\",\\\"repo\\\":\\\"$REPO\\\",\\\"name\\\":\\\"$NAME\\\"}\"",
        "    omarchy-shell -q shell summon \"$ID\" \"$PAYLOAD\"",
        "  fi",
        "elif enabled; then",
        "  notify \"Plugin installed\" \"$NAME is enabled, but its bar icon placement did not stick. Retry: omarchy plugin enable $ID --section $SECTION\"",
        "else",
        "  notify \"Plugin install incomplete\" \"$NAME was installed but failed to enable. Retry: omarchy plugin enable $ID --section $SECTION\"",
        "fi"
      ])
    } else {
      s = s.concat([
        // Unregister the native messaging host while the plugin directory
        // still exists: the setup script lives inside it, and after removal
        // nothing can find it.
        "PLUG=\"${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/bramvanoploo.omarchy-browser-plugin-manager\"",
        "if [ -x \"$PLUG/bin/plugin-installer-setup\" ]; then",
        "  \"$PLUG/bin/plugin-installer-setup\" --uninstall >/dev/null 2>&1 || true",
        "fi",
        "if ! OUT=\"$(omarchy plugin remove \"$ID\" --yes 2>&1)\"; then",
        "  notify \"Plugin uninstall failed\" \"$NAME: $OUT\"",
        "  exit 1",
        "fi",
        "notify \"Plugin uninstalled\" \"$NAME has been removed.\""
      ])
    }
    return s.join("\n") + "\n"
  }

  function spawnWorker(kind, section) {
    Quickshell.execDetached([
      "bash", "-c", root.buildWorkerScript(kind),
      "omarchy-plugin-worker",
      root.pluginId,
      root.pluginName,
      root.pluginRepo,
      String(section || "")
    ])
    root.close()
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
      if (!root.opened) return
      if (exitCode !== 0) {
        // Same discovery race as the add's internal enable: the shell's
        // registry scan may not have reached the fresh clone yet. Retry
        // within the shared enableTries budget; the enable IPC is idempotent.
        if (root.enableTries < 8 && /is not known/.test(root.enableOutput)) {
          root.enableTries++
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
          // Close like every other action: the browser-extension prompt is
          // shown exactly once, by the install worker directly after a
          // successful install of the manager (see buildWorkerScript).
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
      if (!root.opened) return
      if (exitCode !== 0) root.fail("omarchy plugin list exited with code " + exitCode)
    }
  }

  Process {
    id: disableProc
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.enableOutput += "\n" + String(text || "") }
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: root.enableOutput += "\n" + String(text || "") }
    onExited: function (exitCode) {
      if (!root.opened) return
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
    property string tooltipText: ""
    property bool spin: false
    property int labelPixelSize: Style.font.body
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
      font.pixelSize: piButton.labelPixelSize
      font.bold: piButton.primary || piButton.danger
      transformOrigin: Item.Center

      // NumberAnimation (GUI-thread timer driven) rather than
      // RotationAnimator: the shell's composited windows do not advance
      // render-thread animators (same mechanism the bar's refresh button
      // used). Loops full circles while the check runs, and resets so the
      // icon sits upright again once it finishes.
      NumberAnimation on rotation {
        from: 0
        to: 360
        duration: 900
        loops: Animation.Infinite
        running: piButton.spin
        onRunningChanged: if (!running) labelText.rotation = 0
      }
    }
    MouseArea {
      id: piMouse
      anchors.fill: parent
      hoverEnabled: true
      // Kept enabled while the button is dimmed (a running check) so the
      // tooltip ("Checking for updates...") still follows the pointer and a
      // click always reaches the bar. The bar's own running-check guard drops
      // a redundant click, so a click during a check is a safe no-op; gating
      // the click on the button's enabled state instead made the refresh
      // button inert whenever the published snapshot lagged with
      // updateChecking true.
      cursorShape: piButton.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: piButton.clickedPi()
    }
    PanelToolTip {
      visible: piMouse.containsMouse && piButton.tooltipText !== ""
      text: piButton.tooltipText
    }
  }

  // Settings update-list row: plugin name + installed -> latest, with
  // per-row Update (primary) and Uninstall (danger) buttons. Every field
  // is catalog-sourced, so plain-text Text keeps remote strings inert.
  component PiUpdateRow: Row {
    width: parent ? parent.width : 0
    spacing: Style.spacing.controlGap
    Column {
      width: parent.width - 2 * Style.space(78) - 2 * Style.spacing.controlGap
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)
      Text {
        width: parent.width
        elide: Text.ElideRight
        textFormat: Text.PlainText
        text: String(modelData.name)
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        color: Color.foreground
      }
      Text {
        width: parent.width
        elide: Text.ElideRight
        textFormat: Text.PlainText
        text: String(modelData.from) + "  \u2192  " + String(modelData.to)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        color: Color.muted
      }
    }
    PiButton {
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(78)
      height: Style.space(30)
      label: "Update"
      primary: true
      onClickedPi: root.beginUpdateConfirm([modelData])
    }
    PiButton {
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(78)
      height: Style.space(30)
      label: "Uninstall"
      danger: true
      onClickedPi: root.beginUninstallConfirm(modelData)
    }
  }

  // Plain text on purpose: every line here can carry remote marketplace
  // metadata (catalog author, version, license, repo, manifest errors).
  // AutoText would interpret markup in it, so a remote <img src=...> tag
  // would fetch from the network before the user installed anything.
  component PiLine: Text {
    width: cardColumn.width
    wrapMode: Text.Wrap
    textFormat: Text.PlainText
    color: Util.alpha(Color.foreground, 0.75)
    font.family: Style.font.family
    font.pixelSize: Style.font.body
  }

  // Hairline separator dividing the settings panel into groups; a muted
  // foreground alpha so it reads as a rule in any theme (the bar popup's
  // separator, ported verbatim).
  component PiRule: Rectangle {
    width: cardColumn.width
    height: 1
    color: Util.alpha(Color.foreground, 0.15)
  }

  // RichText line with clickable <a href> links; activation opens the URL
  // in the default browser via xdg-open. Colors come from the inline style
  // in root.linkTag (RichText ignores Text.linkColor).
  component PiTextLink: Text {
    width: cardColumn.width
    wrapMode: Text.Wrap
    textFormat: Text.RichText
    color: Util.alpha(Color.foreground, 0.75)
    font.family: Style.font.family
    font.pixelSize: Style.font.body
    onLinkActivated: function (link) { root.openUrl(link) }
  }

  // Caption-size RichText line: used by the browser-store support lists,
  // where the HTML is built locally from hardcoded family labels (the
  // widget wraps installed browsers in an accent span). No links, so no
  // href is reachable from it.
  component PiRichLine: Text {
    width: cardColumn.width
    wrapMode: Text.Wrap
    textFormat: Text.RichText
    color: Color.muted
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
  }

  // One update list: bold title + live count pill, then a capped
  // scrollable box (three rows, fade hint below the fold), rows carrying
  // name, installed -> latest, and per-row Update/Uninstall. Same
  // structure the bar popup's update sections used.
  component PiUpdateSection: Column {
    id: piSec
    property string title: ""
    property color tone: Color.accent
    property var items: []
    width: parent ? parent.width : 0
    spacing: Style.space(8)
    visible: items.length > 0
    readonly property int capRows: 3
    readonly property real rowHeight: Style.space(30)
    readonly property real boxHeight: items.length > capRows
      ? rowHeight * capRows + Style.space(6) * (capRows - 1)
      : rowHeight * items.length + Style.space(6) * Math.max(0, items.length - 1)

    Row {
      spacing: Style.space(8)
      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: piSec.title
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        font.bold: true
      }
      Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        width: piSecCount.implicitWidth + Style.space(10)
        height: piSecCount.implicitHeight + Style.space(4)
        radius: height / 2
        color: Util.alpha(piSec.tone, 0.15)
        Text {
          id: piSecCount
          anchors.centerIn: parent
          text: piSec.items.length
          color: piSec.tone
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          font.bold: true
        }
      }
    }

    Rectangle {
      width: piSec.width
      height: piSec.boxHeight
      radius: Style.cornerRadius
      color: Util.alpha(Color.foreground, 0.05)
      clip: true
      Flickable {
        id: piSecFlick
        anchors.fill: parent
        anchors.margins: Style.space(8)
        contentHeight: piSecColumn.implicitHeight
        boundsBehavior: Flickable.StopAtBounds
        Column {
          id: piSecColumn
          width: parent.width
          spacing: Style.space(6)
          Repeater {
            model: piSec.items
            delegate: PiUpdateRow
          }
        }
      }
      Text {
        anchors.bottom: parent.bottom
        anchors.bottomMargin: Style.space(3)
        anchors.horizontalCenter: parent.horizontalCenter
        text: (piSec.items.length - piSec.capRows) + " more below \u00b7 scroll"
        color: Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        visible: piSecFlick.contentHeight > piSecFlick.height + 1
          && piSecFlick.contentY + piSecFlick.height < piSecFlick.contentHeight - 1
      }
    }
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

    // Escape closes the panel. The surface grabs exclusive keyboard focus
    // while open, so a focused item inside it receives the key.
    Item {
      anchors.fill: parent
      focus: true
      Keys.onEscapePressed: root.close()
    }

    BorderSurface {
      id: card
      anchors.centerIn: parent
      width: Math.min(Style.space(672), panel.width - Style.space(48))
      // Fit the visible stage. Column.implicitHeight also sums the hidden
      // stage columns (running, review, placement, browser prompts), which
      // inflates the card to the tallest possible stage. childrenRect only
      // bounds the *visible* children, so the card hugs the current stage's
      // content, clamped to the screen.
      height: Math.min(cardColumn.anchors.topMargin
                       + cardColumn.childrenRect.height
                       + cardColumn.anchors.bottomMargin
                       + Style.space(48),
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
        anchors.topMargin: card.contentTopInset / 4
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: Style.spacing.panelGap

        // Header block: bar icon + plugin name + version pill + action
        // subtitle, with equal margins above and below (half the panel's
        // content padding) and a full-width divider under the header. The
        // icon-to-title spacing matches the bar widget panels (space(14)).
        Item {
          id: headerBlock
          width: cardColumn.width
          height: headerRow.implicitHeight + Style.space(6)

        Row {
          id: headerRow
          width: parent.width
          spacing: Style.space(14)

          // Extensions glyph (Nerd Font "cod-extensions", U+EAE6): the same
          // icon the bar widget uses. Styled exactly like the OmaGuake
          // settings panel header icon: plain accent-color Text, sized to
          // span the title + subtitle block, no background, no border.
          // (Literal glyph char: QML \\u escapes consume exactly 4 hex digits.)
          Text {
            text: ""
            font.family: Style.font.family
            font.pixelSize: Math.max(Style.font.heading,
              Math.round(headerTextCol.implicitHeight))
            color: Color.accent
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            id: headerTextCol
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Row {
              spacing: Style.space(8)

              Text {
                textFormat: Text.PlainText
                text: (root.manifest && root.manifest.name)
                  ? String(root.manifest.name) : root.pluginName
                font.family: Style.font.family
                font.pixelSize: Style.font.title
                font.bold: true
                color: Color.foreground
                anchors.verticalCenter: parent.verticalCenter
              }

              Rectangle {
                visible: root.manifest && root.manifest.version
                anchors.verticalCenter: parent.verticalCenter
                height: Style.space(18)
                width: headerVersionText.implicitWidth + Style.space(12)
                radius: Style.cornerRadius > 0 ? 4 : 0
                color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.15)
                border.color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.4)
                border.width: 1

                Text {
                  id: headerVersionText
                  anchors.centerIn: parent
                  text: "v" + String((root.manifest && root.manifest.version) || "")
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  color: Color.accent
                }
              }
            }

            Text {
              text: root.headerSubtitle
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              color: Color.muted
            }
          }
        }

          // Divider spanning the full card width, under the header.
          Rectangle {
            anchors.bottom: parent.bottom
            x: -card.contentLeftInset
            width: card.width
            height: 1
            color: Qt.rgba(Color.foreground.r, Color.foreground.g,
              Color.foreground.b, 0.18)
          }
        }

        PiLine {
          visible: root.stage !== "browser-prompt" && root.stage !== "browser-defer"
            && root.stage !== "running"
            && root.mode !== "settings" && root.mode !== "settings-confirm"
          text: root.pluginName + "  \u00b7  " + root.pluginId
          color: Color.foreground
          font.bold: true
          font.pixelSize: Style.font.title
        }

        // ---- stage: running (in-progress system panel) ----
        Column {
          visible: root.stage === "running"
          width: cardColumn.width
          spacing: Style.spacing.md

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            textFormat: Text.PlainText
            text: (root.runningAction === "uninstall" ? "Uninstalling "
                : root.runningAction === "update" ? "Updating " : "Installing ")
              + root.runningName
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            font.bold: true
            color: Color.foreground
          }

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: "this takes a bit \u00b7 Esc hides this panel, the action keeps running"
              + " \u00b7 a notification lands when it is done"
            wrapMode: Text.Wrap
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            color: Color.muted
          }

          // The globe scene, painted from the live palette: grid and stars
          // in foreground, satellites in accent. De-orbit on uninstall.
          // Repaint driver: a never-ending NumberAnimation advances `phase`,
          // each change requests a paint, and the paints keep producing
          // scene-graph frames - which is what keeps the QML animation clock
          // (and the caption/marker Timers) running at all: an idle panel
          // window renders no frames, and a frameless scene graph freezes
          // plain Timers after their first tick.
          // Spacer: 10px of breathing room above and below the globe.
          Item {
            width: parent.width
            height: globe.height + 20
            // Bind visibility explicitly (not just through the hidden stage
            // Column): a Canvas with a running repaint animation keeps
            // compositing frames, and a hidden-but-visible Canvas leaves
            // stray globe fragments painted on the window outside the card.
            visible: root.opened && root.stage === "running"

            Canvas {
            id: globe
            // Zero size outside the running stage: a hidden Canvas (any
            // render strategy) keeps compositing its last frame onto this
            // full-screen window, painting globe scenes behind other
            // stages. A zero-sized item paints nothing.
            width: root.opened && root.stage === "running" ? Style.space(360) : 0
            height: root.opened && root.stage === "running" ? Style.space(180) : 0
            anchors.horizontalCenter: parent.horizontalCenter
            y: 10
            visible: root.opened && root.stage === "running"
            // Image strategy: an Immediate canvas composites straight onto
            // the window surface even while hidden, leaving globe scenes
            // painted behind other stages. Image-cached content respects
            // visibility; the phase animation below keeps frames cycling,
            // which is what keeps the marker Timers alive.
            renderStrategy: Canvas.Image
            property real phase: 0
            onPhaseChanged: requestPaint()
            // getContext() before the canvas is available returns null (and
            // Qt warns), so paints wait for availability and repaint once
            // the context exists.
            onAvailableChanged: if (available) requestPaint()
            onVisibleChanged: if (!visible && available) {
              var c = getContext("2d")
              if (c) {
                c.clearRect(0, 0, width, height)
                c.resetTransform()
              }
            }
            onPaint: {
              if (!visible || !available) return
              var ctx = getContext("2d")
              if (!ctx) return
              var t = (Date.now() - root.runningT0) / 1000 + 5
              root.paintGlobe(ctx, width, height, t,
                root.runningAction === "uninstall",
                root.globeRgb(Color.foreground), root.globeRgb(Color.accent),
                root.globeRgb(Color.foreground))
            }
            NumberAnimation on phase {
              from: 0
              to: 3600
              duration: 360000
              loops: Animation.Infinite
              running: root.opened && root.stage === "running"
            }
            }
          }

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            textFormat: Text.PlainText
            text: root.runningCaptionText()
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            font.italic: true
            color: Color.muted
          }

          // Caption roulette every 3s (kept alive by the globe's frame flow).
          Timer {
            interval: 3000
            running: root.opened && root.stage === "running"
            triggeredOnStart: true
            onTriggered: root.runningCaption = root.runningCaption + 1
          }
        }

        // ---- stage: settings (the bar widget's settings panel as a
        // centered system overlay: toggles, update lists, batch update,
        // poll interval, store links; every control writes a command the
        // widget dispatches, and the panel repaints from the republished
        // snapshot within 400ms) ----
        // Scrollable body: the settings content (toggles with captions,
        // both capped lists, interval row, store section) can exceed the
        // card, so the stage scrolls between the fixed header and footer.
        Flickable {
          visible: root.stage === "settings"
          width: cardColumn.width
          // Fit the content, capped at the space left on screen between the
          // fixed header and footer (card clamps to panel.height - 48, and
          // carries 24+24 of padding). Only scrolls when the content is
          // taller than the available space; never stretches the card.
          // Must not bind to cardColumn.height: the card height is derived
          // from this Flickable's rect (childrenRect), so that would loop.
          height: Math.min(settingsBody.childrenRect.height,
                           Math.max(Style.space(160), panel.height
                             - Style.space(96)
                             - headerBlock.height - footerSpacer.height
                             - footerRow.height - 3 * cardColumn.spacing))
          // childrenRect (visible children only): Column.implicitHeight
          // counts the conditionally hidden rows too, which would leave
          // blank space at the bottom of the scroll range.
          contentHeight: settingsBody.childrenRect.height
          boundsBehavior: Flickable.StopAtBounds
          Column {
          id: settingsBody
          width: parent.width
          // Same group spacing as the bar popup's settings column.
          spacing: Style.space(20)

          // Toggles first, directly under the panel header (as in the bar
          // popup): the unverified toggle gates which versions the update
          // sections and the batch action below can act on, so it reads as
          // the setting that shapes the whole panel. Label + explanatory
          // caption left, On/Off button right.
          Row {
            width: parent.width
            spacing: Style.spacing.controlGap
            Column {
              width: parent.width - Style.space(86) - Style.spacing.controlGap
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)
              PiLine { text: "Update to unverified versions"; width: parent.width }
              PiLine {
                width: parent.width
                color: Color.muted
                font.pixelSize: Style.font.caption
                text: "Off: plugins only update to catalog-verified versions."
              }
            }
            PiButton {
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(86)
              label: root.snapBool("allowUnverified") ? "On" : "Off"
              primary: root.snapBool("allowUnverified")
              onClickedPi: root.toggleAllowUnverified()
            }
          }
          Row {
            width: parent.width
            spacing: Style.spacing.controlGap
            Column {
              width: parent.width - Style.space(86) - Style.spacing.controlGap
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)
              PiLine { text: "Notify about plugin updates"; width: parent.width }
              PiLine {
                width: parent.width
                color: Color.muted
                font.pixelSize: Style.font.caption
                text: "Off: the badge and panel lists stay live, but no desktop notifications."
              }
            }
            PiButton {
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(86)
              label: root.snapBool("notifyUpdates") ? "On" : "Off"
              primary: root.snapBool("notifyUpdates")
              onClickedPi: root.toggleNotifyUpdates()
            }
          }

          PiRule { visible: root.settingsUpdatesGroupVisible() }

          PiLine {
            visible: !root.snapBool("updateChecking")
              && !root.snapBool("updateCheckFailed")
              && root.snapStr("lastCheckText") !== "never"
              && root.snapStr("lastCheckText") !== ""
              && root.settingsAllRows().length === 0
            text: "All installed plugins are up to date."
          }
          PiLine {
            visible: root.snapBool("updateCheckFailed")
            color: Color.urgent
            text: "Catalog unreachable: showing the last known update list."
          }
          PiLine {
            visible: root.snapBool("settingsSaveFailed")
            color: Color.urgent
            text: "Settings file could not be written: changes apply this session only."
          }

          // Batch update (hidden while nothing is updatable): sits above
          // the lists as the primary action; arms a confirmation for the
          // eligible plugins, which then run through detached workers.
          PiButton {
            visible: root.settingsEligibleRows().length > 0
            width: parent.width
            primary: true
            label: "Update " + root.settingsEligibleRows().length
              + (root.settingsEligibleRows().length === 1
                ? " plugin now" : " plugins now")
            onClickedPi: root.beginUpdateConfirm(root.settingsEligibleRows())
          }

          // Per-plugin update lists: verified first, unverified below.
          // The unverified list shows its rows under the opt-in toggle
          // only: with the toggle off the widget never acts on them, and
          // offering rows the batch refuses to update confuses the
          // eligible count the batch label announces.
          PiUpdateSection {
            title: "Verified plugin updates"
            tone: Color.accent
            items: root.snapList("verified")
          }
          PiUpdateSection {
            title: "Unverified plugin updates"
            tone: Color.urgent
            items: root.snapBool("allowUnverified") ? root.snapList("unverified") : []
          }

          PiRule {}

          // Poll interval: five equal segments (selected one primary-marked)
          // and the refresh button. Sits below the lists: the schedule and
          // the manual check are settings, not the panel's primary action.
          PiLine {
            text: "Check for plugin updates:"
          }
          Row {
            width: parent.width
            spacing: Style.spacing.controlGap
            Repeater {
              model: root.snapList("pollValues")
              delegate: PiButton {
                width: (parent.width - Style.space(34)
                  - 5 * Style.spacing.controlGap) / 6
                label: String(root.snapList("pollLabels")[index] || "")
                primary: Number(modelData) === Number(root.snapStr("pollMinutes"))
                onClickedPi: root.setPollIntervalMinutes(modelData)
              }
            }
            PiButton {
              width: Style.space(34)
              label: "\uF021"
              labelPixelSize: Style.font.caption
              spin: root.snapBool("updateChecking")
              tooltipText: root.snapBool("updateChecking")
                ? "Checking for updates\u2026"
                : "Check for updates"
              enabled: !root.snapBool("updateChecking")
              onClickedPi: root.writeSettingsCmd({ action: "refresh" })
            }
          }

          PiRule {}

          // Browser stores: the supported-browser lists (installed browsers
          // accent-highlighted by the widget) above half-width buttons that
          // open the store page in the first installed browser of that
          // family (the labels carry the launch target).
          Grid {
            width: parent.width
            columns: 2
            columnSpacing: Style.spacing.controlGap
            rowSpacing: Style.space(6)
            PiRichLine {
              width: (parent.width - Style.spacing.controlGap) / 2
              text: root.snapStr("chromeSupport")
            }
            PiRichLine {
              width: (parent.width - Style.spacing.controlGap) / 2
              text: root.snapStr("firefoxSupport")
            }
            PiButton {
              width: (parent.width - Style.spacing.controlGap) / 2
              label: root.snapStr("chromeLabel")
              onClickedPi: root.writeSettingsCmd({
                action: "open_store", url: root.snapStr("chromeUrl"),
                bin: root.snapStr("chromeBin")
              })
            }
            PiButton {
              width: (parent.width - Style.spacing.controlGap) / 2
              label: root.snapStr("firefoxLabel")
              onClickedPi: root.writeSettingsCmd({
                action: "open_store", url: root.snapStr("firefoxUrl"),
                bin: root.snapStr("firefoxBin")
              })
            }
          }
          }
        }

        // ---- stage: settings-confirm (update / uninstall confirmation) ----
        Column {
          visible: root.stage === "settings-confirm"
          width: cardColumn.width
          spacing: Style.spacing.md

          PiLine {
            font.pixelSize: Style.font.title
            font.bold: true
            color: Color.foreground
            text: root.settingsConfirm && root.settingsConfirm.kind === "uninstall"
              ? "Uninstall plugin?"
              : "Update " + (root.settingsConfirm
                ? root.settingsConfirm.ids.length : 0)
                + (root.settingsConfirm && root.settingsConfirm.ids.length === 1
                  ? " plugin?" : " plugins?")
          }
          PiLine {
            text: root.settingsConfirm ? String(root.settingsConfirm.text || "") : ""
          }
          Repeater {
            model: root.settingsConfirm ? (root.settingsConfirm.names || []) : []
            delegate: PiLine {
              text: "  \u00b7  " + String(modelData)
            }
          }
        }

        // ---- stage: review (install confirmation) ----
        Column {
          visible: root.stage === "review" && root.mode === "install"
          width: cardColumn.width
          spacing: Style.spacing.lg
          // What is about to be installed: the plugin's name, publisher,
          // version, license, kinds, and source. The marketplace listing
          // is the primary source; when it is missing (unlisted plugins)
          // the fetched plugin manifest fills in the same line.
          PiLine {
            visible: root.pluginName.length > 0
            color: Color.foreground
            font.bold: true
            text: root.pluginName
          }
          PiLine {
            visible: root.pluginId.length > 0 && root.pluginId !== root.pluginName
            color: Color.muted
            font.pixelSize: Style.font.caption
            text: root.pluginId
          }
          PiLine {
            visible: !root.catalogEntry && root.pluginManifest
              && String((root.pluginManifest || {}).description || "").length > 0
            text: String((root.pluginManifest || {}).description || "")
          }
          PiLine {
            visible: root.catalogEntry !== null
              || (root.pluginManifest !== null && root.manifestLoaded)
            text: {
              var e = root.catalogEntry || root.pluginManifest || {}
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
            visible: root.pluginRepo.length > 0
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
        PiLine {
          visible: root.stage === "update-confirm"
            && root.updateVerifiedSha.length > 0
          text: "Installed. Updating fast-forwards the plugin to the verified "
            + "commit " + root.shortSha(root.updateVerifiedSha) + ". If upstream "
            + "advanced past it, the update is refused and the plugin stays untouched."
        }
        PiLine {
          visible: root.stage === "update-confirm"
            && root.updateVerifiedSha.length === 0
          color: Color.accent
          text: "Installed. No marketplace-verified commit matches upstream, and "
            + "you allowed unverified updates: this update pulls commits no "
            + "maintainer reviewed. The shell reloads the plugin afterwards."
        }

        // ---- stage: browser-prompt (manager install finished) ----
        // Shown exactly once: the install worker summons it directly after a
        // successful install of the manager. The wizard is this manager's own
        // UI; it is inert until the matching browser extension is installed.
        // Send the user to the extension page for their default browser and
        // explain the other-browser option.
        Column {
          visible: root.stage === "browser-prompt"
          width: cardColumn.width
          spacing: Style.spacing.lg
          PiLine {
            text: "The Omarchy plugin is installed. Its browser extension is "
              + "what shows the Install buttons on plugins.omarchy.org, so "
              + "without it the plugin does nothing."
          }
          PiLine {
            text: "The button below opens the extension in the "
              + root.primaryStoreName + " for your default browser; the "
              + "browser asks before installing anything."
          }
          PiTextLink {
            text: "For " + root.otherFamilyName + ": "
              + root.linkTag(root.otherExtensionUrl, root.otherLinkText)
          }
        }

        // ---- stage: browser-defer (user cancelled the prompt) ----
        Column {
          visible: root.stage === "browser-defer"
          width: cardColumn.width
          spacing: Style.spacing.lg
          PiLine {
            color: Color.urgent
            text: "Without the browser extension this plugin does nothing: "
              + "no Install buttons will appear on plugins.omarchy.org."
          }
          PiTextLink {
            text: "For " + root.otherFamilyName + ": "
              + root.linkTag(root.otherExtensionUrl, root.otherLinkText)
          }
        }

        // ---- blocking / loading / validation errors across all confirm stages ----
        PiLine {
          visible: root.reviewBlocked.length > 0
            && (root.stage === "review" || root.stage === "uninstall-confirm"
                || root.stage === "enable-confirm" || root.stage === "disable-confirm"
                || root.stage === "update-confirm")
          color: Color.urgent
          text: root.reviewBlocked
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

        // ---- stage: placement (install/enable modes, bar widgets) ----
        // Sections laid out horizontally in an equal-width 3-column grid
        // (a wider version of the pre-refactor Left/Center/Right row: the
        // list is the shell's live section list). The manifest's default
        // section carries a "(default)" suffix and primary coloring.
        Column {
          visible: root.stage === "placement"
          width: cardColumn.width
          spacing: Style.spacing.rowGap
          PiLine {
            text: "Where should the bar icon go?"
          }
          Grid {
            width: parent.width
            columns: 3
            columnSpacing: Style.spacing.controlGap
            rowSpacing: Style.spacing.controlGap
            Repeater {
              model: root.barPlacementSections
              delegate: PiButton {
                width: (parent.width - 2 * Style.spacing.controlGap) / 3
                primary: root.defaultSection === modelData
                label: root.sectionLabel(modelData)
                  + (root.defaultSection === modelData ? " (default)" : "")
                onClickedPi: root.mode === "install"
                  ? root.installWithSection(modelData)
                  : root.enable(modelData)
              }
            }
          }
        }

        Item { id: footerSpacer; width: 1; height: Style.spacing.xs }

        // ---- footer: confirm / cancel ----
        // Right-to-left layout: the primary action (Install/Uninstall/...)
        // lands rightmost, Cancel to its left, as in standard dialogs.
        Row {
          id: footerRow
          layoutDirection: Qt.RightToLeft
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
            enabled: root.canAct
            danger: true
            primary: true
            label: "Uninstall plugin"
            onClickedPi: root.runUninstall()
          }
          PiButton {
            visible: root.mode === "enable" && root.stage === "enable-confirm"
            enabled: root.canAct
            primary: true
            label: "Enable plugin"
            onClickedPi: root.confirmEnable()
          }
          PiButton {
            visible: root.mode === "disable" && root.stage === "disable-confirm"
            enabled: root.canAct
            primary: true
            label: "Disable plugin"
            onClickedPi: root.runDisable()
          }
          PiButton {
            visible: root.mode === "update" && root.stage === "update-confirm"
            enabled: root.canAct
            primary: true
            label: "Update plugin"
            onClickedPi: root.runUpdate()
          }
          PiButton {
            visible: root.stage === "settings"
            primary: true
            label: "Close"
            onClickedPi: root.close()
          }
          PiButton {
            visible: root.stage === "settings-confirm"
            primary: !(root.settingsConfirm
              && root.settingsConfirm.kind === "uninstall")
            danger: root.settingsConfirm
              && root.settingsConfirm.kind === "uninstall"
            label: root.settingsConfirm && root.settingsConfirm.kind === "uninstall"
              ? "Uninstall" : "Update"
            onClickedPi: root.confirmSettingsAction()
          }
          PiButton {
            visible: root.stage === "settings-confirm"
            label: "Cancel"
            onClickedPi: root.cancelSettingsConfirm()
          }
          PiButton {
            visible: root.stage === "review" || root.stage === "uninstall-confirm"
              || root.stage === "enable-confirm" || root.stage === "disable-confirm"
              || root.stage === "update-confirm"
            label: "Cancel"
            onClickedPi: root.close()
          }
          PiButton {
            visible: root.stage === "placement"
            label: "Cancel"
            onClickedPi: root.close()
          }
          PiButton {
            visible: root.stage === "browser-prompt"
            primary: true
            label: root.primaryExtensionLabel
            onClickedPi: root.openExtensionPage()
          }
          PiButton {
            visible: root.stage === "browser-prompt"
            label: "Cancel"
            onClickedPi: root.stage = "browser-defer"
          }
          PiButton {
            visible: root.stage === "browser-defer"
            primary: true
            label: root.primaryExtensionLabel
            onClickedPi: root.openExtensionPage()
          }
          PiButton {
            visible: root.stage === "browser-defer"
            danger: true
            label: "Uninstall Omarchy plugin"
            onClickedPi: root.uninstallManager()
          }
          PiButton {
            visible: root.stage === "browser-defer"
            label: "Cancel"
            onClickedPi: root.close()
          }
        }
      }
    }
  }
}
