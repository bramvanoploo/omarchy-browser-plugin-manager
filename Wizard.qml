import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui

// Omarchy Browser Plugin Manager wizard overlay.
// Summoned by the native messaging host (browser button click) with payload
// {mode, id, repo, name}. The payload is treated as a hint only: the catalog
// entry and the repository manifest are re-fetched and cross-checked before
// anything is displayed, and the user confirms the action in this overlay.
// Installing a bar widget adds a placement step: the user picks the bar
// section (left/center/right); the manifest's default section is labelled
// "(default)" but nothing is preselected, and the install worker enables the
// plugin with the section chosen. Nothing is installed yet at that point, so
// Cancel is a plain close.
// When the action finishes, the result is a desktop notification only: no
// completion dialog is shown and the overlay closes itself.
// Exception: finishing an install/enable of this manager itself enters the
// browser-extension prompt stage. The Omarchy plugin is only half the system;
// the Install buttons in the browser come from the matching browser extension.
// The prompt detects the default browser, sends the user to the Firefox
// add-on page (addons.mozilla.org) for Firefox-based browsers, or to the
// Chrome Web Store page for Chromium-based ones, and explains what happens
// there and why. Cancelling shows a follow-up stage: the plugin does nothing
// without its browser extension, with options to open the extension page,
// cancel, or uninstall the Omarchy plugin (detached worker, since removing
// this plugin unloads the wizard).

Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  // This manager plugin's own id: the browser-extension prompt targets its
  // own extension, never the plugin passed in the payload.
  readonly property string managerId: (root.manifest && root.manifest.id)
    ? String(root.manifest.id) : "bramvanoploo.omarchy-browser-plugin-manager"

  // Browser extension pages: Firefox-based browsers install the add-on from
  // AMO; Chromium-based browsers that support Chrome Web Store extensions
  // install from the CWS listing page (store-assigned item id; the
  // pretty-slug URL is TBD — the bare-id URL redirects to the listing).
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
  // | enabling | placement | disabling | browser-prompt | browser-defer
  property string stage: "review"

  property string pluginId: ""
  property string pluginRepo: ""
  property string pluginName: ""
  // "install" (default) | "uninstall" | "enable" | "disable" — decided by the
  // native host from live local state, never by the page.
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
  property bool isBarWidget: false
  property string defaultSection: "center"
  property string enabledSection: ""
  property int enableTries: 0
  property bool finalCheck: false

  readonly property var manifestKinds: pluginManifest && pluginManifest.kinds
    ? pluginManifest.kinds : []

  readonly property bool needsManifest: root.mode === "install" || root.mode === "enable"

  readonly property string reviewBlocked: {
    if (catalogError.length > 0) return catalogError
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
    var action = ({ install: "Install plugin", uninstall: "Uninstall plugin",
                    enable: "Enable plugin", disable: "Disable plugin" })[root.mode]
    return action || "Plugin setup"
  }

  function stopPending() {
    enableRetryTimer.stop()
    finalVerifyTimer.stop()
    catalogProc.running = false
    manifestProc.running = false
    listProc.running = false
    verifyProc.running = false
  }

  function validPluginId(id) {
    return /^[a-z0-9][a-z0-9.-]{0,127}$/.test(id || "") && String(id).indexOf("..") === -1
  }

  // xdg default-browser id -> which extension family it consumes. Firefox
  // forks (Waterfox, LibreWolf, Tor Browser, IceCat, Zen) take AMO add-ons;
  // Chromium forks (Chrome, Brave, Vivaldi, Edge, ...) take CWS extensions.
  // Unrecognised browsers fall back to Firefox: the AMO listing is live, the
  // CWS listing page is pending.
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
        && newMode !== "browser-prompt" && newMode !== "browser-defer") newMode = "install"
    // Stage before mode: the title binding chooses its source from stage, and
    // assigning a browser-* mode while the old stage is still a confirm stage
    // would index the title map with it (undefined -> "Unable to assign
    // [undefined] to QString").
    stage = (newMode === "browser-prompt" || newMode === "browser-defer") ? newMode : "review"
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
    defaultSection = "center"
    enabledSection = ""
    enableTries = 0
    finalCheck = false

    opened = true

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
    if (mode === "uninstall" || mode === "enable" || mode === "disable") listProc.running = true
  }

  function close() {
    // The registry invokes close() as the plugin's hide handler; hide() in
    // turn calls close(). Clearing `opened` first makes that re-entry a no-op.
    if (!root.opened) return
    root.opened = false
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
               enable: "Plugin enable failed", disable: "Plugin disable failed" })[root.mode]
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

  // Called from the placement step in install mode with an explicit section
  // ("left"/"center"/"right"); the manifest default is marked "(default)" on
  // its own button, so there is no separate "keep default" path.
  function installWithSection(section) {
    if (root.mode !== "install" || root.stage !== "placement") return
    if (!/^(left|center|right)$/.test(section)) return
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
    root.spawnWorker("uninstall")
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
          root.catalogError = "The installer cannot uninstall itself. Remove it in a terminal: omarchy plugin remove bramvanoploo.omarchy-browser-plugin-manager --yes"
        } else if (root.mode === "enable") {
          root.catalogError = ""
          root.stage = "enable-confirm"
        } else if (root.mode === "disable") {
          root.catalogError = ""
          root.stage = "disable-confirm"
        } else {
          root.catalogError = ""
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
      if (exitCode !== 0 && !root.defaultBrowserLoaded) {
        root.defaultBrowserId = ""
        root.defaultBrowserLoaded = true
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
  // Positional parameters ($1=id, $2=name, $3=repo, $4=bar section) are
  // passed directly via execve argv, avoiding temporary script files and
  // shell interpolation.

  function buildWorkerScript(kind) {
    var s = [
      "set -u",
      "ID=\"$1\"",
      "NAME=\"$2\"",
      "REPO=\"$3\"",
      "SECTION=\"$4\"",
      "notify() {",
      "  omarchy-notification-send --app-name omarchy-browser-plugin-manager --expire-time 8000 \"$1\" \"$2\"",
      "}",
      "list() { omarchy plugin list --json 2>/dev/null; }",
      "enabled() { list | jq -e --arg id \"$ID\" 'any(.[]; .id == $id and .enabled == true)' >/dev/null 2>&1; }",
      // The bar layout entry is the real placement record; a missing
      // user config means defaults are in use and nothing verifies it.
      "placed() {",
      "  local f=\"$HOME/.config/omarchy/shell.json\"",
      "  [ -n \"$SECTION\" ] || return 0",
      "  [ -f \"$f\" ] || return 0",
      "  jq -e --arg id \"$ID\" --arg s \"$SECTION\" '(.bar.layout[$s] // []) | any(.[]; .id == $id)' \"$f\" >/dev/null 2>&1",
      "}",
      "OUT=''"
    ]
    if (kind === "install") {
      s = s.concat([
        "# The chosen bar section cannot ride on add's --enable, so clone",
        "# first and let the enable loop below apply --section.",
        "if ! OUT=\"$(omarchy plugin add \"$REPO\" --yes 2>&1)\"; then",
        "  # The clone can land while add fails on its own enable attempt;",
        "  # only re-add when the plugin directory did not arrive.",
        "  if [ ! -d \"$HOME/.config/omarchy/plugins/$ID\" ]; then",
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
        "    PAYLOAD=$(jq -cn --arg id \"$ID\" --arg repo \"$REPO\" --arg name \"$NAME\" '{source:\"worker\",mode:\"browser-prompt\",id:$id,repo:$repo,name:$name}')",
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

        // Header: icon + plugin name + version pill + action subtitle,
        // styled like the OmaGuake settings panel header.
        Row {
          width: cardColumn.width
          spacing: Style.space(14)

          // The browser extension's Install-button glyph: a download stem
          // dropping into an open tray, drawn to the extension's CSS geometry
          // (.pi-icon-install in content.js: 13px box, stem 1x7 at x6, tray
          // border 1, inset 1, height 5, no top side).
          Item {
            id: piIcon
            readonly property real sz: Math.max(Style.font.heading,
              Math.round(headerTextCol.implicitHeight))
            readonly property real u: sz / 13
            readonly property real bw: Math.max(1, Math.round(u))
            width: sz
            height: sz
            anchors.verticalCenter: parent.verticalCenter

            Rectangle {  // stem
              x: Math.round(piIcon.u * 6.5 - piIcon.bw / 2)
              width: piIcon.bw
              height: Math.round(piIcon.u * 7)
              color: Color.accent
            }
            Rectangle {  // tray: left wall
              x: Math.round(piIcon.u)
              y: Math.round(piIcon.sz - piIcon.u * 6)
              width: piIcon.bw
              height: Math.round(piIcon.u * 5)
              color: Color.accent
            }
            Rectangle {  // tray: right wall
              x: Math.round(piIcon.sz - piIcon.u - piIcon.bw)
              y: Math.round(piIcon.sz - piIcon.u * 6)
              width: piIcon.bw
              height: Math.round(piIcon.u * 5)
              color: Color.accent
            }
            Rectangle {  // tray: floor
              x: Math.round(piIcon.u)
              y: Math.round(piIcon.sz - piIcon.u * 2)
              width: Math.round(piIcon.sz - piIcon.u * 2)
              height: piIcon.bw
              color: Color.accent
            }
          }

          Column {
            id: headerTextCol
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Row {
              spacing: Style.space(8)

              Text {
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
        PiLine {
          visible: root.stage !== "browser-prompt" && root.stage !== "browser-defer"
          text: root.pluginName + "  \u00b7  " + root.pluginId
          color: Color.foreground
          font.bold: true
          font.pixelSize: Style.font.title
        }

        // ---- stage: review (install confirmation) ----
        Column {
          visible: root.stage === "review" && root.mode === "install"
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
                || root.stage === "enable-confirm" || root.stage === "disable-confirm")
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
        Column {
          visible: root.stage === "placement"
          width: cardColumn.width
          spacing: Style.spacing.rowGap
          PiLine {
            text: "Where should the bar icon go?"
          }
          Row {
            spacing: Style.spacing.controlGap
            PiButton {
              label: "Left" + (root.defaultSection === "left" ? " (default)" : "")
              onClickedPi: root.mode === "install"
                ? root.installWithSection("left")
                : root.enable("left")
            }
            PiButton {
              label: "Center" + (root.defaultSection === "center" ? " (default)" : "")
              onClickedPi: root.mode === "install"
                ? root.installWithSection("center")
                : root.enable("center")
            }
            PiButton {
              label: "Right" + (root.defaultSection === "right" ? " (default)" : "")
              onClickedPi: root.mode === "install"
                ? root.installWithSection("right")
                : root.enable("right")
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
            visible: root.stage === "review" || root.stage === "uninstall-confirm"
              || root.stage === "enable-confirm" || root.stage === "disable-confirm"
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
            label: "Cancel"
            onClickedPi: root.close()
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
        }
      }
    }
  }
}
