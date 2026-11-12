import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui

// Omarchy PlugBrug wizard overlay.
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
// The bar widget's left click gates the same prompt: when no installed
// browser has the extension, or the default browser specifically lacks it,
// the click opens this dialog instead of the manage popup (the extension is
// seen through per-family stamps the extension/host write into the state
// dir). The dialog presents the extension as the plugin's core marketplace
// feature and links the right store for the default browser, the other
// family as a second link. Cancelling records a dismissal marker so the
// bar stops intercepting clicks; the store buttons just open and close.
// The native messaging host registration is automated: registering on every
// load is idempotent, the uninstall worker unregisters before removing the
// plugin, and a destruction-time watcher unregisters after a terminal
// removal (self-cleanup copy parked in the state dir).

Item {
  id: root

  readonly property color foreground: Color.foreground
  readonly property color accent: Color.accent
  readonly property color dim: Qt.darker(Color.foreground, 1.45)
  readonly property string fontFamily: Style.font.family
  property string activePluginOpId: ""
  property string pluginActionStatus: ""
  property alias pluginFilterQuery: root.manageFilter
  readonly property var filteredPlugins: root.manageFilteredRows()

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  // Directory this overlay was loaded from (the installed plugin folder),
  // as a filesystem path: the plugin's bin/ scripts live next to Wizard.qml.
  readonly property string pluginDir: {
    var u = String(Qt.resolvedUrl("."))
    return u.startsWith("file://") ? decodeURIComponent(u.slice(7)) : u
  }

  property var ownManifest: null
  readonly property string managerVersion: {
    if (root.ownManifest && root.ownManifest.version)
      return String(root.ownManifest.version)
    if (root.settingsSnap && root.settingsSnap.managerVersion)
      return String(root.settingsSnap.managerVersion)
    if (root.manifest && root.manifest.version)
      return String(root.manifest.version)
    return ""
  }
  readonly property string managerName: {
    if (root.ownManifest && root.ownManifest.name)
      return String(root.ownManifest.name)
    if (root.manifest && root.manifest.name)
      return String(root.manifest.name)
    return "PlugBrug"
  }

  FileView {
    id: ownManifestFile
    path: root.pluginDir + "/manifest.json"
    printErrors: false
    onLoaded: {
      try {
        var m = JSON.parse(text())
        root.ownManifest = m
      } catch (e) {
        root.ownManifest = null
      }
    }
    onLoadFailed: root.ownManifest = null
  }

  // This manager plugin's own id: the browser-extension prompt targets its
  // own extension, never the plugin passed in the payload.
  readonly property string managerId: (root.ownManifest && root.ownManifest.id)
    ? String(root.ownManifest.id)
    : ((root.manifest && root.manifest.id) ? String(root.manifest.id) : "bramvanoploo.omarchy-browser-plugin-manager")

  // Browser extension pages: Firefox-based browsers install the add-on from
  // AMO; Chromium-based browsers that support Chrome Web Store extensions
  // install from the CWS listing page (store-assigned item id URL).
  readonly property string amoUrl:
    "https://addons.mozilla.org/firefox/addon/omarchy-browser-plugin-manager/"
  readonly property string cwsUrl:
    "https://chromewebstore.google.com/detail/nalcgjmbglkcmohokidcmogcbpmhkdjf"

  // Default browser (.desktop id) behind the extension prompt; detected
  // when the prompt opens, empty when detection failed (fallback: Firefox).
  property string defaultBrowserId: ""
  property bool defaultBrowserLoaded: false

  property bool opened: false


  // review | enable-confirm | disable-confirm | uninstall-confirm
  // | update-confirm | enabling | placement | disabling
  // | browser-prompt | running
  property string stage: "review"

  property string pluginId: ""
  property string pluginRepo: ""
  property string pluginName: ""
  // Version shown in the header pill while a settings-opened placement
  // stage is up (see headerVersion and openPlacementFromSettings); the
  // Manage row's installed version is copied in when that flow starts.
  property string pluginVersion: ""
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
  readonly property bool catalogLoading: !catalogLoaded && catalogError === ""

  readonly property string marketplaceUrl: "https://plugins.omarchy.org/"
  // About-tab links: this plugin's GitHub project, its issue tracker, its
  // marketplace listing (the same plugin.html page the browser extension
  // watches), and the two repo documents.
  readonly property string githubRepoUrl:
    "https://github.com/bramvanoploo/omarchy-browser-plugin-manager"
  readonly property string githubIssuesUrl: root.githubRepoUrl + "/issues"
  readonly property string marketplaceListingUrl:
    root.marketplaceUrl + "plugin.html?id=" + root.managerId
  readonly property string licenseUrl: root.githubRepoUrl + "/blob/main/LICENSE"
  readonly property string privacyUrl: root.githubRepoUrl + "/blob/main/PRIVACY.md"
  readonly property string catalogThumb: {
    var e = root.catalogEntry
    var t = e ? String(e.previewImage || e.previewThumbnail || "") : ""
    return /^assets\/[A-Za-z0-9._\/-]+$/.test(t) ? t : ""
  }
  readonly property real catalogThumbRatio: 5 / 16
  readonly property real catalogThumbNative: {
    var e = root.catalogEntry
    var w = e ? (Number(e.previewWidth) || Number(e.previewThumbnailWidth) || 0) : 0
    var h = e ? (Number(e.previewHeight) || Number(e.previewThumbnailHeight) || 0) : 0
    return w > 0 && h > 0 ? h / w : root.catalogThumbRatio
  }

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
      else
        value = false
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

  // Update confirmation's "from -> to" line: the local clone's manifest
  // version (the same spelling the shared detector reads) to the catalog
  // entry's version, in the same "from  →  to" format as the settings
  // update rows. Empty when either side is unknown — the commit-sha
  // explainer lines then still describe exactly what is checked out.
  // (The pluginsDir join mirrors BarWatch.qml's installedManifestPath.)
  readonly property string updateVersionLine: {
    var e = root.catalogEntry
    var to = e && e.version ? String(e.version) : ""
    if (root.installedVersion.length === 0 || to.length === 0) return ""
    return "v" + root.installedVersion + "  \u2192  v" + to
  }
  property string installedVersion: ""
  readonly property string pluginsDir: {
    var base = Quickshell.env("XDG_CONFIG_HOME")
      || ((Quickshell.env("HOME") || "/tmp") + "/.config")
    return base + "/omarchy/plugins"
  }
  // validPluginId is the path-safety gate (shape-checked, no traversal).
  readonly property string installedManifestPath:
    root.validPluginId(root.pluginId)
      ? root.pluginsDir + "/" + root.pluginId + "/manifest.json" : ""

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

  readonly property bool isManagerStage: root.stage === "settings"
    || root.stage === "settings-confirm"
    || root.stage === "browser-prompt"

  // Footer container visibility. Derived from the stage list only: the
  // containers must never read their buttons' `visible`, because Item's
  // visible getter reports *effective* visibility (self && every
  // ancestor). A parent binding on a child's visible therefore poisons
  // itself: hiding the PanelWindow cascades false into the rows' reads,
  // the container's binding assigns itself false, and afterwards the
  // (invisible) container pins the rows' effective visibility at false,
  // so the binding can never recover - the footer was gone until the
  // shell restarted. Keep this list in sync with the footer buttons'
  // own bindings: every stage with at least one visible footer button.
  readonly property bool footerVisible: [
    "settings", "settings-confirm", "review", "uninstall-confirm",
    "enable-confirm", "disable-confirm", "update-confirm", "placement",
    "browser-prompt"
  ].indexOf(root.stage) >= 0

  // Header version: the version pill shown in the panel header next to the title.
  readonly property string headerVersion: {
    if (root.placementFromSettings && root.pluginVersion !== "") {
      return root.pluginVersion
    }
    if (root.isManagerStage || root.pluginId === root.managerId) {
      return root.managerVersion
    }
    if (root.catalogEntry && root.catalogEntry.version) {
      return String(root.catalogEntry.version)
    }
    if (root.pluginManifest && root.pluginManifest.version) {
      return String(root.pluginManifest.version)
    }
    return ""
  }

  // Header subtitle: the action this dialog performs, under the plugin
  // identity (name + version pill).
  readonly property string headerSubtitle: {
    if (root.stage === "browser-prompt")
      return "Browser extension setup"
    if (root.stage === "placement") {
      if (root.placementFromSettings)
        return "Position bar icon \u2014 choose section"
      return (root.mode === "enable" ? "Enable plugin" : "Install plugin")
        + " \u2014 choose bar section"
    }
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
  readonly property string otherFamilyName:
    root.extensionFamily === "chromium" ? "Firefox browsers" : "Chromium browsers"
  readonly property string otherExtensionUrl:
    root.extensionFamily === "chromium" ? root.amoUrl : root.cwsUrl
  readonly property string otherLinkText:
    root.extensionFamily === "chromium" ? "Firefox Add-ons page" : "Chrome Web Store page"

  function openUrl(url) {
    var u = String(url || "")
    if (/^https:\/\//.test(u))
      Quickshell.execDetached(["xdg-open", u])
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

  // The bar's left-click gate tells the browser extension dialog why it
  // intercepted the click: "none" (no installed browser has the
  // extension) or "missing-default" (some browsers have it, the default
  // browser does not); an empty reason means an external summon (the
  // install consent gate) where the neutral wording applies. seen is
  // the browser families the extension already reports into.
  property string extPromptReason: ""
  property var extSeenFamilies: []

  // Names the seen families in the missing-default copy.
  readonly property string extSeenFamiliesPhrase: {
    var fams = []
    for (var i = 0; i < root.extSeenFamilies.length; i++) fams.push(String(root.extSeenFamilies[i]))
    if (fams.indexOf("chrome") >= 0 && fams.indexOf("firefox") >= 0)
      return "Chromium and Firefox browsers"
    if (fams.indexOf("chrome") >= 0) return "Chromium browsers"
    if (fams.indexOf("firefox") >= 0) return "Firefox browsers"
    return "other browsers"
  }

  // Declining the left-click extension dialog is durable: a dismiss
  // marker (which the bar watches) is written, then the overlay closes.
  // The marketplace flow is unaffected: someone who declined the click
  // gate can still install the extension from the plugin page later;
  // that re-stamps extension presence but never clears the dismissal.
  function dismissExtensionPrompt() {
    Quickshell.execDetached(["sh", "-c",
      'umask 077 && mkdir -p "${1%/*}" && printf %s dismissed > "$1"',
      "sh", stateDir + "/browser-prompt-dismissed.json"])
    root.close()
  }

  function open(payloadJson) {
    stopPending()

    var payload = {}
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }

    var newMode = String(payload.mode || "install")
    if (newMode !== "uninstall" && newMode !== "enable" && newMode !== "disable"
        && newMode !== "update" && newMode !== "running"
        && newMode !== "browser-prompt"
        && newMode !== "settings" && newMode !== "settings-confirm") newMode = "install"
    // Stage before mode: the title binding chooses its source from stage, and
    // assigning a browser-* mode while the old stage is still a confirm stage
    // would index the title map with it (undefined -> "Unable to assign
    // [undefined] to QString").
    stage = (newMode === "browser-prompt"
      || newMode === "running" || newMode === "settings"
      || newMode === "settings-confirm")
      ? (newMode === "settings-confirm" ? "settings-confirm" : newMode)
      : (payload.stage === "placement" ? "placement" : "review")
    mode = newMode

    pluginId = String(payload.id || "")
    pluginRepo = String(payload.repo || "")
    pluginName = String(payload.name || pluginId)
    if (mode === "browser-prompt") pluginId = managerId
    if (!pluginName) pluginName = root.managerName

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
    installedVersion = ""

    opened = true

    runningT0 = Date.now()
    // Fresh read of the shared settings (allowUnverified), theme colors, and own manifest on every summon.
    settingsFile.reload()
    themeColorsFile.reload()
    ownManifestFile.reload()

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
      pluginName = root.managerName
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
      // Placement detour requested by the bar popup's Position button:
      // the settings panel opens underneath, then walks straight into the
      // placement step for the plugin named in the payload. This is the
      // same openPlacementFromSettings the Manage rows' Position button
      // calls, so placement's Escape/Close land back on the live
      // settings panel.
      if (mode === "settings" && payload.stage === "placement"
          && validPluginId(String(payload.id || ""))) {
        root.openPlacementFromSettings({
          id: String(payload.id),
          name: String(payload.name || payload.id),
          repo: String(payload.repo || ""),
          version: String(payload.version || ""),
          section: String(payload.section || "")
        })
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

    if (mode === "browser-prompt") {
      // No marketplace data needed: the prompt shows this manager's own
      // name/version (from the shell-loaded manifest) and the detected
      // default browser. The bar's left-click gate adds why it
      // intercepted (reason) and which browser families already have
      // the extension (seenFamilies); anything malformed reads as the
      // neutral install-consent-gate wording.
      root.extPromptReason = (payload.reason === "none"
        || payload.reason === "missing-default") ? payload.reason : ""
      root.extSeenFamilies = Array.isArray(payload.seenFamilies)
        ? payload.seenFamilies.filter(function (f) {
            return f === "chrome" || f === "firefox"
          })
        : []
      catalogLoaded = true
      manifestLoaded = true
      defaultBrowserLoaded = false
      defaultBrowserId = ""
      browserProc.running = true
      return
    }

    catalogProc.running = true
    if (needsManifest) {
      manifestProc.command = ["curl", "-fsSL", "--proto", "=https", "--max-time", "15", "--max-filesize", "16777216", "--", mUrl]
      manifestProc.running = true
    } else {
      manifestLoaded = true
    }
    if (mode === "uninstall" || mode === "enable" || mode === "disable" || mode === "update") listProc.running = true
    if (mode === "update" && installedManifestPath !== "") installedManifestFile.reload()
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

  function sectionIcon(section) {
    if (section === "left") return "\uF036"
    if (section === "centerBegin") return "\uF104"
    if (section === "center") return "\uF037"
    if (section === "centerEnd") return "\uF105"
    if (section === "right") return "\uF038"
    if (section === "tray") return "\uF01C"
    return "\uF037"
  }

  property bool placementFromSettings: false
  property string placementPreviousSection: ""
  // The manager-stage mode ("settings") the placement detour interrupted:
  // placement sets mode to "move", and every return path has to restore
  // it, or settings-stage layout gated on the mode (the identity PiLine)
  // leaks a visible row back into the fixed-height panel.
  property string placementPreviousMode: ""

  function returnPlacementToSettings() {
    if (root.placementPreviousMode !== "")
      root.mode = root.placementPreviousMode
    root.placementPreviousMode = ""
    root.placementFromSettings = false
    root.stage = "settings"
  }

  function openPlacementFromSettings(item) {
    if (!item) return
    root.placementFromSettings = true
    root.placementPreviousMode = root.mode
    root.pluginId = String(item.id || "")
    root.pluginName = String(item.name || item.id || "")
    root.pluginRepo = String(item.repo || "")
    root.pluginVersion = String(item.version || item.installed || "")
    root.placementPreviousSection = String(item.section || "")
    root.mode = "move"
    root.stage = "placement"
  }

  function currentPlacementSection() {
    if (root.placementFromSettings && root.placementPreviousSection !== "")
      return root.placementPreviousSection
    return root.defaultSection
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
    command: ["curl", "-fsSL", "--proto", "=https", "--max-time", "15", "--max-filesize", "16777216", "--", "https://plugins.omarchy.org/catalog.json"]
    stdout: StdioCollector {
      id: catalogProcOut
      waitForEnd: true
    }
    onExited: function (exitCode) {
      if (!root.opened) return
      var raw = String(catalogProcOut.text || "").trim()
      if (exitCode !== 0 || !raw) {
        root.catalogError = "Marketplace catalog could not be fetched"
      } else {
        var entry = null
        try {
          var catalog = JSON.parse(raw)
          var items = Array.isArray(catalog) ? catalog
            : (catalog && Array.isArray(catalog.plugins) ? catalog.plugins : [])
          entry = items.filter(function (item) {
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
          if (String(entry.kind || "").indexOf("Bar widget") !== -1 || entry.category === "Bar widgets" || entry.category === "Widgets") {
            root.isBarWidget = true
          }
        }
      }
      root.catalogLoaded = true
    }
  }

  Process {
    id: manifestProc
    stdout: StdioCollector {
      id: manifestProcOut
      waitForEnd: true
    }
    onExited: function (exitCode) {
      if (!root.opened) return
      var raw = String(manifestProcOut.text || "").trim()
      if (exitCode !== 0 || !raw) {
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
          root.isBarWidget = root.isBarWidget || (m.kinds || []).indexOf("bar-widget") !== -1
          root.defaultSection = (m.barWidget
            && m.barWidget.defaultSection === "center") ? "centerEnd"
            : (m.barWidget && m.barWidget.defaultSection)
              ? String(m.barWidget.defaultSection) : "centerEnd"
        }
      }
      root.manifestLoaded = true
    }
  }

  // The installed clone's own manifest.json: its version field is the
  // "from" side of the update confirmation's version line. Loaded on
  // demand at summon (file watches don't fire on external writes in this
  // environment, so a path that did not change still needs an explicit
  // reload); a missing or unreadable manifest just means no version line.
  FileView {
    id: installedManifestFile
    path: root.installedManifestPath
    printErrors: false
    onLoaded: {
      var v = ""
      try { v = String(JSON.parse(text()).version || "") } catch (e) { v = "" }
      root.installedVersion = v
    }
    onLoadFailed: root.installedVersion = ""
  }

  // Local state check for uninstall/enable/disable: validates and, when the
  // plugin is in the right state, moves to the mode's confirm stage.
  Process {
    id: listProc
    command: ["omarchy", "plugin", "list", "--json"]
    stdout: StdioCollector {
      id: listProcOut
      waitForEnd: true
    }
    onExited: function (exitCode) {
      if (!root.opened) return
      if (exitCode !== 0) {
        if (root.stage === "review") root.catalogError = "Could not read the local plugin list"
        return
      }
      var entry = null
      try {
        var plugins = JSON.parse(String(listProcOut.text || "[]"))
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
    onTriggered: {
      settingsPayloadFile.reload()
      ownManifestFile.reload()
    }
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
      'umask 077 && mkdir -p "${1%/*}" && printf %s "$3" | head -c "$2" > "$1"',
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
        if (key === "updateChecking") {
          if (d.updateChecking === true
              || (d.lastCheckText && d.lastCheckText !== root.snapStr("lastCheckText"))
              || (Date.now() - root.refreshRequestedAt > 15000)) {
            delete next[key]
            retired = true
          } else {
            d[key] = next[key]
          }
        } else if (d[key] === next[key]) {
          delete next[key]
          retired = true
        } else {
          d[key] = next[key]
        }
      }
      if (retired) root.settingsPending = next
    }
    // Same confirm-or-keep retirement for the enable echoes: a snapshot
    // row that carries the requested state confirms the click (the echo
    // was true all along - the widget's own override took over from the
    // command on), so the entry goes; one that still contradicts it keeps
    // the hold until the 4s window expires (a failed toggle reverting to
    // reality exactly once, on that snapshot).
    var pend = root.pendingEnable
    var pendKeys = Object.keys(pend)
    if (pendKeys.length > 0) {
      var confirmed = ({})
      var anyConfirmed = false
      var nowMs = Date.now()
      for (var pi = 0; pi < pendKeys.length; pi++) {
        var pk2 = pendKeys[pi]
        var pe = pend[pk2]
        var row = null
        var prows = Array.isArray(d.plugins) ? d.plugins : []
        for (var ri = 0; ri < prows.length; ri++)
          if (prows[ri] && String(prows[ri].id || "") === pk2) row = prows[ri]
        if ((row && row.enabled === pe.enable) || nowMs - Number(pe.at) > 6000) {
          anyConfirmed = true
          continue
        }
        confirmed[pk2] = pe
      }
      if (anyConfirmed) root.pendingEnable = confirmed
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

  // ---- settings-panel tab bar (Updates / Manage / Settings / About) ------
  // OmApple panel style: an icon, a title, and a one-line description per
  // tab in a left rail (see the tab delegate in the settings stage).
  property string settingsTab: "updates"
  // (Literal glyphs: the U+F04xx/F03xx icons are plane-15 codepoints, and
  // the QML lexer's \u escapes consume exactly 4 hex digits, so they must
  // be written as literal characters, not escapes.)
  readonly property var settingsTabModel: [
    { key: "updates",  iconText: "󰑐", title: "Updates",
      desc: "Plugin updates" },
    { key: "manage",   iconText: "󰏓", title: "Manage",
      desc: "Installed plugins" },
    { key: "settings", iconText: "󰒓", title: "Settings",
      desc: "Update behaviour" },
    { key: "about",    iconText: "󰋽", title: "About",
      desc: "What this does" },
  ]
  // The settings card is a fixed size: the OmApple panel's own dimensions
  // (968x682) per the OmApple reference, dialed back 15% on the height
  // (580), then grown 10% back on it (638); shrunk further only when the
  // panel itself is smaller.
  // Every height the tab bodies need derives from this root property,
  // because a body that sizes the column that sizes the card, reading
  // the card back, is a binding loop.
  readonly property real settingsCardHeight: Math.min(Style.space(638),
    panel.height - Style.space(48))
  // The active tab's rail entry (title + desc), reused by the category
  // title header above the tab body.
  function settingsTabEntry() {
    for (var i = 0; i < settingsTabModel.length; i++) {
      if (settingsTabModel[i].key === settingsTab) {
        // The Manage header keeps the installed-plugin count live.
        if (settingsTab === "manage" && root.snapBool("pluginsListed"))
          return {
            title: settingsTabModel[i].title,
            desc: settingsTabModel[i].desc
              + "  \u00b7  " + root.snapList("plugins").length,
          }
        return settingsTabModel[i]
      }
    }
    return {}
  }
  // Plugin whose Manage row has its section chooser expanded, "" for none.
  property string manageMoveForId: ""
  // Enable echo window: id -> {enable, at} for the last click. The widget
  // only learns the toggle through the cmd file a moment after the click,
  // and a plugin-list read that STARTED before the click can PUBLISH after
  // it: that snapshot row carries pre-toggle truth, wipes a one-shot local
  // patch, and the switch flips back before the post-CLI truth lands (the
  // seen switch-back-again flicker). managePlugins() holds the row at the
  // clicked value for a short window instead, re-evaluated on every
  // snapshot: a successful toggle makes the truth match the echo (the
  // overlay no-ops), a failed one reverts to reality when the window
  // closes - and the widget's own override keeps the row steady from the
  // moment the command is processed on.
  property var pendingEnable: ({})
  function managePlugins() {
    var pe = root.pendingEnable
    var now = Date.now()
    var list = root.snapList("plugins")
    var out = []
    for (var i = 0; i < list.length; i++) {
      var r = list[i]
      if (!r) { out.push(r); continue }
      var p = pe[String(r.id || "")]
      if (p && now - Number(p.at) < 4000 && r.enabled !== p.enable) {
        var o = ({})
        for (var k in r) o[k] = r[k]
        o.enabled = p.enable
        out.push(o)
      } else {
        out.push(r)
      }
    }
    return out
  }
  // Manage-tab search filter: the input field's text, matched case-
  // insensitively against every row's name and id.
  property string manageFilter: ""
  // Manage-tab state filter: "" (both), "enabled" or "disabled", toggled
  // by the two filter buttons beside the search field. It composes with
  // the search text, and it is applied after managePlugins()' optimistic
  // override, so a row the user just toggled follows along immediately.
  property string manageStateFilter: ""
  function manageFilteredRows() {
    var q = root.manageFilter.trim().toLowerCase()
    var st = root.manageStateFilter
    var rows = root.managePlugins()
    if (q === "" && st === "") return rows
    return rows.filter(function (r) {
      if (!r) return false
      if (st !== "" && Boolean(r.enabled) !== (st === "enabled")) return false
      if (q === "") return true
      var hay = (String(r.name || "") + " " + String(r.id || "")
        + " " + String(r.author || "") + " " + String(r.desc || "")
        + " " + String(r.description || ""))
        .toLowerCase()
      return hay.indexOf(q) !== -1
    })
  }
  // Render identity of the manage list. The Repeater renders from
  // manageRenderRows instead of filteredPlugins directly: the model is
  // only re-assigned - which destroys and re-creates every card,
  // momentarily collapses contentHeight and clamps contentY to 0 - when
  // the row id set or order changes, i.e. on a filter/search edit, an
  // install, an uninstall or a move. Snapshot echoes and optimistic
  // enable/disable patches keep the same ids, so the existing cards
  // simply repaint through their delegate's live `row` lookup and the
  // scroll position is never destroyed at all.
  readonly property string manageRenderSig: {
    var rows = root.filteredPlugins
    var s = ""
    for (var i = 0; i < rows.length; i++)
      s += (i > 0 ? "|" : "") + String(rows[i] ? rows[i].id : "?")
    return s
  }
  property var manageRenderRows: []
  onManageRenderSigChanged: manageRenderRows = root.filteredPlugins
  // Scroll-position hold, the safety net under that: a rebuild the id
  // signature cannot avoid (a plugin installed or removed elsewhere)
  // still flashes contentHeight through its collapsed value, and
  // StopAtBounds clamps contentY to 0 in that window. Track the last
  // real scroll offset on every contentY change and re-assert it as the
  // rebuilt cards restore contentHeight. Search/state-filter edits
  // still land at the top: they change which rows exist, so the old
  // offset is meaningless.
  property real manageSavedY: -1
  property string manageSavedFilter: ""
  property string manageSavedState: ""
  property bool manageRestoring: false
  // Where and when the hold last wrote contentY. The Flickable answers
  // a restore write with a sub-pixel correction of its own (118.5 ->
  // 119) just after the restoring flag has fallen; that correction must
  // not be mistaken for a user scroll, or the hold is silently retargeted
  // to the collapsed position and the list stays pinned near the top.
  property int manageRestoreAtMs: 0
  property real manageRestoreY: -1
  Connections {
    target: pluginCardsFlickable
    function onContentYChanged() {
      // A restore write is mid-burst clamped by the partially rebuilt
      // content; it must not overwrite the saved offset we are aiming at.
      if (root.manageRestoring)
        return
      var y = pluginCardsFlickable.contentY
      if (y > 0 && root.manageSavedY > 0
        && Date.now() - root.manageRestoreAtMs < 250
        && Math.abs(y - root.manageRestoreY) <= 2)
        return
      if (y > 0) {
        root.manageSavedY = y
        return
      }
      // y==0 with full content height = a real user scroll to the top
      // (forget the hold); y==0 while contentHeight has collapsed is the
      // rebuild clamp itself (keep the hold).
      if (pluginCardsFlickable.contentHeight - pluginCardsFlickable.height
        >= root.manageSavedY)
        root.manageSavedY = 0
    }
    function onContentHeightChanged() {
      if (root.manageSavedY <= 0)
        return
      var maxY = Math.max(0, pluginCardsFlickable.contentHeight
        - pluginCardsFlickable.height)
      if (pluginCardsFlickable.contentY < root.manageSavedY && maxY > 0) {
        var target = Math.min(root.manageSavedY, maxY)
        root.manageRestoring = true
        root.manageRestoreAtMs = Date.now()
        root.manageRestoreY = target
        pluginCardsFlickable.contentY = target
        root.manageRestoring = false
      }
    }
  }
  // Filter/search edits (which also swap the model) still reset the list
  // to the top instead of re-asserting the hold.
  function manageScrollModelSwapped() {
    if (manageFilter !== manageSavedFilter
      || manageStateFilter !== manageSavedState) {
      manageSavedFilter = manageFilter
      manageSavedState = manageStateFilter
      manageSavedY = -1
      pluginCardsFlickable.contentY = 0
    }
  }
  // The installed-plugin snapshot row for an id, or null when the list
  // has no row (yet).
  function pluginRowById(id) {
    var list = root.managePlugins()
    for (var i = 0; i < list.length; i++)
      if (list[i] && String(list[i].id) === String(id)) return list[i]
    return null
  }
  // Update-snapshot rows prepared for PiPluginCard: the update lists carry
  // only {id, name, from, to, verified}, so each row is copied and joined
  // with the installed-plugin row (live enable state, bar section,
  // bar-widget kind, catalog author/description/repo). installed/latest
  // and from/to are normalized to the same pair so the card's Update
  // confirm and version pill read either spelling; updateAvailable marks
  // every row as an available update and updatable carries whether the
  // bar would actually apply it under the verification setting.
  function updatesCardRows(items) {
    var out = []
    for (var i = 0; i < (items || []).length; i++) {
      var u = items[i]
      if (!u) continue
      var o = {}
      for (var k in u) o[k] = u[k]
      var inst = root.pluginRowById(String(o.id || ""))
      if (inst) {
        o.author = inst.author
        o.desc = inst.desc
        o.repo = inst.repo
        o.enabled = inst.enabled
        o.isBarWidget = inst.isBarWidget
        o.kinds = inst.kinds
        if (!o.section) o.section = inst.section
        if (!o.name) o.name = inst.name
      }
      o.installed = String(o.installed || o.from || "")
      o.latest = String(o.latest || o.to || "")
      o.from = o.installed
      o.to = o.latest
      // Every row is an available update (drives badge/border); whether it
      // is actionable mirrors the bar's eligibleUpdates(): verified rows
      // always, unverified ones only while the opt-in is on.
      o.updateAvailable = true
      o.updatable = (o.verified === true) || root.snapBool("allowUnverified")
      out.push(o)
    }
    return out
  }
  // The plugin page on plugins.omarchy.org for a row's id (the same page
  // the catalog links to; the id is payload-sourced and url-encoded).
  function pluginPageUrl(id) {
    return "https://plugins.omarchy.org/plugin.html?id="
      + encodeURIComponent(String(id || ""))
  }
  // Open a plugin's marketplace page: the widget dispatches open_url after
  // re-validating the https scheme, then closes the panel (the page is the
  // point of the click, same dismissal as the store buttons).
  function openPluginPageAndClose(id) {
    root.writeSettingsCmd({ action: "open_url", url: root.pluginPageUrl(id) })
    root.close()
  }
  // Counter shown after the Updates tab title: the total available updates
  // spelled out by kind (verified + unverified), so both stay explicit the
  // way the two list sections keep them apart.
  function settingsVerifiedCount() {
    return root.snapList("verified").length
  }
  function settingsUnverifiedCount() {
    return root.snapList("unverified").length
  }
  function settingsUpdateBadgeText() {
    var v = root.settingsVerifiedCount()
    var u = root.settingsUnverifiedCount()
    if (v > 0 && u > 0) return v + " + " + u
    return v > 0 ? String(v) : String(u)
  }
  function settingsUpdateCountsText() {
    var v = root.settingsVerifiedCount()
    var u = root.settingsUnverifiedCount()
    var parts = []
    if (v > 0) parts.push(v + " verified")
    if (u > 0) parts.push(u + " unverified")
    if (parts.length === 0) return "No plugin updates available"
    var n = v + u
    return n + " plugin update" + (n === 1 ? "" : "s") + " available: "
      + parts.join(", ")
      + (u > 0 && !root.snapBool("allowUnverified")
        ? " (unverified ones need the Settings-tab toggle)" : "")
  }
  // Move a plugin's bar icon from the Manage tab: patch the row locally so
  // the section label updates at once, and the widget re-validates and runs
  // the same move chain the popup's move row uses, then republishes (a
  // failed move republishes the old section and the patch reverts).
  function manageMove(id, section) {
    var list = root.snapList("plugins").map(function (r) {
      if (r && String(r.id) === String(id)) {
        var o = {}
        for (var k in r) o[k] = r[k]
        o.section = String(section)
        return o
      }
      return r
    })
    root.snapPatch({ plugins: list })
    root.manageMoveForId = ""
    root.writeSettingsCmd({ action: "move_icon", id: String(id),
      section: String(section) })
  }
  // Enable/disable from a Manage row: same optimistic echo as the move
  // (the row flips at once); the widget validates the id grammar, runs
  // omarchy plugin enable/disable, reloads the plugin list, and
  // republishes, so a failed toggle lands back on the real state.
  function manageToggle(id, enable) {
    // Arm the echo window (see managePlugins) and flip the local snapshot
    // for the instant paint; the window then holds the row steady across
    // any stale or override-free republish until the CLI truth lands.
    var pe = ({})
    for (var pk in root.pendingEnable) pe[pk] = root.pendingEnable[pk]
    pe[String(id)] = { enable: enable === true, at: Date.now() }
    root.pendingEnable = pe
    var list = root.snapList("plugins").map(function (r) {
      if (r && String(r.id) === String(id)) {
        var o = {}
        for (var k in r) o[k] = r[k]
        o.enabled = enable === true
        return o
      }
      return r
    })
    root.snapPatch({ plugins: list })
    var name = ""
    for (var i = 0; i < list.length; i++)
      if (list[i] && String(list[i].id) === String(id))
        name = String(list[i].name || "")
    root.writeSettingsCmd({ action: "run_toggle", id: String(id),
      enable: enable === true, name: name })
  }
  // Open a plugin's repository from its Manage row: the widget execs
  // xdg-open after re-validating the https scheme. The panel deliberately
  // stays open (a browser tab steals focus anyway, and the click-away
  // handler would close the panel the moment it loses focus).
  function manageOpenUrl(url) {
    root.writeSettingsCmd({ action: "open_url", url: String(url || "") })
  }
  // Can this row's plugin be summoned as a window? Mirrors the shell's own
  // panel loader rule: only panel/overlay/menu entry kinds get a panel
  // Loader, and a disabled plugin has none to summon (the CLI refuses it).
  // Bar widgets open through the bar itself, and their row carries the
  // position button instead.
  function rowIsSummonable(row) {
    if (!row || row.enabled !== true || row.isBarWidget) return false
    if (row.section) return false
    var kinds = row.kinds
    if (!Array.isArray(kinds)) return false
    return kinds.indexOf("panel") !== -1 || kinds.indexOf("overlay") !== -1
      || kinds.indexOf("menu") !== -1
  }
  // Open button on a summonable Manage row: the bar routes this to the
  // shell CLI (omarchy-shell shell summon <id>), the documented way to
  // open one of these plugins. The panel stays open, like every other
  // row action.
  function manageSummonPlugin(row) {
    if (!root.rowIsSummonable(row)) return
    root.writeSettingsCmd({ action: "summon_plugin", id: String(row.id || "") })
  }
  function openExternalUrl(url) {
    root.manageOpenUrl(url)
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
  property double refreshRequestedAt: 0
  function refreshUpdates() {
    if (root.snapBool("updateChecking")) return
    root.snapPatch({ updateChecking: true })
    root.markPending("updateChecking", true)
    root.refreshRequestedAt = Date.now()
    root.writeSettingsCmd({ action: "refresh" })
  }
  // Queue the store launch (the widget execs the family's browser when it
  // dispatches the command) and close the panel right away, the way the
  // install prompt's openExtensionPage() dismisses itself: the store page
  // is the point of the click, and the panel has nothing left to show.
  // open_store lands before close()'s "closed" line in the append log, so
  // the widget's in-order dispatch still launches the browser.
  function openStoreAndClose(urlKey, binKey) {
    root.writeSettingsCmd({
      action: "open_store", url: root.snapStr(urlKey),
      bin: root.snapStr(binKey)
    })
    root.close()
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

  // Active theme palette colors (colors.toml): used for semantic badges
  // such as the verified / unverified status in the install confirmation panel.
  readonly property string themeColorsPath: {
    var base = Quickshell.env("XDG_STATE_HOME")
    if (!base) base = (Quickshell.env("HOME") || "/tmp") + "/.local/state"
    return base + "/omarchy/current/theme/colors.toml"
  }
  property string themeSuccessColor: "#cfd7c5"
  property string themeWarningColor: "#d79921"

  FileView {
    id: themeColorsFile
    path: root.themeColorsPath
    printErrors: false
    onLoaded: root.parseThemeColors(text())
  }

  function parseThemeColors(raw) {
    var lines = String(raw || "").split("\n")
    var green = ""
    var yellow = ""
    var orange = ""
    var red = ""
    for (var i = 0; i < lines.length; i++) {
      var m = lines[i].match(/^\s*([A-Za-z0-9_-]+)\s*=\s*["']?(#[0-9A-Fa-f]{3,8})/)
      if (!m) continue
      var k = m[1].toLowerCase()
      if (k === "green" || (k === "color2" && !green)) green = m[2]
      else if (k === "yellow" || (k === "color3" && !yellow)) yellow = m[2]
      else if (k === "orange") orange = m[2]
      else if (k === "red" || (k === "color1" && !red)) red = m[2]
    }
    if (green) root.themeSuccessColor = green
    var warn = yellow || orange || red
    if (warn) root.themeWarningColor = warn
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
    themeColorsFile.reload()
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
    // omarchy-browser.desktop is Omarchy's launcher wrapper and names no
    // browser family, so that answer (or an empty one) is resolved via
    // omarchy-cmd-default-browser, the reader the wrapper itself uses.
    command: ["bash", "-c",
      "b=$(xdg-settings get default-web-browser 2>/dev/null || true);"
      + " if [ -z \"$b\" ] || [ \"$b\" = omarchy-browser.desktop ]"
      + " && [ -x \"${OMARCHY_PATH:-/usr/share/omarchy}/bin/omarchy-cmd-default-browser\" ]; then"
      + " d=$(\"${OMARCHY_PATH:-/usr/share/omarchy}/bin/omarchy-cmd-default-browser\" 2>/dev/null || true);"
      + " [ -n \"$d\" ] && b=$d; fi;"
      + " [ -n \"$b\" ] || b=$(xdg-mime query default x-scheme-handler/https 2>/dev/null || true);"
      + " printf %s \"$b\""]
    stdout: StdioCollector {
      id: browserProcOut
      waitForEnd: true
    }
    onExited: function (exitCode) {
      if (!root.opened) return
      var val = String(browserProcOut.text || "").trim()
      root.defaultBrowserId = exitCode === 0 ? val : ""
      root.defaultBrowserLoaded = true
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
    // Cross-check every marker's self-reported started against the file's
    // real mtime (and the clock) before trusting it: the content is written
    // once by the worker, so a marker whose timestamp disagrees with its
    // mtime was not written by a worker and is deleted on the spot.
    command: ["bash", "-c",
      "for f in \"$1\"/*.json; do [ -e \"$f\" ] || exit 0; m=$(stat -c %Y \"$f\" 2>/dev/null) || continue; now=$(date +%s); out=$(jq -c --argjson m \"$m\" --argjson now \"$now\" 'select(type==\"object\" and (((.started // null)|type)==\"number\") and .started >= $m-120 and .started <= $m+120 and .started <= $now+60)' \"$f\" 2>/dev/null); if [ -n \"$out\" ]; then echo \"$out\"; else rm -f \"$f\"; fi; done",
      "bpm-boot", root.markerDir]
    stdout: StdioCollector {
      id: bootScanProcOut
      waitForEnd: true
    }
    onExited: function (exitCode) {
      if (root.opened || exitCode !== 0) return
      var entries = root.freshMarkerEntries(String(bootScanProcOut.text || ""))
      if (entries.length === 0) return
      var newest = entries[entries.length - 1]
      var payload = { source: "boot", mode: "running",
        id: String(newest.id || ""), name: String(newest.name || ""),
        action: String(newest.mode || "install") }
      root.open(JSON.stringify(payload))
    }
  }

  Process {
    id: markerProc
    // Same mtime cross-check as the boot scan: a marker whose started
    // timestamp disagrees with the file's real mtime is not from a worker
    // and is deleted instead of keeping the running panel open.
    command: ["bash", "-c",
      "for f in \"$1\"/*.json; do [ -e \"$f\" ] || exit 0; m=$(stat -c %Y \"$f\" 2>/dev/null) || continue; now=$(date +%s); out=$(jq -c --argjson m \"$m\" --argjson now \"$now\" 'select(type==\"object\" and (((.started // null)|type)==\"number\") and .started >= $m-120 and .started <= $m+120 and .started <= $now+60)' \"$f\" 2>/dev/null); if [ -n \"$out\" ]; then echo \"$out\"; else rm -f \"$f\"; fi; done",
      "bpm-marker", root.markerDir]
    stdout: StdioCollector {
      id: markerProcOut
      waitForEnd: true
    }
    onExited: function () {
      root.onMarkers(String(markerProcOut.text || ""))
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

  // Empty-state companion to the globe: a wireframe cardboard box with its
  // top flaps open, drawn in the globe's visual language - depth decides
  // edge alpha, the same twinkling star field scatters around it, and a
  // few accent sparkles drift out of the opening. It turns slowly on its
  // axis and bobs on a sine. The motion never has a loop seam: every
  // moving part is a smooth, endless function of time (the yaw simply
  // keeps turning, the bob/flap sway are sine terms, and each sparkle
  // fades in from zero alpha and back to zero before its cycle restarts).
  // Colors come from the live palette like paintGlobe's.
  function paintEmptyBox(ctx, W, H, t, gridCol, dotCol, starCol) {
    // Same reference-unit scaling as the globe: identical scene feel at
    // any canvas size.
    var sc = H / 120
    var cx = W / 2, cy = H / 2
    var rgba = function (c, a) {
      return "rgba(" + c[0] + "," + c[1] + "," + c[2] + "," + a.toFixed(3) + ")"
    }
    // Geometry (reference units): box half-extents and flap length.
    var a = 23, b = 17, h = 19, f = 12
    var yaw = t * 0.16                          // endless slow turn
    var pitch = 0.4 + 0.04 * Math.sin(t * 0.5)  // lean showing the opening
    var bob = 2.2 * Math.sin(t * 0.9)           // gentle float
    var cosY = Math.cos(yaw), sinY = Math.sin(yaw)
    var cosP = Math.cos(pitch), sinP = Math.sin(pitch)
    var proj = function (x, y, z) {
      var x1 = x * cosY + z * sinY
      var z1 = -x * sinY + z * cosY
      var y2 = y * cosP - z1 * sinP
      var z2 = y * sinP + z1 * cosP
      return { x: cx + x1 * sc, y: cy - (y2 + bob) * sc, z: z2 }
    }
    var edgeAlpha = function (z, boost) {
      var nz = Math.max(-1, Math.min(1, z / 34))
      var al = nz >= 0 ? 0.2 + 0.55 * nz : 0.08
      return boost ? Math.min(1, al * 1.5) : al
    }
    ctx.clearRect(0, 0, W, H)
    // Stars: the globe's deterministic scatter and twinkle, kept clear of
    // the box's footprint so they read as backdrop, not clutter.
    for (var i = 0; i < 26; i++) {
      var sx = (i * 97 + 31) % W, sy = (i * 53 + 17) % H
      var sdx = sx - cx, sdy = sy - cy
      if (sdx * sdx + sdy * sdy < (a + 10) * (a + 10) * sc * sc) continue
      ctx.fillStyle = rgba(starCol, 0.18 + 0.15 * Math.sin(t * 1.3 + i * 2.1))
      ctx.fillRect(sx, sy, 1.4, 1.4)
    }
    // Every edge is collected with its mean depth, then drawn far-to-near
    // so the fainter back edges never overprint the brighter front ones.
    var edges = []
    var addEdge = function (p, q, boost) {
      edges.push({ p: p, q: q, z: (p.z + q.z) / 2, b: boost })
    }
    var corners = [[-a, -b], [a, -b], [a, b], [-a, b]]
    var norms = [[0, -1], [1, 0], [0, 1], [-1, 0]]
    for (var ci = 0; ci < 4; ci++) {
      var c1 = corners[ci], c2 = corners[(ci + 1) % 4]
      // Bottom ring, top rim (boosted: it frames the opening), stiles.
      addEdge(proj(c1[0], -h, c1[1]), proj(c2[0], -h, c2[1]), false)
      addEdge(proj(c1[0], h, c1[1]), proj(c2[0], h, c2[1]), true)
      addEdge(proj(c1[0], -h, c1[1]), proj(c1[0], h, c1[1]), false)
      // Open flap on this rim edge: hinged at the rim, tilted outward and
      // slightly up, with an easy per-flap sway (sine terms -> seamless).
      var n = norms[ci]
      var fb = 0.3 + 0.045 * Math.sin(t * 1.15 + ci * 1.7)
      var ox = Math.cos(fb) * n[0] * f, oz = Math.cos(fb) * n[1] * f
      var oy = Math.sin(fb) * f
      var t1 = proj(c1[0] + ox, h + oy, c1[1] + oz)
      var t2 = proj(c2[0] + ox, h + oy, c2[1] + oz)
      addEdge(proj(c1[0], h, c1[1]), t1, false)
      addEdge(proj(c2[0], h, c2[1]), t2, false)
      addEdge(t1, t2, false)
    }
    edges.sort(function (u, v) { return u.z - v.z })
    ctx.lineWidth = 1
    for (var ei = 0; ei < edges.length; ei++) {
      var e = edges[ei]
      ctx.beginPath()
      ctx.moveTo(e.p.x, e.p.y)
      ctx.lineTo(e.q.x, e.q.y)
      ctx.strokeStyle = rgba(gridCol, edgeAlpha(e.z, e.b))
      ctx.stroke()
    }
    // Sparkles: three motes of accent light drift up and out of the open
    // box. Each fades in from nothing and back to nothing, so its cycle
    // restart is invisible (this is what keeps the loop seamless).
    for (var k = 0; k < 3; k++) {
      var cyc = (t * 0.22 + k / 3) % 1
      var alpha = 0.85 * Math.sin(Math.PI * cyc)
      if (alpha <= 0.02) continue
      var rise = -h + (2 * h + 16) * cyc
      var wob = 6 * Math.sin(t * 1.7 + k * 2.4)
      var sp = proj(wob, rise, wob * 0.4)
      var r = (1.1 + 0.5 * Math.sin(t * 2.3 + k)) * sc
      ctx.beginPath()
      ctx.arc(sp.x, sp.y, Math.max(0.6, r), 0, 6.2832)
      ctx.fillStyle = rgba(dotCol, alpha * 0.9)
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
  // All three modes share one file worker (bin/omarchy-plugin-worker): the
  // positional parameters ($1=mode, $2=id, $3=name, $4=repo, $5=bar section
  // or — for update — the verified commit pin) ride directly on execve
  // argv, avoiding temporary script files and shell interpolation. The
  // pinned-update logic is the shared bin/omarchy-plugin-update apply, so
  // confirming a verified update here loads exactly the reviewed commit or
  // nothing at all, like the bar widget's updater.

  function spawnWorker(kind, section) {
    Quickshell.execDetached([
      "bash", root.pluginDir + "/bin/omarchy-plugin-worker",
      kind,
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
      id: enableProcOut
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: enableProcErr
      waitForEnd: true
    }
    onExited: function (exitCode) {
      if (!root.opened) return
      root.enableOutput = (String(enableProcOut.text || "") + "\n" + String(enableProcErr.text || "")).trim()
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
      id: verifyProcOut
      waitForEnd: true
    }
    onExited: function (exitCode) {
      if (!root.opened) return
      if (exitCode !== 0) {
        root.fail("omarchy plugin list exited with code " + exitCode)
        return
      }
      var entry = null
      try {
        var plugins = JSON.parse(String(verifyProcOut.text || "[]"))
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
        // successful install of the manager (see bin/omarchy-plugin-worker).
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

  Process {
    id: disableProc
    stdout: StdioCollector { id: disableProcOut; waitForEnd: true }
    stderr: StdioCollector { id: disableProcErr; waitForEnd: true }
    onExited: function (exitCode) {
      if (!root.opened) return
      root.enableOutput = (String(disableProcOut.text || "") + "\n" + String(disableProcErr.text || "")).trim()
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
    // Optional leading glyph (Nerd Font icon), rendered left of the label.
    property string iconText: ""
    property string tooltipText: ""
    property bool spin: false
    property int labelPixelSize: Style.font.body
    property bool primary: false
    property bool danger: false
    property bool active: false
    readonly property color tone: danger
      ? Color.urgent
      : primary ? Color.accent : Color.foreground
    readonly property bool hot: piMouse.containsMouse
    signal clickedPi

    // With iconText set, the row's implicit width covers both texts;
    // empty, it collapses to just the label, exactly as before.
    implicitWidth: piButtonRow.implicitWidth + Style.space(36)
    implicitHeight: Style.space(34)
    width: implicitWidth
    height: implicitHeight
    radius: Style.cornerRadius
    color: active
      ? Util.alpha(Color.accent, 0.25)
      : (!enabled ? "transparent"
        : primary || danger
          ? (hot ? Util.alpha(tone, 0.2) : Util.alpha(tone, 0.12))
          : (hot ? Util.alpha(Color.foreground, 0.12) : Util.alpha(Color.foreground, 0.05)))
    borderSpec: Border.flat(active ? Color.accent
      : (enabled
        ? (primary || danger ? tone : Util.alpha(Color.foreground, 0.3))
        : Util.alpha(Color.foreground, 0.2)),
      1)

    // Row, not a lone centered Text, so an iconText glyph can sit left of
    // the label; the positioner skips the invisible icon text, so a label
    // button still renders exactly as before.
    Row {
      id: piButtonRow
      anchors.centerIn: parent
      spacing: piButton.iconText !== "" ? Style.space(10) : 0
      Text {
        id: piIconText
        visible: piButton.iconText !== ""
        anchors.verticalCenter: piButtonRow.verticalCenter
        text: piButton.iconText
        color: piButton.active ? Color.accent
          : (piButton.enabled
            ? (piButton.primary || piButton.danger ? piButton.tone : Color.foreground)
            : Util.alpha(Color.foreground, 0.35))
        font.family: Style.font.family
        font.pixelSize: Style.font.icon
      }
      Text {
        id: labelText
        anchors.verticalCenter: piButtonRow.verticalCenter
        text: piButton.label
        color: piButton.active ? Color.accent
          : (piButton.enabled
            ? (piButton.primary || piButton.danger ? piButton.tone : Color.foreground)
            : Util.alpha(Color.foreground, 0.35))
        font.family: Style.font.family
        font.pixelSize: piButton.labelPixelSize
        font.bold: piButton.primary || piButton.danger || piButton.active
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

  // Bordered icon button in the OmApple plugins-list idiom: a bare glyph,
  // the shell's control spec (normal -> hover-cursor), and a tooltip naming
  // the action. Used for every per-row Manage action.
  component PiIconButton: BorderSurface {
    id: piIconBtn
    property string iconText: ""
    property string tooltipText: ""
    property bool spin: false
    property bool active: false
    property real iconSize: Style.font.body + 2
    property color tone: Color.foreground
    signal clickedPi

    implicitWidth: Style.space(34)
    implicitHeight: Style.space(30)
    width: implicitWidth
    height: implicitHeight
    radius: Style.cornerRadius
    padding: 0
    color: active
      ? Util.alpha(Color.accent, 0.25)
      : (piIconMouse.containsMouse
        ? Style.hoverFillFor(Color.foreground, tone) : "transparent")
    borderSpec: active
      ? Border.flat(Color.accent, 1)
      : Border.controlSpec(piIconMouse.containsMouse
        ? "hover-cursor" : "normal", Color.foreground, tone)

    Text {
      id: piIconBtnText
      anchors.centerIn: parent
      text: piIconBtn.iconText
      color: piIconBtn.enabled ? piIconBtn.tone
        : Util.alpha(Color.foreground, 0.35)
      font.family: Style.font.family
      font.pixelSize: piIconBtn.iconSize
      transformOrigin: Item.Center
      // Same NumberAnimation-not-RotationAnimator rule as PiButton: the
      // shell's composited windows do not advance render-thread animators.
      NumberAnimation on rotation {
        from: 0
        to: 360
        duration: 900
        loops: Animation.Infinite
        running: piIconBtn.spin
        onRunningChanged: if (!running) piIconBtnText.rotation = 0
      }
    }
    MouseArea {
      id: piIconMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: piIconBtn.clickedPi()
    }
    PanelToolTip {
      visible: piIconMouse.containsMouse && piIconBtn.tooltipText !== ""
      text: piIconBtn.tooltipText
    }
  }

  // Plain text on purpose: every line here can carry remote marketplace
  // metadata (catalog author, version, license, repo, manifest errors).
  // AutoText would interpret markup in it, so a remote <img src=...> tag
  // would fetch from the network before the user installed anything.
  component PiLine: Text {
    // Fill the containing column/row: the settings panel nests these inside
    // tab bodies narrower than the card, so the width comes from the parent
    // (same ownership as PiUpdateSection).
    width: parent ? parent.width : 0
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
    width: parent ? parent.width : 0
    height: 1
    color: Util.alpha(Color.foreground, 0.15)
  }

  // RichText line with clickable <a href> links; activation opens the URL
  // in the default browser via xdg-open. Colors come from the inline style
  // in root.linkTag (RichText ignores Text.linkColor).
  component PiTextLink: Text {
    width: parent ? parent.width : 0
    wrapMode: Text.Wrap
    textFormat: Text.RichText
    color: Util.alpha(Color.foreground, 0.75)
    font.family: Style.font.family
    font.pixelSize: Style.font.body
    property bool closeOnActivate: false
    onLinkActivated: function (link) {
      root.openUrl(link)
      if (closeOnActivate) root.close()
    }
  }

  // Caption-size RichText line: used by the browser-store support lists,
  // where the HTML is built locally from hardcoded family labels (the
  // widget wraps installed browsers in an accent span). No links, so no
  // href is reachable from it.
  component PiRichLine: Text {
    width: parent ? parent.width : 0
    wrapMode: Text.Wrap
    textFormat: Text.RichText
    color: Color.muted
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
  }

  // Shared plugin card for both settings lists: the Manage tab's full
  // installed set and the two Updates-tab lists render the identical
  // card (the Manage Repeater used this markup inline; it is now a named
  // component so both lists share it). A bordered surface - accent when
  // the row is updatable - with a letter avatar, name and version pill
  // ("v{from} -> v{to}" whenever a row carries two different versions,
  // plain "v{installed}" otherwise), a "by {author} . {id}" meta line,
  // an Update Available badge and the shell enable/disable switch, the
  // plugin description, and the action row: the marketplace page and the
  // repository link on the left, and Update (arms the same settings-confirm
  // gate the batch action uses), Position bar icon (bar widgets and placed
  // plugins) and Remove (uninstall gate) right-aligned underneath the
  // toggle. Every string comes from the widget's
  // snapshot, and plain-text Text keeps remote names inert.
  component PiPluginCard: BorderSurface {
                      id: pluginCard
                      // The row object this card paints. Defaults to the
                      // Repeater context's modelData (the Updates tab's
                      // PiUpdateSection keeps working unchanged); the
                      // manage list overrides it with a live lookup so
                      // snapshot echoes and enable/disable patches update
                      // the card in place instead of rebuilding every
                      // card (a rebuild collapses the list's
                      // contentHeight and jumps the scroll position).
                      property var row: modelData
                      width: parent.width
                      implicitHeight: pluginCardCol.implicitHeight + Style.space(28)
                      height: implicitHeight
                      color: Util.alpha(root.foreground, 0.03)
                      borderSpec: (row.updateAvailable || row.updatable)
                        ? Border.flat(Color.accent, 1)
                        : (Boolean(row.installed || row.version) ? Border.flat(Util.alpha(root.foreground, 0.16), 1) : Border.none())
                      radius: Style.cornerRadius

                      readonly property bool isBusy: root.activePluginOpId === row.id
                      readonly property string authorText: String(row.author || "")
                      readonly property string descText: String(row.description || row.desc || "")
                      readonly property string repoText: String(row.repo || "")
                      // Version pill pair: the update-list rows carry both
                      // sides (from/to); an installed row only has its own
                      // version, and latest when the row is updatable.
                      readonly property string fromText: String(
                        row.from || row.installed
                        || row.version || "")
                      readonly property string toText: String(
                        row.to || row.latest || "")
                      readonly property bool isUpdatable: Boolean(row.updateAvailable || row.updatable)

                      Column {
                        id: pluginCardCol
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.margins: Style.space(14)
                        spacing: Style.space(10)

                        // 1. Header Line: Icon, Title, Author, Version, Status Badges
                        Row {
                          width: parent.width
                          spacing: Style.space(10)

                          Rectangle {
                            width: Style.space(34)
                            height: Style.space(34)
                            radius: Style.cornerRadius
                            color: pluginCard.isUpdatable
                              ? Util.alpha(Color.accent, 0.2)
                              : (Boolean(row.installed || row.version) ? Util.alpha(root.foreground, 0.08) : Util.alpha(root.foreground, 0.04))
                            anchors.verticalCenter: parent.verticalCenter

                            Text {
                              anchors.centerIn: parent
                              text: row.name && row.name.length > 0 ? row.name.substring(0, 1).toUpperCase() : "󰏖"
                              textFormat: Text.PlainText
                              color: pluginCard.isUpdatable ? Color.accent : (Boolean(row.installed || row.version) ? root.foreground : root.dim)
                              font.family: root.fontFamily
                              font.pixelSize: Style.font.body
                              font.bold: true
                            }
                          }

                          Column {
                            width: Math.max(0, parent.width - Style.space(34) - Style.space(10) - badgesRow.implicitWidth - Style.space(10))
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 2

                            Row {
                              spacing: Style.space(6)

                              Text {
                                text: String(row.name || row.id || "")
                                textFormat: Text.PlainText
                                color: root.foreground
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.body
                                font.bold: true
                                elide: Text.ElideRight
                              }

                              Text {
                                // A row that carries both versions spells the
                                // pair out ("v{from} -> v{to}") even when the
                                // two strings are equal (an unverified update
                                // can re-offer the same version); a row with
                                // one version stays plain "v{installed}".
                                visible: pluginCard.fromText !== ""
                                  || pluginCard.toText !== ""
                                text: pluginCard.fromText !== ""
                                  && pluginCard.toText !== ""
                                  ? "v" + pluginCard.fromText + "  \u2192  v"
                                    + pluginCard.toText
                                  : "v" + (pluginCard.fromText !== ""
                                    ? pluginCard.fromText : pluginCard.toText)
                                textFormat: Text.PlainText
                                color: Color.accent
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                font.bold: true
                              }

                              Text {
                                visible: Boolean(row.rankLabel)
                                text: String(row.rankLabel || "")
                                textFormat: Text.PlainText
                                color: Color.accent
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                font.bold: true
                              }

                              Text {
                                visible: Boolean(row.stars && row.stars > 0)
                                text: "★ " + row.stars
                                color: root.dim
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                              }

                              Text {
                                visible: Boolean(row.hearts && row.hearts > 0)
                                text: "♥ " + row.hearts
                                color: root.dim
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                              }
                            }

                            Text {
                              text: (pluginCard.authorText !== "" ? ("by " + pluginCard.authorText + " · ") : "") + row.id
                              textFormat: Text.PlainText
                              color: root.dim
                              font.family: root.fontFamily
                              font.pixelSize: Style.font.caption
                              elide: Text.ElideRight
                            }
                          }

                          // Status Badges & Toggle Switch
                          Row {
                            id: badgesRow
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Style.space(6)

                            // T2 Specific Badge
                            Rectangle {
                              visible: Boolean(row.isT2 || row.isExactT2)
                              height: Style.space(22)
                              width: t2BadgeRow.implicitWidth + Style.space(12)
                              radius: Style.cornerRadius
                              color: Util.alpha(Color.accent, 0.14)
                              border.color: Util.alpha(Color.accent, 0.5)
                              border.width: 1

                              Row {
                                id: t2BadgeRow
                                anchors.centerIn: parent
                                spacing: Style.space(4)
                                Text {
                                  text: ""
                                  color: Color.accent
                                  font.family: root.fontFamily
                                  font.pixelSize: Style.font.caption
                                }
                                Text {
                                  text: "T2"
                                  color: Color.accent
                                  font.family: root.fontFamily
                                  font.pixelSize: Style.font.caption
                                  font.bold: true
                                }
                              }
                            }

                            // Update Available Badge
                            Rectangle {
                              visible: pluginCard.isUpdatable
                              height: Style.space(22)
                              width: updateBadgeText.implicitWidth + Style.space(12)
                              radius: Style.cornerRadius
                              color: Util.alpha(Color.accent, 0.2)
                              border.color: Color.accent
                              border.width: 1

                              Text {
                                id: updateBadgeText
                                anchors.centerIn: parent
                                text: "󰚰 Update Available"
                                color: Color.accent
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                font.bold: true
                              }
                            }

                            // Toggle Switch to enable/disable plugin
                            ToggleSwitch {
                              id: cardToggleSwitch
                              visible: true
                              anchors.verticalCenter: parent.verticalCenter
                              checked: Boolean(row && row.enabled !== false)
                              accent: root.accent
                              foreground: checked ? root.accent : root.foreground
                              busy: pluginCard.isBusy
                              enabled: !pluginCard.isBusy && root.activePluginOpId === ""
                              onToggled: root.manageToggle(String(row.id), !checked)

                              PanelToolTip {
                                visible: cardToggleSwitch.containsMouse
                                text: (row && row.enabled !== false) ? "Enabled" : "Disabled"
                              }
                            }
                          }
                        }

                        // 2. Description
                        Text {
                          width: parent.width
                          visible: pluginCard.descText !== ""
                          text: pluginCard.descText
                          textFormat: Text.PlainText
                          color: root.foreground
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                          wrapMode: Text.WordWrap
                          lineHeight: 1.25
                        }

                        // 3. Actions Row: the marketplace and repository
                        // links sit on the left; the actions (Update, then the
                        // one that opens the plugin - Position bar icon for
                        // bar widgets, Open for summonable panel-type ones -
                        // then Remove) are right-aligned, in
                        // that order, so Remove lands directly underneath
                        // the enable/disable toggle in the header row. The
                        // positioner skips invisible children, so hidden
                        // conditional buttons leave no gaps behind.
                        Item {
                          id: pluginActionsRow
                          width: parent.width
                          height: Math.max(linksRow.implicitHeight,
                            actionsRow.implicitHeight)

                          Row {
                            id: linksRow
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Style.space(8)

                            // External link to Omarchy Plugins website page
                            Button {
                              tooltipText: "Plugins page ↗"
                              iconText: "󰖟"
                              bordered: true
                              onClicked: {
                                var pageUrl = row.webUrl || ("https://plugins.omarchy.org/plugin.html?id=" + encodeURIComponent(row.id))
                                root.openPluginPageAndClose(row.id)
                              }
                            }

                            // External link to repository
                            Button {
                              visible: pluginCard.repoText !== ""
                              tooltipText: "GitHub ↗"
                              iconText: "󰌹"
                              bordered: true
                              onClicked: root.manageOpenUrl(pluginCard.repoText)
                            }
                          }

                          Row {
                            id: actionsRow
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Style.space(8)

                            // Update button (if update available): wrapped in
                            // an accent ring + tint so every updatable row's
                            // action pops (the row itself keeps a highlighted
                            // border; the shell Button's own fill/border
                            // bindings are internal and not overridable, so
                            // the highlight paints behind a transparent
                            // Button). An unverified update the verification
                            // opt-in refuses still shows here - the row is
                            // badged - but its tooltip states why the click
                            // only explains (the bar refuses the update).
                            Item {
                              id: updateBtnWrap
                              visible: Boolean(pluginCard.isUpdatable)
                              implicitWidth: btnUpdate.implicitWidth
                              implicitHeight: btnUpdate.implicitHeight

                              Rectangle {
                                anchors.fill: parent
                                radius: Style.cornerRadius
                                color: Util.alpha(root.accent, 0.14)
                                border.color: root.accent
                                border.width: 1
                              }

                              Button {
                                id: btnUpdate
                                anchors.fill: parent
                                background: "transparent"
                                // Icon (and hover/focus tokens) follow
                                // `foreground`; the idle fill and border come
                                // from the accent ring behind this button.
                                foreground: root.accent
                                tooltipText: pluginCard.isBusy
                                  ? "Updating..."
                                  : (row.updatable === false
                                    ? "Unverified update: enable \"Update to unverified versions\" in the Settings tab first"
                                    : ("Update to v" + (row.latest || row.version || row.installed)))
                                iconText: pluginCard.isBusy ? "󰑐" : "󰚰"
                                iconSpinning: pluginCard.isBusy
                                enabled: !pluginCard.isBusy && root.activePluginOpId === ""
                                onClicked: root.beginUpdateConfirm([{
                                  id: String(row.id),
                                  name: String(row.name || row.id),
                                  from: String(row.installed || row.version || ""),
                                  to: String(row.latest || row.version || ""),
                                  verified: row.verified === true
                                }])
                              }
                            }

                            // Bar positioning button (for bar widgets)
                            Button {
                              visible: Boolean(row && (row.isBarWidget || row.section))
                              tooltipText: "Position bar icon"
                              iconText: "\uF037"
                              bordered: true
                              enabled: !pluginCard.isBusy && root.activePluginOpId === ""
                              onClicked: root.openPlacementFromSettings(row)
                            }

                            // Open button (non-bar plugins that the shell
                            // can summon as a window: panel/overlay/menu
                            // kinds, and only while enabled - a disabled
                            // plugin has no panel to open). It sits in the
                            // same slot the position button takes on bar
                            // rows; the two are mutually exclusive. The
                            // circle-play glyph reads as "run this plugin
                            // now"; the open-in-new/window-arrow glyph read
                            // as an external-browser jump, which this is not
                            // (it opens the plugin's own window in the shell).
                            Button {

                              visible: root.rowIsSummonable(row)
                              tooltipText: "Open plugin"
                              iconText: "\uF144"
                              bordered: true
                              enabled: !pluginCard.isBusy && root.activePluginOpId === ""
                              onClicked: root.manageSummonPlugin(row)
                            }

                            // Remove button
                            Button {
                              visible: true
                              tooltipText: pluginCard.isBusy ? "Removing..." : "Remove"
                              iconText: pluginCard.isBusy ? "󰑐" : "󰆴"
                              iconSpinning: pluginCard.isBusy
                              bordered: true
                              enabled: !pluginCard.isBusy && root.activePluginOpId === ""
                              onClicked: root.beginUninstallConfirm({
                                id: String(row.id),
                                name: String(row.name || row.id)
                              })
                            }
                          }
                        }
                      }
                    }

  // One update list: bold title + live count pill, then the same plugin
  // cards the Manage tab list uses. The snapshot's update rows (id, name,
  // from, to, verified) are joined with the installed-plugin list and the
  // catalog detail before reaching the card (root.updatesCardRows), so a
  // row can show the full information and every button; the version pill
  // keeps spelling out the from -> to pair. The tab body already scrolls
  // (settingsFlickable), so the section no longer caps its own height.
  component PiUpdateSection: Column {
    id: piSec
    property string title: ""
    property color tone: Color.accent
    property var items: []
    width: parent ? parent.width : 0
    spacing: Style.space(8)
    visible: items.length > 0

    // Joined card rows (see root.updatesCardRows): a binding, so a fresh
    // snapshot - or an optimistic enable/move echo patching the installed
    // list - re-renders the cards.
    readonly property var cardRows: root.updatesCardRows(piSec.items)

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

    Column {
      width: piSec.width
      spacing: Style.space(10)
      Repeater {
        model: piSec.cardRows
        // Braces matter (see PiUpdateSection's old note): the bare
        // component type is not a delegate definition.
        delegate: PiPluginCard { }
      }
    }
  }

  // Settings-tab toggle row: an OmApple-panel-style bordered surface with
  // a bold label and explanatory caption left, and the shell's own
  // ToggleSwitch (the same control the OmApple panel and bar popups use)
  // right. The caller owns the value; `toggledPi` fires on every click.
  component PiToggleRow: BorderSurface {
    id: piToggleRow
    property string label: ""
    property string desc: ""
    property bool checked: false
    signal toggledPi

    width: parent ? parent.width : 0
    height: Style.space(62)
    color: Util.alpha(Color.foreground, 0.03)
    radius: Style.cornerRadius

    Row {
      anchors.fill: parent
      anchors.leftMargin: Style.space(14)
      anchors.rightMargin: Style.space(14)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(14)

      Column {
        width: parent.width - settingSwitch.width - Style.space(14)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)
        Text {
          width: parent.width
          elide: Text.ElideRight
          text: piToggleRow.label
          color: Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          font.bold: true
        }
        Text {
          width: parent.width
          elide: Text.ElideRight
          text: piToggleRow.desc
          color: Color.muted
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }
      ToggleSwitch {
        id: settingSwitch
        anchors.verticalCenter: parent.verticalCenter
        checked: piToggleRow.checked
        onToggled: piToggleRow.toggledPi()
      }
    }
  }

  // Marketplace preview thumbnail with loading placeholder / shimmer:
  // shown in install review, uninstall confirmation, and update
  // confirmation panels.
  // Proportional height up to 16:5 max proportions. While loading,
  // reserves the 16:5 ratio placeholder box and animates a soft shimmer
  // band until the image lands, so the card height never jumps.
  component PiPreviewImage: Rectangle {
    id: previewBox
    visible: root.catalogLoading || root.catalogThumb !== ""
    width: cardColumn.width
    height: visible
      ? Math.round((width - 2) * Math.min(root.catalogThumbNative, root.catalogThumbRatio)) + 2
      : 0
    implicitHeight: height
    implicitWidth: width
    radius: Style.cornerRadius
    color: Util.alpha(Color.foreground, 0.05)
    border.color: Util.alpha(Color.foreground, 0.15)
    border.width: 1
    clip: true

    Image {
      id: previewImage
      x: 1
      y: 1
      width: parent.width - 2
      height: Math.max(parent.height - 2, Math.round(width * root.catalogThumbNative))
      source: root.catalogThumb !== "" ? root.marketplaceUrl + root.catalogThumb : ""
      sourceSize.width: Math.round(width * 2)
      fillMode: Image.Stretch
      asynchronous: true
      cache: true
      smooth: true
    }

    Rectangle {
      id: previewShimmer
      anchors.fill: parent
      radius: Style.cornerRadius
      color: "transparent"
      clip: true
      visible: previewBox.visible
        && (root.catalogLoading
            || root.catalogThumb === ""
            || previewImage.status !== Image.Ready)

      Rectangle {
        id: shimmerBand
        width: Math.round(previewBox.width * 0.45)
        height: parent.height
        gradient: Gradient {
          orientation: Gradient.Horizontal
          GradientStop { position: 0.0; color: Qt.rgba(1, 1, 1, 0) }
          GradientStop { position: 0.5; color: Util.alpha(Color.foreground, 0.07) }
          GradientStop { position: 1.0; color: Qt.rgba(1, 1, 1, 0) }
        }
        SequentialAnimation on x {
          running: previewShimmer.visible
          loops: Animation.Infinite
          NumberAnimation {
            from: -shimmerBand.width
            to: previewBox.width
            duration: 1100
            easing.type: Easing.InOutQuad
          }
          PauseAnimation { duration: 350 }
        }
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
      onClicked: {
        if (root.stage === "placement" && root.placementFromSettings) {
          root.returnPlacementToSettings()
        } else {
          root.close()
        }
      }
    }

    // Escape closes the panel. The surface grabs exclusive keyboard focus
    // while open, so a focused item inside it receives the key.
    Item {
      anchors.fill: parent
      focus: true
      Keys.onEscapePressed: {
        if (root.stage === "placement" && root.placementFromSettings) {
          root.returnPlacementToSettings()
        } else {
          root.close()
        }
      }
    }

    BorderSurface {
      id: card
      anchors.centerIn: parent
      // The settings stage is a fixed-size card (the OmApple panel's
      // 968x682, dialed back 15% to 823x580 and then grown 10% on both
      // axes to 905x638, shrunk only when the panel is smaller); the
      // wizard stages keep hugging the visible stage content, clamped
      // to the screen (cardColumn.implicitHeight sums visible children only).
      width: root.stage === "settings"
        ? Math.min(Style.space(905), panel.width - Style.space(48))
        : Math.min(Style.space(760), panel.width - Style.space(48))
      height: root.stage === "settings"
        ? root.settingsCardHeight
        : Math.min(cardColumn.anchors.topMargin
                   + cardColumn.implicitHeight
                   + card.footerInset,
                   panel.height - Style.space(48))
      clip: true
      radius: Style.cornerRadius
      color: Color.popups.background
      borderSpec: Border.flat(Color.accent, Style.normalBorderWidth)
      padding: Style.space(24)
      // Header and footer paddings are dialed tighter than the insets they
      // otherwise follow (two 15% steps): the header's margins above/below
      // the header row, and the even inset that frames the footer strip on
      // all four sides. The body keeps the full content insets.
      readonly property real headerInset: Math.round(contentTopInset * 0.8 * 0.85 * 0.85)
      readonly property real footerInset: Math.round(contentBottomInset * 0.85 * 0.85)

      // Swallow clicks over the card so the scrim MouseArea below doesn't close.
      MouseArea { anchors.fill: parent; onClicked: {} }

      Column {
        id: cardColumn
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.topMargin: card.headerInset
        anchors.rightMargin: card.contentRightInset
        anchors.leftMargin: card.contentLeftInset
        spacing: Style.spacing.panelGap

        // Header block: bar icon + plugin name + version pill + action
        // subtitle, with equal margins above and below (the header inset:
        // 20% under the content margin, then 15% tighter twice over) and a
        // full-width divider under the header.
        Item {
          id: headerBlock
          width: cardColumn.width
          implicitHeight: headerRow.implicitHeight + card.headerInset
          height: implicitHeight

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
                text: root.isManagerStage ? root.managerName : root.pluginName
                font.family: Style.font.family
                font.pixelSize: Style.font.title
                font.bold: true
                color: Color.foreground
                anchors.verticalCenter: parent.verticalCenter
              }

              Rectangle {
                visible: root.headerVersion !== ""
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
                  text: "v" + String(root.headerVersion)
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

          // Panel-header actions, right-aligned and shown ONLY while the
          // tabbed settings layout is on screen (root.isManagerStage,
          // stage "settings"): the batch update first, then a manual
          // check. Install review, placement, the running system panel
          // and the settings-confirm gate all reuse this header, and
          // these two actions belong to the settings panel alone. The
          // batch is the accent-primary (ring + tint behind a
          // transparent Button); the check's icon spins 360 while a
          // check runs (the shared Button's iconSpinning, gated on
          // reduce-motion). Both defer to the bar: the batch arms the
          // settings-confirm gate, the check writes the refresh command
          // (the bar's running-check guard makes a redundant click a safe
          // no-op, so it stays clickable during a check and the spin
          // covers the whole check via the published updateChecking flag).
          Row {
            id: headerActionsRow
            // Not root.isManagerStage: that also covers settings-confirm
            // and the browser-prompt stage, which reuse this header
            // for their own cards. Only the tabbed settings stage itself.
            visible: root.stage === "settings"
            anchors.right: parent.right
            anchors.verticalCenter: headerRow.verticalCenter
            spacing: Style.space(10)
            Item {
              visible: root.settingsEligibleRows().length > 0
              implicitWidth: btnHeaderUpdate.implicitWidth
              implicitHeight: btnHeaderUpdate.implicitHeight

              Rectangle {
                anchors.fill: parent
                radius: Style.cornerRadius
                color: Util.alpha(root.accent, 0.14)
                border.color: root.accent
                border.width: 1
              }

              Button {
                id: btnHeaderUpdate
                anchors.fill: parent
                background: "transparent"
                foreground: root.accent
                text: "Update " + root.settingsEligibleRows().length
                  + (root.settingsEligibleRows().length === 1
                    ? " plugin now" : " plugins now")
                iconText: "󰚰"
                onClicked: root.beginUpdateConfirm(root.settingsEligibleRows())
              }
            }
            Button {
              id: btnHeaderCheck
              text: root.snapBool("updateChecking")
                ? "Checking for updates" : "Check for updates"
              iconText: "\uF021"
              bordered: true
              // Disabled while a check runs (the label and spinning icon
              // carry that state); the bar's running-check guard made a
              // redundant click a no-op anyway, but a dimmed, inert button
              // is the honest affordance.
              enabled: !root.snapBool("updateChecking")
              // The kit has no disabled tint: dim the button itself so the
              // inert state is visible (the spinning icon carries the
              // "checking" half of the state).
              opacity: enabled ? 1.0 : 0.55
              iconSpinning: root.snapBool("updateChecking")
                && !Style.reduceMotion
              // The check's results (globe, empty state, update rows) all
              // live in the Updates tab: show it while the check runs.
              onClicked: {
                root.settingsTab = "updates"
                root.refreshUpdates()
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
          visible: root.stage !== "browser-prompt"
            && root.stage !== "running"
            // Stage-gated as well as mode-gated: the settings panel's card
            // is fixed-height, so a stray visible row here (e.g. mode left
            // on "move" after the placement detour) clips the footer off
            // the card. The stage check makes that class of leak impossible.
            && root.stage !== "settings" && root.stage !== "settings-confirm"
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

          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.space(2)

            Text {
              id: runningActionLabel
              width: Math.min(implicitWidth, cardColumn.width - Style.space(40))
              elide: Text.ElideRight
              maximumLineCount: 1
              textFormat: Text.PlainText
              text: (root.runningAction === "uninstall" ? "Uninstalling "
                  : root.runningAction === "update" ? "Updating " : "Installing ")
                + root.runningName
              font.family: Style.font.family
              font.pixelSize: Style.font.title
              font.bold: true
              color: Util.alpha(Color.foreground, 0.75)

              SequentialAnimation on color {
                running: root.opened && root.stage === "running" && !Style.reduceMotion
                loops: Animation.Infinite
                ColorAnimation {
                  from: Util.alpha(Color.foreground, 0.75)
                  to: Color.accent
                  duration: 900
                  easing.type: Easing.InOutSine
                }
                ColorAnimation {
                  from: Color.accent
                  to: Util.alpha(Color.foreground, 0.75)
                  duration: 900
                  easing.type: Easing.InOutSine
                }
              }
            }

            Repeater {
              model: 3
              delegate: Text {
                text: "."
                font.family: Style.font.family
                font.pixelSize: Style.font.title
                font.bold: true
                color: Color.accent
                property real lift: 0
                y: lift
                SequentialAnimation on lift {
                  running: root.opened && root.stage === "running" && !Style.reduceMotion
                  loops: Animation.Infinite
                  PauseAnimation { duration: index * 160 }
                  NumberAnimation { from: 0; to: -4; duration: 220; easing.type: Easing.OutQuad }
                  NumberAnimation { from: -4; to: 0; duration: 220; easing.type: Easing.InQuad }
                  PauseAnimation { duration: 600 - (index * 160) }
                }
                SequentialAnimation on opacity {
                  running: root.opened && root.stage === "running" && !Style.reduceMotion
                  loops: Animation.Infinite
                  PauseAnimation { duration: index * 160 }
                  NumberAnimation { from: 0.35; to: 1.0; duration: 220; easing.type: Easing.OutQuad }
                  NumberAnimation { from: 1.0; to: 0.35; duration: 220; easing.type: Easing.InQuad }
                  PauseAnimation { duration: 600 - (index * 160) }
                }
              }
            }
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
            implicitHeight: (root.opened && root.stage === "running") ? (globe.height + 20) : 0
            height: implicitHeight
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
            width: root.opened && root.stage === "running" ? Style.space(540) : 0
            height: root.opened && root.stage === "running" ? Style.space(270) : 0
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
        // centered system overlay, organized as four vertical tabs:
        // Updates, Manage, Settings and About. The tab bar sits at the
        // left; the tab body scrolls between the fixed header and footer.
        // Every control writes a command the widget dispatches, and the
        // panel repaints from the republished snapshot within 400ms. ----
        Row {
          visible: root.stage === "settings"
          width: cardColumn.width
          spacing: Style.space(16)

          // Vertical tab rail: OmApple-panel-style buttons (icon + title +
          // one-line description, accent strip and tinted fill on the
          // active one). The Updates button carries a counter pill after
          // its title: the total available updates spelled out by kind
          // ("verified + unverified"), urgent-toned whenever unverified
          // ones are part of the total; the tooltip spells both counts out.
          id: settingsStageRow
          // Exact vertical budget for the tab body: the fixed settings card
          // minus every fixed element stacked above and below it (top margin,
          // the PlugBrug header, the footer divider and buttons, the bottom
          // inset, and the column gaps). The
          // settings row then fills the card to the pixel, so the footer is
          // never clipped and the body is always exactly the space between
          // header and footer.
          readonly property real settingsBodyMax: Math.max(Style.space(160),
            root.settingsCardHeight - card.headerInset
            - card.footerInset - headerBlock.height
            - footerDivider.implicitHeight - footerArea.height
            - 3 * cardColumn.spacing)
          Column {
            id: settingsTabBar
            width: Style.space(242)
            spacing: Style.space(8)
            Repeater {
              model: root.settingsTabModel
              delegate: BorderSurface {
                id: tabBtn
                width: settingsTabBar.width
                height: Style.space(54)
                padding: 0
                radius: Style.cornerRadius
                color: root.settingsTab === modelData.key
                  ? Style.selectedFillFor(Color.foreground, Color.accent)
                  : tabBtnMouse.containsMouse
                    ? Style.hoverFillFor(Color.foreground, Color.accent)
                    : "transparent"
                borderSpec: root.settingsTab === modelData.key
                  ? Border.flat(Color.accent, 1)
                  : Border.controlSpec(tabBtnMouse.containsMouse
                      ? "hover-cursor" : "normal", Color.foreground, Color.accent)
                // Left active accent strip (the OmApple rail marker).
                Rectangle {
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(3)
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(4)
                  height: Style.space(34)
                  radius: Style.space(2)
                  color: Color.accent
                  visible: root.settingsTab === modelData.key
                }
                MouseArea {
                  id: tabBtnMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    root.settingsTab = String(modelData.key)
                    root.manageMoveForId = ""
                  }
                }
                Row {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(14)
                  anchors.rightMargin: Style.space(12)
                  spacing: Style.space(12)
                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: String(modelData.iconText)
                    color: root.settingsTab === modelData.key
                      ? Color.accent : Color.foreground
                    font.family: Style.font.family
                    font.pixelSize: Style.font.title
                  }
                  Column {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - Style.space(42)
                    spacing: Style.space(2)
                    Row {
                      spacing: Style.space(6)
                      Text {
                        text: String(modelData.title)
                        font.family: Style.font.family
                        font.pixelSize: Style.font.body
                        font.bold: root.settingsTab === modelData.key
                        color: Color.foreground
                        anchors.verticalCenter: parent.verticalCenter
                      }
                      // Updates-tab counter pill: total available updates
                      // spelled out by kind, urgent-toned when unverified
                      // ones are part of the total.
                      Rectangle {
                        id: updTabPill
                        visible: modelData.key === "updates"
                          && root.settingsAllRows().length > 0
                        anchors.verticalCenter: parent.verticalCenter
                        width: updTabPillText.implicitWidth + Style.space(10)
                        height: updTabPillText.implicitHeight + Style.space(4)
                        radius: height / 2
                        color: Util.alpha(root.snapList("unverified").length > 0
                          ? Color.urgent : Color.accent, 0.16)
                        Text {
                          id: updTabPillText
                          anchors.centerIn: parent
                          text: root.settingsUpdateBadgeText()
                          color: root.snapList("unverified").length > 0
                            ? Color.urgent : Color.accent
                          font.family: Style.font.family
                          font.pixelSize: Style.font.caption
                          font.bold: true
                        }
                      }
                    }
                    Text {
                      width: parent.width
                      elide: Text.ElideRight
                      text: String(modelData.desc)
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      color: Qt.darker(Color.foreground, 1.55)
                    }
                  }
                }
                PanelToolTip {
                  visible: tabBtnMouse.containsMouse && modelData.key === "updates"
                  text: root.settingsUpdateCountsText()
                }
              }
            }
          }

          // Hairline between rail and content, the OmApple separator.
          Rectangle {
            id: tabSeparator
            width: 1
            height: settingsContentCol.height
            color: Util.alpha(Color.foreground, 0.08)
          }

          // Scrollable tab body column: no category header - the vertical
          // tab rail already names each tab, and only the about tab carries
          // a title of its own (the accent-toned plugin identity block).
          Column {
            id: settingsContentCol
            width: cardColumn.width - settingsTabBar.width - tabSeparator.width
              - 2 * settingsStageRow.spacing
            spacing: 0

            // Scrollable tab body: a fixed viewport that is always exactly
            // the leftover space on the fixed settings card between the
            // PlugBrug header and the footer (settingsBodyMax, derived from
            // the fixed settings card). Only scrolls when the content is
            // taller than that; never stretches the card and never reaches
            // past the footer. clip keeps the sliding rows inside the
            // viewport instead of painting over the header and footer. Must
            // not bind to cardColumn.height: the wizard-stage card height is
            // derived from that column, so that would loop.
            Flickable {
              id: settingsFlickable
              visible: root.settingsTab !== "manage"
              width: parent.width
              height: settingsStageRow.settingsBodyMax
              implicitHeight: visible ? height : 0
              // Bound to the active tab column's own implicit height, not
              // to settingsBody.childrenRect: childrenRect also counts the
              // hidden tab columns, and the updates column's stage items
              // bind implicitHeight: visible ? settingsFlickable.height : 0
              // - their own visible flag stays true while the column hides
              // them, so the hidden column injects a phantom contentHeight
              // equal to the viewport itself, which made even the static
              // Settings tab (and any other tab) flicker into scrollable.
              contentHeight: Math.max(Style.space(1),
                root.settingsTab === "updates" ? updatesTabCol.implicitHeight
                  : root.settingsTab === "about" ? aboutTabCol.implicitHeight
                    : settingsCol.implicitHeight)
              clip: true
              boundsBehavior: Flickable.StopAtBounds
              ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
              Column {
                id: settingsBody
                width: parent.width
                // Same group spacing as the bar popup's settings column.
                spacing: Style.space(20)

              // ---- tab: updates: the check state, the batch action, and
              // the two per-plugin lists (verified first, unverified below,
              // exactly as the widget gates them) ----
              Column {
                id: updatesTabCol
                visible: root.settingsTab === "updates"
                width: parent.width
                spacing: Style.space(20)

                // Checking indicator: the wireframe globe with orbiting
                // satellites from the running stage, painted while the
                // update check runs. Same zero-size/visibility guards as
                // there: a hidden Canvas with a repaint animation keeps
                // compositing frames and can leave stray globe fragments
                // on this full-screen window. While a check runs the list
                // area is empty, so the indicator claims the whole
                // viewport (settingsFlickable has a fixed height derived
                // from the card, never from content, so this cannot loop)
                // and the globe scales to the largest square that fits,
                // caption included.
                // Shared slot for the globe and the empty-state box: only
                // one is ever shown, and both claim the same full-flickable
                // height, so a cross-fade between them never shifts the
                // rows below. The slot's own height follows the *show*
                // state, not the fade-out linger: when a check finishes
                // with update rows appearing, the slot collapses at once
                // and the fading globe just dissolves over the new list
                // instead of shoving it down for the fade duration.
                Item {
                  id: settingsStageSlot
                  width: parent.width
                  implicitHeight: Math.max(
                    checkingGlobe.show ? settingsFlickable.height : 0,
                    emptyBoxStage.show ? settingsFlickable.height : 0)
                  height: implicitHeight

                  Item {
                    id: checkingGlobe
                    // Show state and visibility are kept apart so the item
                    // can linger (visible) while it fades out to opacity 0;
                    // the same Behaviour animates the 0 -> 1 fade-in. The
                    // opacity binding depends only on `show` and visible
                    // only on show+opacity, so nothing is circular.
                    readonly property bool show: root.stage === "settings"
                      && root.snapBool("updateChecking")
                    visible: show || opacity > 0.01
                    opacity: show ? 1 : 0
                    Behavior on opacity {
                      enabled: !Style.reduceMotion
                      NumberAnimation { duration: 220 }
                    }
                    width: parent.width
                    implicitHeight: visible ? settingsFlickable.height : 0
                    height: implicitHeight
                    // Largest square the globe can take (the panel width, or
                    // the leftover height under the caption), then dialed
                    // back 15%: the full-fit square reads too dominant.
                    readonly property real side: Math.max(0, Math.min(
                      width,
                      height - checkingCaption.implicitHeight - Style.space(12))) * 0.85
  
                    Item {
                      anchors.centerIn: parent
                      width: checkingGlobe.side
                      height: checkingGlobe.side + Style.space(8)
                        + checkingCaption.implicitHeight
  
                      Canvas {
                        id: checkingGlobeCanvas
                        anchors.top: parent.top
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: checkingGlobe.visible ? checkingGlobe.side : 0
                        height: checkingGlobe.visible ? checkingGlobe.side : 0
                        visible: checkingGlobe.visible
                        renderStrategy: Canvas.Image
                        antialiasing: true
                        property real phase: 0
                        onPhaseChanged: requestPaint()
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
                          root.paintGlobe(ctx, width, height, Date.now() / 1000,
                            false,
                            root.globeRgb(Color.foreground), root.globeRgb(Color.accent),
                            root.globeRgb(Color.foreground))
                        }
                        NumberAnimation on phase {
                          from: 0
                          to: 3600
                          duration: 360000
                          loops: Animation.Infinite
                          running: checkingGlobe.visible && !Style.reduceMotion
                        }
                      }
  
                      // Animated caption, same language as the running-stage
                      // label: the words pulse between muted and accent, and
                      // three dots bounce and fade in on a stagger (index *
                      // 160) instead of a static ellipsis. Same running
                      // guard as the globe itself; with reduce-motion the
                      // animations stop and the line settles to its resting
                      // state (plain caption + three steady dots).
                      Row {
                        id: checkingCaption
                        anchors.top: checkingGlobeCanvas.bottom
                        anchors.topMargin: Style.space(8)
                        anchors.horizontalCenter: parent.horizontalCenter
                        spacing: Style.space(2)
  
                        Text {
                          id: checkingCaptionText
                          textFormat: Text.PlainText
                          text: "Checking for plugin updates"
                          font.family: Style.font.family
                          font.pixelSize: Style.font.caption
                          font.italic: true
                          color: Color.muted
  
                          SequentialAnimation on color {
                            running: checkingGlobe.visible && !Style.reduceMotion
                            loops: Animation.Infinite
                            ColorAnimation {
                              from: Color.muted
                              to: Color.accent
                              duration: 900
                              easing.type: Easing.InOutSine
                            }
                            ColorAnimation {
                              from: Color.accent
                              to: Color.muted
                              duration: 900
                              easing.type: Easing.InOutSine
                            }
                          }
                        }
  
                        Repeater {
                          model: 3
                          delegate: Text {
                            text: "."
                            font.family: Style.font.family
                            font.pixelSize: Style.font.caption
                            font.italic: true
                            font.bold: true
                            color: Color.accent
                            property real lift: 0
                            y: lift
                            SequentialAnimation on lift {
                              running: checkingGlobe.visible && !Style.reduceMotion
                              loops: Animation.Infinite
                              PauseAnimation { duration: index * 160 }
                              NumberAnimation { from: 0; to: -4; duration: 220; easing.type: Easing.OutQuad }
                              NumberAnimation { from: -4; to: 0; duration: 220; easing.type: Easing.InQuad }
                              PauseAnimation { duration: 600 - (index * 160) }
                            }
                            SequentialAnimation on opacity {
                              running: checkingGlobe.visible && !Style.reduceMotion
                              loops: Animation.Infinite
                              PauseAnimation { duration: index * 160 }
                              NumberAnimation { from: 0.35; to: 1.0; duration: 220; easing.type: Easing.OutQuad }
                              NumberAnimation { from: 1.0; to: 0.35; duration: 220; easing.type: Easing.InQuad }
                              PauseAnimation { duration: 600 - (index * 160) }
                            }
                          }
                        }
                      }
                    }
                  }
  
                  // Empty state: nothing to update and no check running (so
                  // no globe), the open cardboard box from paintEmptyBox
                  // floats in the globe's slot - same viewport-filling and
                  // scale guards as the checking globe above, and the
                  // "up to date" message rides its caption instead of a
                  // separate text line.
                  Item {
                    id: emptyBoxStage
                    // Same linger-while-fading-out pattern as the globe.
                    readonly property bool show: root.stage === "settings"
                      && !root.snapBool("updateChecking")
                      && !root.snapBool("updateCheckFailed")
                      && root.settingsAllRows().length === 0
                    visible: show || opacity > 0.01
                    opacity: show ? 1 : 0
                    Behavior on opacity {
                      enabled: !Style.reduceMotion
                      NumberAnimation { duration: 220 }
                    }
                    width: parent.width
                    implicitHeight: visible ? settingsFlickable.height : 0
                    height: implicitHeight
                    readonly property real side: Math.max(0, Math.min(
                      width,
                      height - emptyBoxCaption.implicitHeight
                        - Style.space(12))) * 0.85
  
                    Item {
                      anchors.centerIn: parent
                      width: emptyBoxStage.side
                      height: emptyBoxStage.side + Style.space(8)
                        + emptyBoxCaption.implicitHeight
  
                      Canvas {
                        id: emptyBoxCanvas
                        anchors.top: parent.top
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: emptyBoxStage.visible ? emptyBoxStage.side : 0
                        height: emptyBoxStage.visible ? emptyBoxStage.side : 0
                        visible: emptyBoxStage.visible
                        renderStrategy: Canvas.Image
                        antialiasing: true
                        property real phase: 0
                        onPhaseChanged: requestPaint()
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
                          root.paintEmptyBox(ctx, width, height,
                            Date.now() / 1000,
                            root.globeRgb(Color.foreground), root.globeRgb(Color.accent),
                            root.globeRgb(Color.foreground))
                        }
                        NumberAnimation on phase {
                          from: 0
                          to: 3600
                          duration: 360000
                          loops: Animation.Infinite
                          running: emptyBoxStage.visible && !Style.reduceMotion
                        }
                      }
  
                      Text {
                        id: emptyBoxCaption
                        anchors.top: emptyBoxCanvas.bottom
                        anchors.topMargin: Style.space(8)
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: root.snapStr("lastCheckText") === "never"
                          || root.snapStr("lastCheckText") === ""
                          ? "No update check has run yet"
                          : "All installed plugins are up to date"
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                        font.italic: true
                        font.bold: root.snapStr("lastCheckText") !== "never"
                          && root.snapStr("lastCheckText") !== ""
                        // The good-news state ("up to date") is highlighted
                        // in accent; the neutral "no check yet" stays muted.
                        color: root.snapStr("lastCheckText") !== "never"
                          && root.snapStr("lastCheckText") !== ""
                          ? Color.accent : Color.muted
                      }
                    }
                  }
                }
                PiLine {
                  visible: root.snapBool("updateCheckFailed")
                  color: Color.urgent
                  text: "Catalog unreachable: showing the last known update list."
                }

                // (The batch "Update N plugin(s) now" action moved to the
                // settings panel header - see headerActionsRow.)

                // Per-plugin update lists: verified first, unverified below.
                // The unverified list shows its rows under the opt-in toggle
                // only: with the toggle off the widget never acts on them,
                // and offering rows the batch refuses to update confuses the
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
              }

              // ---- tab: settings: the update-gating toggles and the
              // check-for-updates schedule (the toggles gate which versions
              // the Updates tab can act on, so they read as the settings
              // that shape the panel) ----
              // ---- tab: settings: the two behaviour toggles, and the
              // update-check schedule row ----
              Column {
                id: settingsCol
                visible: root.settingsTab === "settings"
                width: parent.width
                // Tighter than the generic 20: this tab's content is fixed
                // and must stay inside the derived viewport (settingsBodyMax)
                // with real slack, so the flickable never becomes scrollable.
                spacing: Style.space(14)

                // Toggles first, directly under the tab header: OmApple
                // panel-style rows (label + explanatory caption left, the
                // shell ToggleSwitch right).
                PiToggleRow {
                  label: "Update to unverified versions"
                  desc: "Off: plugins only update to catalog-verified versions."
                  checked: root.snapBool("allowUnverified")
                  onToggledPi: root.toggleAllowUnverified()
                }
                PiToggleRow {
                  label: "Notify about plugin updates"
                  desc: "Off: the badge and panel lists stay live, but no desktop notifications."
                  checked: root.snapBool("notifyUpdates")
                  onToggledPi: root.toggleNotifyUpdates()
                }
                PiLine {
                  visible: root.snapBool("settingsSaveFailed")
                  color: Color.urgent
                  text: "Settings file could not be written: changes apply this session only."
                }

                PiRule {}

                // Poll interval: five equal segments (selected one
                // primary-marked) and the refresh button: the schedule and
                // the manual check are settings, not a primary action.
                PiLine {
                  text: "Check for plugin updates:"
                }
                Row {
                  anchors.horizontalCenter: parent.horizontalCenter
                  spacing: Style.spacing.controlGap
                  Repeater {
                    model: root.snapList("pollValues")
                    delegate: PiButton {
                      width: Style.space(84)
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
                    onClickedPi: root.refreshUpdates()
                  }
                }
              }

              // ---- tab: about: the browser stores, and this plugin's
              // project links ----
              Column {
                id: aboutTabCol
                visible: root.settingsTab === "about"
                width: parent.width
                spacing: Style.space(12)

                // This plugin's own identity, rendered in the exact same
                // format as the install-confirmation review's plugin block
                // (bold accent-highlighted name, muted id line, description,
                // the "by author · version · license · kinds" meta line and
                // the "Source:" link): the data is this plugin's own
                // manifest.json - the same file that backs the header's
                // version badge - so it always describes the installed
                // version. (The review's preview image and marketplace
                // status lines are left out: this plugin has no own
                // catalog entry in its own panel, and no self-verdict.)
                PiLine {
                  color: Color.accent
                  font.bold: true
                  text: root.managerName
                }
                PiLine {
                  visible: root.managerId.length > 0
                    && root.managerId !== root.managerName
                  color: Color.muted
                  font.pixelSize: Style.font.caption
                  text: root.managerId
                }
                PiLine {
                  visible: root.ownManifest !== null
                    && String((root.ownManifest || {}).description || "").length > 0
                  text: String((root.ownManifest || {}).description || "")
                }
                PiLine {
                  text: {
                    var e = root.ownManifest || {}
                    var bits = []
                    if (e.author) bits.push("by " + e.author)
                    if (root.managerVersion) bits.push("v" + root.managerVersion)
                    if (e.license) bits.push(String(e.license))
                    var kinds = Array.isArray(e.kinds) ? e.kinds : []
                    if (kinds.length) bits.push(kinds.join(", "))
                    return bits.join("  \u00b7  ")
                  }
                }
                PiTextLink {
                  visible: root.githubRepoUrl.length > 0
                  closeOnActivate: true
                  text: "Source: " + root.linkTag(root.githubRepoUrl,
                    root.githubRepoUrl)
                }

                PiRule {}

                // Browser stores: the supported-browser lists (installed
                // browsers accent-highlighted by the widget) above
                // half-width buttons that open the store page in the first
                // installed browser of that family (the labels carry the
                // launch target) and dismiss the panel: the store page is
                // the point of the click, the panel has nothing left to do
                // once the launch command is queued. The open_store line is
                // written before close() appends its "closed" line, so the
                // widget's in-order dispatch launches the browser before the
                // session closes (same command-plus-close pattern as a
                // settings-confirm action).
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
                    onClickedPi: root.openStoreAndClose("chromeUrl", "chromeBin")
                  }
                  PiButton {
                    width: (parent.width - Style.spacing.controlGap) / 2
                    label: root.snapStr("firefoxLabel")
                    onClickedPi: root.openStoreAndClose("firefoxUrl", "firefoxBin")
                  }
                }

                PiRule {}

                PiTextLink {
                  text: "Project: " + root.linkTag(root.githubRepoUrl,
                    "GitHub repository") + "  \u00b7  "
                    + root.linkTag(root.githubIssuesUrl, "Report an issue")
                }
                PiTextLink {
                  text: "Marketplace: " + root.linkTag(root.marketplaceListingUrl,
                    "PlugBrug on the Omarchy plugin marketplace")
                }
                PiTextLink {
                  text: "Docs: " + root.linkTag(root.licenseUrl, "License")
                    + "  \u00b7  " + root.linkTag(root.privacyUrl, "Privacy policy")
                }
              }
            }
          }

            // Manage Tab: Pinned search toolbar and count at top,
            // scrollable list of plugin cards below!
            Item {
              id: pluginsTabContainer
              visible: root.settingsTab === "manage"
              width: parent.width
              height: settingsStageRow.settingsBodyMax

              // Pinned Top Area: Search toolbar & active operation status banner
              Column {
                id: pluginsPinnedTop
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                spacing: Style.space(10)

                // Toolbar: Search box and plugin count
                Item {
                  width: parent.width
                  height: Style.space(32)

                  Row {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(8)

                    Loader {
                      id: pluginSearchLoader
                      width: Style.space(240)
                      height: Style.space(32)
                      active: root.opened && root.settingsTab === "manage"
                      sourceComponent: FocusScope {
                        id: pluginSearchScope
                        width: Style.space(240)
                        height: Style.space(32)

                        readonly property bool _focused: searchInput.activeFocus
                        readonly property bool _hot: searchMouseArea.containsMouse || _focused
                        readonly property var _borderSpec: Border.controlSpec(_focused ? "focus" : (_hot ? "hover-cursor" : "normal"), root.foreground, root.accent)

                        BorderSurface {
                          anchors.fill: parent
                          radius: Style.cornerRadius
                          color: Style.controlFill(pluginSearchScope._focused, pluginSearchScope._hot, root.foreground, root.accent)
                          borderSpec: pluginSearchScope._borderSpec
                        }

                        MouseArea {
                          id: searchMouseArea
                          anchors.fill: parent
                          hoverEnabled: true
                          cursorShape: Qt.IBeamCursor
                          onClicked: searchInput.forceActiveFocus()
                        }

                        Text {
                          anchors.left: parent.left
                          anchors.right: parent.right
                          anchors.leftMargin: Style.space(10)
                          anchors.rightMargin: Style.space(10)
                          anchors.verticalCenter: parent.verticalCenter
                          visible: searchInput.text.length === 0
                          text: "Search plugins..."
                          font.pixelSize: Style.font.caption
                          font.family: root.fontFamily
                          color: Qt.darker(root.foreground, 1.6)
                          elide: Text.ElideRight
                        }

                        TextInput {
                          id: searchInput
                          anchors.left: parent.left
                          anchors.right: clearBtn.visible ? clearBtn.left : parent.right
                          anchors.leftMargin: Style.space(10)
                          anchors.rightMargin: Style.space(6)
                          anchors.verticalCenter: parent.verticalCenter
                          font.pixelSize: Style.font.caption
                          font.family: root.fontFamily
                          color: root.foreground
                          clip: true
                          readOnly: false
                          text: root.pluginFilterQuery
                          onTextChanged: root.pluginFilterQuery = text
                        }

                        MouseArea {
                          id: clearBtn
                          visible: searchInput.text.length > 0
                          width: Style.space(20)
                          height: Style.space(20)
                          anchors.right: parent.right
                          anchors.rightMargin: Style.space(6)
                          anchors.verticalCenter: parent.verticalCenter
                          cursorShape: Qt.PointingHandCursor
                          onClicked: {
                            searchInput.text = ""
                            root.pluginFilterQuery = ""
                          }

                          Text {
                            anchors.centerIn: parent
                            text: "󰅖"
                            color: root.dim
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                          }
                        }
                      }
                    }

                    // State filter toggles: each narrows the list to the
                    // enabled or disabled plugins, and clicking the active
                    // one clears the filter (both states shown again). They
                    // compose with the search text; the count on the right
                    // reflects the filtered rows.
                    Button {
                      text: "Enabled"
                      fontSize: Style.font.caption
                      bordered: true
                      selected: root.manageStateFilter === "enabled"
                      tooltipText: "Show only enabled plugins"
                        + " \u2014 click again to show all"
                      onClicked: root.manageStateFilter
                        = root.manageStateFilter === "enabled" ? "" : "enabled"
                    }
                    Button {
                      text: "Disabled"
                      fontSize: Style.font.caption
                      bordered: true
                      selected: root.manageStateFilter === "disabled"
                      tooltipText: "Show only disabled plugins"
                        + " \u2014 click again to show all"
                      onClicked: root.manageStateFilter
                        = root.manageStateFilter === "disabled" ? "" : "disabled"
                    }
                  }

                  Row {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(10)

                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      text: root.filteredPlugins.length + " plugins"
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }
                }

                // Operation in progress / feedback banner
                BorderSurface {
                  visible: root.pluginActionStatus !== ""
                  width: parent.width
                  height: Style.space(40)
                  radius: Style.cornerRadius
                  color: Util.alpha(Color.accent, 0.12)
                  borderSpec: Border.flat(Color.accent, 1)

                  Row {
                    anchors.fill: parent
                    anchors.leftMargin: Style.space(12)
                    anchors.rightMargin: Style.space(12)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(8)

                    Text {
                      text: root.activePluginOpId !== "" ? "󰑐" : "󰄲"
                      color: Color.accent
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                    }

                    Text {
                      width: parent.width - Style.space(60)
                      text: root.pluginActionStatus
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                      elide: Text.ElideRight
                    }

                    MouseArea {
                      width: Style.space(20)
                      height: Style.space(20)
                      anchors.verticalCenter: parent.verticalCenter
                      visible: root.activePluginOpId === ""
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.pluginActionStatus = ""

                      Text {
                        anchors.centerIn: parent
                        text: "󰅖"
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                      }
                    }
                  }
                }
              }

              // Scrollable Plugin Cards List
              Flickable {
                id: pluginCardsFlickable
                anchors.top: pluginsPinnedTop.bottom
                anchors.topMargin: Style.space(10)
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                contentHeight: pluginCardsColumn.childrenRect.height

                Column {
                  id: pluginCardsColumn
                  width: parent.width
                  spacing: Style.space(10)

                  // Empty State
                  BorderSurface {
                    visible: root.filteredPlugins.length === 0
                    width: parent.width
                    height: Style.space(100)
                    radius: Style.cornerRadius
                    color: Util.alpha(root.foreground, 0.03)

                    Column {
                      anchors.centerIn: parent
                      spacing: Style.space(8)

                      Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: "󰏖"
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.title
                      }

                      Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: "No plugins found"
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                      }
                    }
                  }

                  // Plugin Cards Repeater
                  Repeater {
                    // Stable render identity: the model only swaps when the
                    // row ids/order change (manageRenderSig), so enable/
                    // disable patches and snapshot echoes repaint cards in
                    // place instead of destroying and re-creating the whole
                    // list (which collapses contentHeight and jumps the
                    // scroll position mid-frame).
                    model: root.manageRenderRows
                    // Id-set changes (filter edits, installs, removals) do
                    // rebuild; filter/search edits reset to the top.
                    onModelChanged: root.manageScrollModelSwapped()

                    delegate: PiPluginCard {
                      // Live row: paint the current filtered row at this
                      // index, re-read on every filteredPlugins change.
                      row: root.filteredPlugins[index]
                    }
                  }
                }
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

          // Preview image: 100% width, proportional up to 16:5 max proportions,
          // with loading placeholder shimmer while catalog or image is loading.
          PiPreviewImage {}

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
          PiTextLink {
            visible: root.pluginRepo.length > 0
            closeOnActivate: true
            text: "Source: " + root.linkTag(root.pluginRepo, root.pluginRepo)
          }
          PiLine {
            visible: root.catalogEntry !== null
            textFormat: Text.RichText
            text: {
              var e = root.catalogEntry
              if (!e) return ""
              var isVer = e.verificationStatus === "verified"
              var verification = isVer
                ? "<span style='color: " + root.themeSuccessColor + ";'>verified</span>"
                : "<span style='color: " + root.themeWarningColor + ";'>unverified</span>"
              var isSnapVer = e.verificationSnapshotStatus === "verified"
              var snapshot = isSnapVer
                ? "snapshot <span style='color: " + root.themeSuccessColor + ";'>verified</span>"
                : "snapshot <span style='color: " + root.themeWarningColor + ";'>unverified</span>"
              return "Marketplace status: " + verification + " \u00b7 " + snapshot
                + " at " + root.shortSha(e.listingValidatedCommit)
            }
          }
          PiLine {
            visible: root.catalogEntry !== null
            textFormat: Text.RichText
            color: Color.accent
            text: "Installs the repository's current HEAD, which may differ from the "
              + "<span style='color: " + root.themeSuccessColor + ";'>verified</span> snapshot."
          }
        }

        // ---- stages: mode confirmations ----
        Column {
          visible: root.stage === "uninstall-confirm" && root.mode === "uninstall"
          width: cardColumn.width
          spacing: Style.spacing.lg

          // Preview image: 100% width, proportional up to 16:5 max proportions,
          // with loading placeholder shimmer while catalog or image is loading.
          PiPreviewImage {}

          PiLine {
            text: "Installed as a user plugin. Uninstalling removes the plugin files, "
              + "disables it, and removes its bar layout entry."
          }
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
        // ---- stage: update-confirm (single-plugin update confirmation) ----
        // Same plugin identity block as the install review: preview image
        // with loading placeholder, name, id, meta line, source link, and
        // marketplace status — plus the "from -> to" version line and the
        // commit-pinning explainer.
        Column {
          visible: root.stage === "update-confirm" && root.mode === "update"
          width: cardColumn.width
          spacing: Style.spacing.lg

          // Preview image: 100% width, proportional up to 16:5 max proportions,
          // with loading placeholder shimmer while catalog or image is loading.
          PiPreviewImage {}

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
          // Installed -> available versions (both version-shaped; when the
          // manifest or catalog carries no version the commit explainer below
          // is the only, still exact, description of the change).
          PiLine {
            visible: root.updateVersionLine.length > 0
            color: Color.foreground
            text: root.updateVersionLine
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
          PiTextLink {
            visible: root.pluginRepo.length > 0
            closeOnActivate: true
            text: "Source: " + root.linkTag(root.pluginRepo, root.pluginRepo)
          }
          PiLine {
            visible: root.catalogEntry !== null
            textFormat: Text.RichText
            text: {
              var e = root.catalogEntry
              if (!e) return ""
              var isVer = e.verificationStatus === "verified"
              var verification = isVer
                ? "<span style='color: " + root.themeSuccessColor + ";'>verified</span>"
                : "<span style='color: " + root.themeWarningColor + ";'>unverified</span>"
              var isSnapVer = e.verificationSnapshotStatus === "verified"
              var snapshot = isSnapVer
                ? "snapshot <span style='color: " + root.themeSuccessColor + ";'>verified</span>"
                : "snapshot <span style='color: " + root.themeWarningColor + ";'>unverified</span>"
              return "Marketplace status: " + verification + " \u00b7 " + snapshot
                + " at " + root.shortSha(e.listingValidatedCommit)
            }
          }
          PiLine {
            visible: root.updateVerifiedSha.length > 0
            text: "Installed. Updating fast-forwards the plugin to the verified "
              + "commit " + root.shortSha(root.updateVerifiedSha) + ". If upstream "
              + "advanced past it, the update is refused and the plugin stays untouched."
          }
          PiLine {
            visible: root.updateVerifiedSha.length === 0
            color: Color.accent
            text: "Installed. No marketplace-verified commit matches upstream, and "
              + "you allowed unverified updates: this update pulls commits no "
              + "maintainer reviewed. The shell reloads the plugin afterwards."
          }
        }

        // ---- stage: browser-prompt (browser extension setup) ----
        // Summoned from two places: the install worker, directly after a
        // manager install whose consent gate found no browser extension,
        // and the bar's left-click gate when the extension is missing
        // from every installed browser ("none") or from the default
        // browser specifically ("missing-default"). The copy explains
        // that the extension carries the plugin's core marketplace
        // feature; declining it (Cancel) records a dismissal so the bar
        // stops intercepting clicks.
        Column {
          visible: root.stage === "browser-prompt"
          width: cardColumn.width
          spacing: Style.spacing.lg
          PiLine {
            text: "The browser extension carries this plugin's core feature: "
              + "it shows the Install buttons on the official Omarchy "
              + "Marketplace at plugins.omarchy.org, so you can manage "
              + "plugins straight from the website. Installing it is "
              + "highly recommended."
          }
          PiLine {
            visible: root.extPromptReason === "missing-default"
            text: "The extension is already installed in "
              + root.extSeenFamiliesPhrase + ", but not in your default "
              + "browser: the button below adds it there too, so the "
              + "marketplace works wherever you browse."
          }
          PiLine {
            visible: root.extPromptReason !== "missing-default"
            text: "The button below opens the extension in the "
              + root.primaryStoreName + " for your default browser; the "
              + "browser asks before installing anything."
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
        // Horizontal row of square icon buttons with tooltips, centered in the panel.
        Column {
          visible: root.stage === "placement"
          width: cardColumn.width
          spacing: Style.spacing.rowGap
          PiLine {
            text: "Where should the bar icon go?"
            horizontalAlignment: Text.AlignHCenter
          }
          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.spacing.controlGap
            Repeater {
              model: root.barPlacementSections
              delegate: PiButton {
                width: Style.space(51)
                height: Style.space(51)
                labelPixelSize: Style.space(24)
                label: root.sectionIcon(modelData)
                tooltipText: root.sectionLabel(modelData)
                  + (root.currentPlacementSection() === modelData ? " (current)" : (root.defaultSection === modelData ? " (default)" : ""))
                primary: root.currentPlacementSection() === modelData
                onClickedPi: {
                  if (root.placementFromSettings) {
                    root.manageMove(root.pluginId, modelData)
                    root.returnPlacementToSettings()
                  } else if (root.mode === "install") {
                    root.installWithSection(modelData)
                  } else {
                    root.enable(modelData)
                  }
                }
              }
            }
          }
        }

        // Divider spanning the full card width, above the footer action buttons.
        Item {
          id: footerDivider
          visible: footerArea.visible && footerArea.height > 0
          width: cardColumn.width
          implicitHeight: visible ? 1 : 0
          height: implicitHeight

          Rectangle {
            x: -card.contentLeftInset
            width: card.width
            height: 1
            color: Qt.rgba(Color.foreground.r, Color.foreground.g,
              Color.foreground.b, 0.18)
          }
        }

        // ---- footer: confirm / cancel ----
        // Right-to-left layout: the primary action (Install/Uninstall/...)
        // lands rightmost, Cancel to its left, as in standard dialogs. The
        // settings stage additionally pins a left-aligned pair of browser
        // store buttons on the opposite end of the same strip.
        Item {
          id: footerArea
          visible: root.footerVisible
          width: cardColumn.width
          // Even padding on all four sides of the footer strip: the
          // column gap above the buttons (panel-gap) is smaller than the
          // card's footer insets (left, right and below), so the area
          // carries the difference as headroom and the rows sit on its
          // bottom edge: gap + headroom = the inset, everywhere.
          height: Math.max(footerRow.implicitHeight,
            footerStoreRow.implicitHeight)
            + Math.max(0, card.footerInset - cardColumn.spacing)

          // Left end (settings stage only): labeled icon buttons that
          // open this plugin's Chrome Web Store / Firefox Add-ons page in
          // the first installed browser of that family. Identical behavior
          // to the About tab's labeled store buttons (openStoreAndClose
          // queues the launch line, then closes the panel): the store page
          // is the point of the click, so the panel dismisses once the
          // command is queued. PiButton, so the pair carries the same
          // glyph+label treatment, and the exact default control height, as
          // the Close button at the other end of the strip.
          Row {
            id: footerStoreRow
            visible: root.stage === "settings"
            // The strip's side padding is the footer inset, not the body's
            // content inset: reach closer to the card border (two 15% steps).
            anchors.leftMargin: -(card.contentLeftInset - card.footerInset)
            anchors.left: parent.left
            anchors.bottom: parent.bottom
            spacing: Style.spacing.controlGap
            PiButton {
              iconText: "󰊯"
              label: "Chrome extension"
              tooltipText: "Open this plugin's page in the Chrome Web"
                + " Store, in Google Chrome"
              onClickedPi: root.openStoreAndClose("chromeUrl", "chromeBin")
            }
            PiButton {
              iconText: "󰈹"
              label: "Firefox addon"
              tooltipText: "Open this plugin's page in Firefox"
                + " Add-ons, in Firefox"
              onClickedPi: root.openStoreAndClose("firefoxUrl", "firefoxBin")
            }
          }

          Row {
            id: footerRow
            // Stretched equally past both ends of the column: the Close
            // button's right padding lands on the footer inset too.
            width: cardColumn.width + 2 * (card.contentLeftInset - card.footerInset)
            x: -(card.contentLeftInset - card.footerInset)
            // Both rows ride the area's bottom edge (same default control
            // height), so they share one baseline and the strip's top
            // headroom pads the divider gap out to the side insets.
            anchors.bottom: parent.bottom
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
            // Secondary treatment: closing the panel is not an affirmative
            // action, so it carries no accent highlight (the store buttons
            // on the same strip are flat too).
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
            onClickedPi: {
              if (root.placementFromSettings) {
                root.returnPlacementToSettings()
              } else {
                root.close()
              }
            }
          }
          PiButton {
            visible: root.stage === "browser-prompt"
            primary: true
            label: root.primaryExtensionLabel
            onClickedPi: root.openExtensionPage()
          }
          PiButton {
            visible: root.stage === "browser-prompt"
            // Declining writes the dismissal marker first (the bar
            // watches it), so left-clicks open the manage popup again.
            label: "Cancel"
            onClickedPi: root.dismissExtensionPrompt()
          }
          }
        }
      }
    }
  }
}

