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
// beacon that stops dims the icon: a tab close/pagehide unwatches (file
// gone) right away, a blurred window stamps the record "paused" (dropped on
// the next poll), and a killed browser leaves the record to staleness.
//
// Left click opens a dropdown with the watched plugin's header title (the
// same identity line the wizard dialogs show) and buttons to manage it:
// Install, Uninstall, Update, and moving its bar icon (Left/Center/Right).
// Install, Uninstall, and Update summon the wizard overlay: the beacon
// record is a display hint only, and every action is re-validated and
// confirmed there, exactly like the browser buttons. Moving the icon is a
// plain layout change, so it runs the official `omarchy bar move` directly.
//
// Right click opens the settings panel (same header pattern): a plugin-update
// poll every 10m / 30m / 1h / 5h / daily with a refresh button, two capped
// scrollable per-plugin update lists (verified first, then unverified; each
// with a title, a count, and an install button that updates just that
// plugin), a "Update N plugins now" button (only while updates are
// available), a toggle for updating to unverified latest versions (default:
// verified only), and the two browser-store links with per-family installed
// indicators. The poll
// detects outdated plugins exactly like omaplug does (git HEAD behind
// origin/HEAD via fetch + merge-base); the bar icon carries an
// omaplug-identical accent pill counting the updates the verification
// setting allows to apply, in its top-right corner (hidden at 0), a poll
// that finds new outdated plugins sends a notification offering the update,
// and the settings persist to settings.json in the state dir.
Panel {
  id: root
  moduleName: "bramvanoploo.omarchy-browser-plugin-manager"
  ipcTarget: "bramvanoploo.omarchy-browser-plugin-manager"

  readonly property string managerId: "bramvanoploo.omarchy-browser-plugin-manager"
  readonly property string marketplaceUrl: "https://plugins.omarchy.org/"
  // Must match the beacon interval/staleness in the host and extension:
  // a live beacon renews every 5s, so 12s without a renewal means gone
  // (that is the browser-killed path). An app switch marks the record
  // "paused" right at the blur, so the dimming lands on the next poll.
  readonly property int beaconStaleMs: 12000

  readonly property string stateDir: {
    var base = Quickshell.env("XDG_STATE_HOME")
    if (!base) base = (Quickshell.env("HOME") || "/tmp") + "/.local/state"
    return base + "/omarchy/" + managerId
  }
  readonly property string watchPath: stateDir + "/browser-watch.json"

  // Parsed beacon record ({id, repo, name, pid, ts, paused?}) or null.
  // "paused" is stamped by the host when the tab's browser window loses
  // OS focus; focus regained sends a live record again.
  property var watchState: null
  property real nowMs: 0
  readonly property bool beaconLive: watchState !== null && nowMs > 0
    && (nowMs - Number(watchState.ts) * 1000) < beaconStaleMs
    && watchState.paused !== true

  // What the popup shows. The popup freezes on the plugin captured when it
  // opens: the menu must never swap or lose its content mid-interaction
  // (the record can die while open: the beacon paused by an app switch, the
  // tab closed). Two capture windows stay open: the reload issued on open
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

  // ---- right-click settings panel ---------------------------------------
  // The settings popup is the widget's own popup: it opens on right click
  // independently of any watched page, and is mutually exclusive with the
  // plugin popup (one open at a time). Its outside-click dismissal routes
  // through settingsOwner.close(), the PopupCard owner contract.
  property bool settingsOpen: false
  // Opening the panel (right-click, any path) refreshes the update lists
  // immediately so the shown state is current, not the last poll's.
  onSettingsOpenChanged: {
    if (settingsOpen)
      root.checkForUpdates()
  }
  readonly property QtObject settingsOwner: QtObject {
    function close() { root.settingsOpen = false }
  }

  function toggleSettings() {
    root.close()
    root.settingsOpen = !root.settingsOpen
  }

  function toggleLeft() {
    root.settingsOpen = false
    root.toggle()
  }

  // Settings (persisted to settings.json in the state dir, beside the
  // beacon): update-poll interval and the unverified toggle. Defaults: 1h,
  // verified-only.
  readonly property string settingsPath: stateDir + "/settings.json"
  readonly property var pollIntervalMinutes: [10, 30, 60, 300, 1440]
  readonly property var pollIntervalLabels: ["10m", "30m", "1h", "5h", "Daily"]
  property int pollMinutes: 60
  property bool allowUnverified: false
  property bool settingsLoaded: false
  property bool settingsSaving: false
  property bool settingsSaveFailed: false

  function settingsObject() {
    return { pollMinutes: root.pollMinutes, allowUnverified: root.allowUnverified }
  }

  function applySettings(raw) {
    // settingsLoaded gates saving until a load was attempted: the widget
    // must never overwrite a settings file it has not read yet.
    root.settingsLoaded = true
    try {
      var d = JSON.parse(String(raw || "{}"))
      if (d && typeof d === "object") {
        if (root.pollIntervalMinutes.indexOf(Number(d.pollMinutes)) !== -1)
          root.pollMinutes = Number(d.pollMinutes)
        if (typeof d.allowUnverified === "boolean")
          root.allowUnverified = d.allowUnverified
      }
    } catch (e) {
      // Corrupt file: keep the current (default) values and rewrite below.
    }
    // First run (load failed) and corrupt files land here: write the
    // current values exactly once. Qt.callLater keeps this outside the
    // FileView's own load signal.
    Qt.callLater(root.saveSettings)
  }

  function saveSettings() {
    if (root.settingsSaving || !root.settingsLoaded) return
    var content = JSON.stringify(root.settingsObject(), null, 2) + "\n"
    // Identical content: FileView.setText writes nothing and no save signal
    // ever arrives, so the save-wait timer would flag a false write failure
    // (the file already holds exactly these values: nothing to persist).
    if (settingsFile.text() === content) return
    root.settingsSaving = true
    settingsFile.setText(content)
  }

  function setPollInterval(minutes) {
    if (root.pollIntervalMinutes.indexOf(Number(minutes)) === -1) return
    root.pollMinutes = Number(minutes)
    root.saveSettings()
  }

  function setAllowUnverified(on) {
    var next = on === true
    if (root.allowUnverified === next) return
    root.allowUnverified = next
    root.saveSettings()
    // The verified/unverified lists the user watches change meaning with
    // this toggle, so refresh the available updates immediately. A check
    // already running fetches the full verified-flagged set and applies it
    // under the new setting when it lands, so skipping then is correct.
    root.checkForUpdates()
  }

  // ---- update poll -------------------------------------------------------
  // Every installed user (non-first-party) plugin whose git HEAD is behind
  // origin (omaplug's fetch/merge-base model, so both widgets count the same
  // set). updateList holds the outdated ones ({id, name, installed, latest,
  // verified}); the bar badge and tooltip show the eligibleCount size (hidden
  // at 0) — the subset the verification setting allows to update (all when
  // unverified is on, verified-only otherwise).
  property var updateList: []
  readonly property int updateCount: root.updateList.length
  readonly property int eligibleCount: root.allowUnverified
    ? root.updateCount
    : root.updateList.filter(function (p) { return p.verified === true }).length
  property bool updateChecking: false
  property bool updateCheckFailed: false
  property string lastCheckText: "never"
  // Ids of the last notified outdated set: a poll offers the update once
  // per new set (ids join), so an unchanged repeat poll never nags.
  property string lastNotifiedKey: ""

  function eligibleUpdates() {
    return root.allowUnverified ? root.updateList
      : root.updateList.filter(function (p) { return p.verified === true })
  }

  // The settings panel shows the pending updates as two separate lists so
  // the verification state of every single update stays explicit.
  function verifiedUpdates() {
    return root.updateList.filter(function (p) { return p.verified === true })
  }

  function unverifiedUpdates() {
    return root.updateList.filter(function (p) { return p.verified !== true })
  }

  function checkForUpdates() {
    if (updateCheckProc.running) return
    root.updateChecking = true
    updateCheckProc.running = true
  }

  function applyCheckResult(res) {
    root.updateChecking = false
    if (res && res.ok === true && Array.isArray(res.plugins)) {
      root.updateList = res.plugins
      root.updateCheckFailed = false
      root.lastCheckText = Qt.formatTime(new Date(), "hh:mm")
      // Offer the update when a check finds a new outdated set: the
      // notification is how this widget "offers" anything (the button lives
      // in the settings panel). Held-back updates (verified-only setting
      // off-locks them) stay in the list and explain in the body; the badge
      // counts only the eligible ones.
      var ids = res.plugins.map(function (p) { return String(p.id) }).sort().join(",")
      if (ids !== root.lastNotifiedKey) {
        root.lastNotifiedKey = ids
        if (ids !== "") {
          var n = res.plugins.length
          root.notify("Plugin updates available",
            n + " installed plugin" + (n === 1 ? " has" : "s have") + " updates."
            + " Right-click the bar icon to update"
            + (root.eligibleCount === 0 ? " (enable Unverified in settings)" : "") + ".")
        }
      }
    } else {
      // A failed catalog fetch keeps the last known list (offline must not
      // blank the badge); the panel explains the failed check.
      root.updateCheckFailed = true
    }
  }

  // The browser-extension store pages. The panel shows each family's
  // supported-browser list (the list order doubles as launch priority);
  // installed names are highlighted in accent, and each store button
  // opens its page in the first installed browser of that family.
  readonly property string chromeStoreUrl: "https://chromewebstore.google.com/detail/nalcgjmbglkcmohokidcmogcbpmhkdjf"
  readonly property string firefoxStoreUrl: "https://addons.mozilla.org/firefox/addon/omarchy-browser-plugin-manager/"
  readonly property var chromeBrowsers: [
    { key: "chrome", label: "Chrome", bins: ["google-chrome", "google-chrome-stable"] },
    { key: "chromium", label: "Chromium", bins: ["chromium", "chromium-browser"] },
    { key: "brave", label: "Brave", bins: ["brave-browser", "brave"] },
    { key: "edge", label: "Edge", bins: ["microsoft-edge", "edge"] },
    { key: "vivaldi", label: "Vivaldi", bins: ["vivaldi-stable", "vivaldi"] },
    { key: "opera", label: "Opera", bins: ["opera"] }
  ]
  readonly property var firefoxBrowsers: [
    { key: "firefox", label: "Firefox incl. ESR", bins: ["firefox", "firefox-esr"] },
    { key: "waterfox", label: "Waterfox", bins: ["waterfox"] },
    { key: "librewolf", label: "LibreWolf", bins: ["librewolf"] },
    { key: "tor", label: "Tor Browser", bins: ["torbrowser-launcher", "torbrowser"] },
    { key: "icecat", label: "IceCat", bins: ["icecat"] },
    { key: "zen", label: "Zen", bins: ["zen-browser", "zen"] }
  ]
  // Launcher binary per browser key, from the PATH probe ("" = not installed).
  property var chromeInstalledBins: ({})
  property var firefoxInstalledBins: ({})

  // Probe script: one line per browser "family key bin" (bin "-" when not
  // on PATH). Keys and bins are fixed literals from the lists above, so the
  // interpolation into the script is safe.
  function browserProbeScript() {
    var lines = []
    var groups = [["chrome", root.chromeBrowsers], ["firefox", root.firefoxBrowsers]]
    groups.forEach(function (g) {
      g[1].forEach(function (b) {
        lines.push('hit=""; for b in ' + b.bins.join(" ")
          + '; do command -v "$b" >/dev/null 2>&1 && { hit="$b"; break; }; done;'
          + " echo " + g[0] + " " + b.key + ' "${hit:--}"')
      })
    })
    return lines.join("; ")
  }

  function applyProbeOutput(text) {
    var chrome = {}
    var firefox = {}
    String(text || "").split("\n").forEach(function (line) {
      var parts = String(line).trim().split(" ")
      if (parts.length !== 3) return
      var bin = parts[2] === "-" ? "" : parts[2]
      if (parts[0] === "chrome") chrome[parts[1]] = bin
      else if (parts[0] === "firefox") firefox[parts[1]] = bin
    })
    root.chromeInstalledBins = chrome
    root.firefoxInstalledBins = firefox
  }

  function firstInstalledBin(families, installed) {
    for (var i = 0; i < families.length; i++)
      if (installed[families[i].key]) return String(installed[families[i].key])
    return ""
  }

  // Display name of the browser a store button launches, for the button
  // label; "" means the family is not installed, so xdg-open opens the
  // system default browser.
  function firstInstalledLabel(families, installed) {
    for (var i = 0; i < families.length; i++)
      if (installed[families[i].key]) return String(families[i].label)
    return ""
  }

  function storeButtonLabel(base, launchLabel) {
    // The list label "Firefox incl. ESR" is only the ESR clarification, which
    // the list line above already carries; the button keeps the short name.
    var short = String(launchLabel || "").split(" incl.")[0]
    return base + " (" + (short !== "" ? short : "default browser") + ")"
  }

  // Support list as rich text: installed names get the accent color. The
  // hex form is required because styled text carries no Color objects.
  function supportHtml(families, installed) {
    var s = String(Color.accent).replace("#", "")
    var hex = "#" + s.substring(s.length - 6)
    return families.map(function (b) {
      var label = String(b.label)
      if (installed[b.key])
        return '<span style="color:' + hex + '">' + label + "</span>"
      return label
    }).join(", ")
  }

  readonly property string chromeSupportHtml: supportHtml(chromeBrowsers, chromeInstalledBins)
  readonly property string firefoxSupportHtml: supportHtml(firefoxBrowsers, firefoxInstalledBins)
  readonly property string chromeLaunchBin: firstInstalledBin(chromeBrowsers, chromeInstalledBins)
  readonly property string firefoxLaunchBin: firstInstalledBin(firefoxBrowsers, firefoxInstalledBins)
  readonly property string chromeLaunchLabel: firstInstalledLabel(chromeBrowsers, chromeInstalledBins)
  readonly property string firefoxLaunchLabel: firstInstalledLabel(firefoxBrowsers, firefoxInstalledBins)

  function openStore(url, bin) {
    // The store page must open in its own family, so the browser found by
    // the probe is launched directly; xdg-open is only the fallback when
    // the family is not installed at all.
    var target = String(bin || "") !== ""
      ? [String(bin), String(url)]
      : ["xdg-open", String(url)]
    Quickshell.execDetached(target)
  }

  // Batch update runs as a detached bash worker (the wizard's per-plugin
  // update pattern): a git pull takes time, and updating the manager itself
  // reloads the shell and destroys this widget mid-run. Ids ride in as
  // argv ($1..$n): no shell interpolation of plugin ids.
  // Each CLI call ends with "omarchy-shell shell rescanPlugins" when it
  // updated something, which reloaded the bar once per plugin. The worker
  // shadows omarchy-shell on PATH to swallow those per-plugin rescans and
  // fires one real rescan after the whole batch, so the bar reloads once.
  readonly property string updateWorkerScript: [
    "set -u",
    "notify() {",
    "  omarchy-notification-send --app-name omarchy-browser-plugin-manager --expire-time 8000 \"$1\" \"$2\"",
    "}",
    "real_shell=/usr/share/omarchy/bin/omarchy-shell",
    "bin_dir=$(mktemp -d)",
    "printf '%s\\n' '#!/bin/bash' '[ \"${1:-}\" = shell ] && [ \"${2:-}\" = rescanPlugins ] && exit 0' 'exec '\"$real_shell\"' \"$@\"' > \"$bin_dir/omarchy-shell\"",
    "chmod +x \"$bin_dir/omarchy-shell\"",
    "export PATH=\"$bin_dir:$PATH\"",
    "ok=0; fail=0; failed=\"\"",
    "while [ $# -gt 0 ]; do",
    "  if OUT=\"$(omarchy plugin update \"$1\" --yes 2>&1)\"; then",
    "    ok=$((ok+1))",
    "  else",
    "    fail=$((fail+1)); failed=\"$failed $1\"",
    "  fi",
    "  shift",
    "done",
    "rm -rf \"$bin_dir\"",
    "if [ \"$ok\" -gt 0 ]; then",
    "  \"$real_shell\" -q shell rescanPlugins >/dev/null 2>&1 || true",
    "fi",
    "if [ \"$fail\" -gt 0 ]; then",
    "  notify \"Plugin updates finished\" \"$ok updated, $fail failed:$failed\"",
    "elif [ \"$ok\" -gt 0 ]; then",
    "  notify \"Plugins updated\" \"$ok plugin(s) updated to the latest version.\"",
    "else",
    "  notify \"No plugin updated\" \"No plugin update was applied.\"",
    "fi"
  ].join("\n")

  // Runs the detached worker for the given plugin ids: the batch button
  // passes every eligible id, the per-row install buttons a single id.
  function startUpdate(ids) {
    ids = (ids || []).map(String)
    if (ids.length === 0) return
    var argv = ["bash", "-c", root.updateWorkerScript, "omarchy-bpm-update"]
    Quickshell.execDetached(argv.concat(ids))
    // Closing the popups is harmless: the shell reloads when the manager
    // itself is among the updated plugins, and the detached worker
    // outlives that reload with its summary notification.
    root.settingsOpen = false
    root.close()
  }

  function startBatchUpdate() {
    root.startUpdate(root.eligibleUpdates().map(function (p) { return String(p.id) }))
  }


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
  // popup is open, cached per plugin id. catalogLoading marks the fetch in
  // flight: the thumbnail box shows its 16:9 loading placeholder while true,
  // so the panel height is reserved and never jumps when the image lands.
  property var catalogEntry: null
  property string catalogForId: ""
  property bool catalogLoading: false

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
    root.catalogLoading = true
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

  // Persisted settings file. Atomic writes, no watching (we are the only
  // writer): a change signal right after our own setText would reload and
  // feed the write cycle. A failed write is surfaced in the settings panel
  // (settingsSaveFailed) and retried by the next user action; the save-wait
  // timer below releases the saving flag if no signal ever arrives.
  FileView {
    id: settingsFile
    path: root.settingsPath
    atomicWrites: true
    printErrors: false
    onLoaded: root.applySettings(text())
    onLoadFailed: root.applySettings("")
    onSaved: {
      root.settingsSaving = false
      root.settingsSaveFailed = false
    }
    onSaveFailed: {
      root.settingsSaving = false
      root.settingsSaveFailed = true
    }
  }

  Timer {
    interval: 3000
    running: root.settingsSaving
    onTriggered: {
      // Release the saving flag so the next user action can retry the write.
      root.settingsSaving = false
      root.settingsSaveFailed = true
    }
  }

  // This plugin's own manifest: the settings header shows the manager
  // version in the same pill the plugin popup uses for the watched plugin.
  readonly property string pluginDir: String(Qt.resolvedUrl(".")).replace("file://", "").replace(/\/$/, "")
  property string managerVersion: ""
  FileView {
    id: managerManifestFile
    path: root.pluginDir + "/manifest.json"
    printErrors: false
    onLoaded: {
      try {
        var m = JSON.parse(text())
        root.managerVersion = String(m && m.version ? m.version : "")
      } catch (e) {
        root.managerVersion = ""
      }
    }
    onLoadFailed: root.managerVersion = ""
  }

  // Update poll: detection identical to omaplug's plugin-state.sh — an
  // installed user plugin is outdated when its git HEAD is a strict ancestor
  // of origin/HEAD (git fetch + merge-base --is-ancestor), so both widgets
  // agree on the exact same set (version numbers in manifest/catalog can lag
  // behind real commits, e.g. a fix shipped without a version bump). Dev
  // symlinks, non-git dirs, detached HEADs, and dirty working trees are
  // skipped (omaplug shows those as LOCAL_CHANGES, never as an UPDATE), a
  // failed fetch counts as "not an
  // update" (offline never invents one). Emits the behind set as JSON
  // ({ok, plugins: [{id, name, installed, latest, verified}]}); the catalog
  // (15 MB, far over the kernel's per-arg limit, so it rides in on stdin —
  // --argjson on the command line fails with "Argument list too long") only
  // decorates entries with the verified flag and the latest version.
  readonly property string checkScript: [
    "set -u",
    "export GIT_TERMINAL_PROMPT=0",
    "export GIT_SSH_COMMAND=\"${GIT_SSH_COMMAND:-ssh -oBatchMode=yes}\"",
    "PLUG=\"$HOME/.config/omarchy/plugins\"",
    "list=$(omarchy plugin list --json 2>/dev/null) || list=\"[]\"",
    "catalog=$(curl -fsSL --proto '=https' --max-time 30 --max-filesize 16777216 \"https://plugins.omarchy.org/catalog.json\" 2>/dev/null) || catalog=\"\"",
    "[ -n \"$catalog\" ] || catalog='{\"plugins\":[]}'",
    "rows=\"\"",
    "for ID in $(jq -r '(if type == \"array\" then . else [] end)[] | select(type == \"object\" and ((.firstParty // false) | not)) | .id // empty' <<<\"$list\" 2>/dev/null); do",
    "  case \"$ID\" in *[!a-z0-9.-]*|.*|*..*) continue ;; esac",
    "  D=\"$PLUG/$ID\"",
    "  [ -L \"$D\" ] && continue",
    "  [ -d \"$D/.git\" ] || continue",
    "  HEAD_SHA=$(git -C \"$D\" rev-parse HEAD 2>/dev/null) || continue",
    "  git -C \"$D\" remote get-url origin >/dev/null 2>&1 || continue",
    "  git -C \"$D\" symbolic-ref --quiet HEAD >/dev/null 2>&1 || continue",
    "  [ -z \"$(git -C \"$D\" status --porcelain --untracked-files=normal 2>/dev/null)\" ] || continue",
    "  timeout 15 git -C \"$D\" fetch --quiet origin HEAD 2>/dev/null || continue",
    "  REMOTE=$(git -C \"$D\" rev-parse --verify FETCH_HEAD 2>/dev/null) || continue",
    "  if [ -n \"$REMOTE\" ] && [ \"$HEAD_SHA\" != \"$REMOTE\" ] && git -C \"$D\" merge-base --is-ancestor \"$HEAD_SHA\" \"$REMOTE\" 2>/dev/null; then",
    "    M=\"$D/manifest.json\"",
    "    VER=$(jq -r '.version // \"\"' \"$M\" 2>/dev/null)",
    "    NAME=$(jq -r '.name // \"\"' \"$M\" 2>/dev/null | tr -d '\\t\\r\\n')",
    "    rows+=$(printf '%s\\t%s\\t%s' \"$ID\" \"$VER\" \"$NAME\")$'\\n'",
    "  fi",
    "done",
    "plugins=$(printf '%s' \"$catalog\" | jq -c --arg rows \"$rows\" '",
    "(.plugins // []) as $pl",
    "| [ $rows | split(\"\\n\")[] | select(length > 0) | split(\"\\t\")",
    "  | {id: .[0], installed: .[1], name: (if length > 2 then .[2] else \"\" end) }",
    "] | map(. as $p",
    "  | ($pl | map(select(type == \"object\" and .id == $p.id)) | first) as $e",
    "  | {id: $p.id, name: (if $p.name != \"\" then $p.name else $p.id end),",
    "    installed: ($p.installed | tostring),",
    "    latest: ((if $e == null then \"\" else ($e.version // \"\") end) | tostring),",
    "    verified: ((if $e == null then \"\" else ($e.verificationStatus // \"\") end) | tostring) == \"verified\"})",
    "' 2>/dev/null) || plugins=\"[]\"",
    "[ \"${plugins:0:1}\" = \"[\" ] || plugins=\"[]\"",
    "printf '%s' \"{\\\"ok\\\":true,\\\"plugins\\\":$plugins}\""
  ].join("\n")

  Process {
    id: updateCheckProc
    command: ["bash", "-c", root.checkScript]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var res = null
        try { res = JSON.parse(String(text || "")) } catch (e) { res = null }
        root.applyCheckResult(res)
      }
    }
    onExited: function (exitCode) {
      // No stdout handler ran (process died before printing): count it as a
      // failed check, not an empty catalog.
      if (exitCode !== 0 && root.updateChecking) {
        root.updateChecking = false
        root.updateCheckFailed = true
      }
    }
  }

  // Browser install probe: every supported browser's launcher names are
  // checked on PATH, one "family key bin" line per browser, feeding the
  // accent highlighting in the panel's browser lists and the store
  // buttons' launch targets.
  Process {
    id: browserCheckProc
    command: ["bash", "-c", root.browserProbeScript()]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyProbeOutput(text)
    }
  }

  // The update poll: fires at boot and on the chosen interval. The interval
  // binding makes an interval change take effect on the next run.
  Timer {
    interval: root.pollMinutes * 60000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.checkForUpdates()
  }

  Component.onCompleted: {
    // The beacon host creates the state dir lazily; the settings file needs
    // it at widget start (its write goes through a shell, mkdir first).
    Quickshell.execDetached(["mkdir", "-p", root.stateDir])
    managerManifestFile.reload()
    settingsFile.reload()
    browserCheckProc.running = true
    Qt.callLater(root.checkForUpdates)
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
      // The two popups are mutually exclusive (also enforced in the toggle
      // handlers); this covers the panel controller's own open paths.
      root.settingsOpen = false
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
        root.catalogLoading = false
      }
    }
    onExited: function (exitCode) {
      if (exitCode !== 0) {
        root.catalogEntry = null
        root.catalogLoading = false
      }
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

  // Extensions glyph (Nerd Font "cod-extensions", U+EAE6): the puzzle
  // piece, universal browser-extension symbol. BarIconButton draws it at
  // the bar's optical canvas size with its default colors: dim normally,
  // active (accent) color while a beacon is live ("lit up").
  // NOTE: write the glyph as a literal character: QML \u escapes consume
  // exactly 4 hex digits, so \uXXXXX would draw U+XXXX plus a stray digit.
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    active: root.beaconLive
    tooltipText: (root.beaconLive
      ? root.watchedName() + " \u00b7 open in browser \u00b7 click to manage"
      : "Browser Plugin Manager")
      + (root.eligibleCount > 0
        ? " \u00b7 " + root.eligibleCount + " plugin" + (root.eligibleCount === 1 ? " has" : "s have")
          + " updates (right-click)"
        : root.updateCount > 0
          ? " \u00b7 " + root.updateCount + " plugin" + (root.updateCount === 1 ? " has" : "s have")
            + " updates, all unverified (right-click)"
          : "")

    onPressed: function (code) {
      // Left: the plugin popup; right: the settings panel (mutually
      // exclusive, both route through the toggle helpers).
      if (code === Qt.LeftButton) root.toggleLeft()
      else if (code === Qt.RightButton) root.toggleSettings()
    }

    // Update counter badge: pixel-identical to omaplug's pending-update
    // indicator — accent pill anchored to the icon's top-right corner with a
    // bar-background border, bold caption*0.85 text in the theme background
    // tone (dark on the light accent; flips with the theme), "9+" cap,
    // hidden at 0. It counts the updates the verification setting actually allows to
    // apply (eligibleCount), not every outdated plugin.
    Rectangle {
      id: updateBadge
      visible: root.eligibleCount > 0
      anchors.top: parent.top
      anchors.right: parent.right
      z: 10
      readonly property string countText: root.eligibleCount > 9 ? "9+" : String(root.eligibleCount)
      implicitWidth: Math.max(Style.space(14), updateBadgeText.implicitWidth + Style.space(6))
      implicitHeight: Style.space(14)
      radius: height / 2
      color: Color.accent
      border.width: 1
      border.color: root.bar ? root.bar.background : "transparent"

      Text {
        id: updateBadgeText
        anchors.centerIn: parent
        text: updateBadge.countText
        color: Color.background
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.caption * 0.85
        font.bold: true
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

  // Icon-only square variant of BWButton, used by the update-list rows.
  component BWIconButton: BorderSurface {
    id: bwIcon
    property string label: ""
    property bool primary: false
    signal clickedBw
    width: Style.space(30)
    height: Style.space(30)
    radius: Style.cornerRadius
    color: !enabled ? "transparent"
      : primary
        ? (bwIconMouse.containsMouse ? Util.alpha(Color.accent, 0.2) : Util.alpha(Color.accent, 0.12))
        : (bwIconMouse.containsMouse ? Util.alpha(Color.foreground, 0.12) : Util.alpha(Color.foreground, 0.05))
    borderSpec: Border.flat(enabled
      ? (primary ? Color.accent : Util.alpha(Color.foreground, 0.3))
      : Util.alpha(Color.foreground, 0.2), 1)
    Text {
      anchors.centerIn: parent
      text: bwIcon.label
      font.family: "Material Icons"
      font.pixelSize: Math.round(Style.space(17))
      color: bwIcon.enabled
        ? (bwIcon.primary ? Color.accent : Color.foreground)
        : Util.alpha(Color.foreground, 0.35)
    }
    MouseArea {
      id: bwIconMouse
      anchors.fill: parent
      hoverEnabled: true
      enabled: bwIcon.enabled
      cursorShape: Qt.PointingHandCursor
      onClicked: bwIcon.clickedBw()
    }
  }

  // One titled, capped, scrollable list of pending updates with a per-row
  // install button. The section hides itself when there is nothing to show.
  component BWUpdateSection: Column {
    id: bwSection
    property string title: ""
    property var items: []
    signal pluginPicked(string id)
    spacing: Style.space(8)
    visible: items.length > 0

    Row {
      width: bwSection.width
      spacing: Style.space(8)
      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: bwSection.title
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        font.bold: true
      }
      Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        width: secCountLabel.implicitWidth + Style.space(10)
        height: secCountLabel.implicitHeight + Style.space(4)
        radius: height / 2
        color: Util.alpha(Color.accent, 0.15)
        Text {
          id: secCountLabel
          anchors.centerIn: parent
          text: bwSection.items.length
          color: Color.accent
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          font.bold: true
        }
      }
    }

    Rectangle {
      width: bwSection.width
      radius: Style.cornerRadius
      color: "#15151c"
      height: Math.min(secColumn.implicitHeight + Style.space(16), Style.space(190))
      clip: true
      Flickable {
        anchors.fill: parent
        anchors.margins: Style.space(8)
        contentHeight: secColumn.implicitHeight
        boundsBehavior: Flickable.StopAtBounds
        Column {
          id: secColumn
          width: parent.width
          spacing: Style.space(6)
          Repeater {
            model: bwSection.items
            Row {
              width: secColumn.width
              spacing: Style.space(10)
              Text {
                anchors.verticalCenter: parent.verticalCenter
                width: secColumn.width - secVersions.implicitWidth - secButton.width
                  - (parent.spacing * 2)
                elide: Text.ElideRight
                text: modelData.name
                color: Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.body
              }
              Text {
                id: secVersions
                anchors.verticalCenter: parent.verticalCenter
                text: modelData.installed + " \u2192 " + modelData.latest
                color: Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
              BWIconButton {
                id: secButton
                anchors.verticalCenter: parent.verticalCenter
                label: "\uE2C9" // install (download) icon
                primary: true
                onClickedBw: bwSection.pluginPicked(String(modelData.id))
              }
            }
          }
        }
      }
    }
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

      // Header (the wizard/OmaGuake panel header pattern): extensions glyph
      // (accent Text, no background, no border) + plugin name + version pill
      // + muted status/id subtitle.
      Row {
        width: popupColumn.width
        spacing: Style.space(14)

        Text {
          text: ""
          font.family: Style.font.family
          font.pixelSize: Math.max(Style.font.heading,
            Math.round(bwHeaderTextCol.implicitHeight))
          color: Color.accent
          anchors.verticalCenter: parent.verticalCenter
        }

        Column {
          id: bwHeaderTextCol
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(2)

          Row {
            spacing: Style.space(8)

            Text {
              text: root.popupLive ? root.watchedName() : "Browser Plugin Manager"
              font.family: Style.font.family
              font.pixelSize: Style.font.title
              font.bold: true
              color: Color.foreground
              anchors.verticalCenter: parent.verticalCenter
            }

            Rectangle {
              visible: root.popupLive && root.statusChecked
                && root.pluginInstalled && root.installedVersion !== ""
              anchors.verticalCenter: parent.verticalCenter
              height: Style.space(18)
              width: bwHeaderVersionText.implicitWidth + Style.space(12)
              radius: Style.cornerRadius > 0 ? 4 : 0
              color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.15)
              border.color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.4)
              border.width: 1

              Text {
                id: bwHeaderVersionText
                anchors.centerIn: parent
                text: "v" + String(root.installedVersion)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: true
                color: Color.accent
              }
            }
          }

          Text {
            text: root.popupLive
              ? (root.statusChecked
                 ? ((root.pluginInstalled
                     ? (root.pluginEnabled ? "Installed \u00b7 enabled" : "Installed \u00b7 disabled")
                     : "Not installed")
                    + "  \u00b7  " + String(root.watchState ? root.watchState.id : ""))
                 : "Checking installed state\u2026")
              : "No plugin page is open in the browser"
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            color: Color.muted
          }
        }
      }

      // Preview thumbnail from the marketplace catalog, card proportions.
      // The box is shown from the moment the panel opens on a live plugin
      // (loading placeholder) and keeps its height until the image has
      // landed: the panel never jumps mid-read.
      Rectangle {
        id: thumbBox
        visible: root.popupLive && (root.catalogThumb !== "" || root.catalogLoading)
        width: popupColumn.width
        // Proportional height at the full panel width, capped at the
        // marketplace card's 16:9: wide-short thumbs (e.g. 499x48 banners)
        // get their own short box; taller images (e.g. 320x720) cap here
        // and overflow, hidden by clip. While the catalog entry is not in
        // yet, catalogThumbNative is the cap itself, so the placeholder
        // reserves exactly the 16:9 box most cards end up having.
        height: visible
          ? Math.round((width - 2) * Math.min(root.catalogThumbNative, root.catalogThumbRatio)) + 2
          : 0
        radius: Style.cornerRadius
        color: Util.alpha(Color.foreground, 0.05)
        border.color: Util.alpha(Color.foreground, 0.15)
        border.width: 1
        clip: true

        Image {
          id: thumbImage
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

        // Loading placeholder: a soft highlight band sweeping over the box
        // while the catalog entry is being fetched and the thumbnail image
        // is still decoding; it disappears the moment the image is Ready.
        Rectangle {
          id: thumbShimmer
          anchors.fill: parent
          radius: Style.cornerRadius
          color: "transparent"
          clip: true
          visible: thumbBox.visible
            && (root.catalogLoading
                || root.catalogThumb === ""
                || thumbImage.status !== Image.Ready)

          Rectangle {
            id: shimmerBand
            width: Math.round(thumbBox.width * 0.45)
            height: parent.height
            gradient: Gradient {
              orientation: Gradient.Horizontal
              GradientStop { position: 0.0; color: Qt.rgba(1, 1, 1, 0) }
              GradientStop { position: 0.5; color: Util.alpha(Color.foreground, 0.07) }
              GradientStop { position: 1.0; color: Qt.rgba(1, 1, 1, 0) }
            }
            SequentialAnimation on x {
              running: thumbShimmer.visible
              loops: Animation.Infinite
              NumberAnimation {
                from: -shimmerBand.width
                to: thumbBox.width
                duration: 1100
                easing: Easing.InOutQuad
              }
              PauseAnimation { duration: 350 }
            }
          }
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

  // ---- right-click settings panel ----------------------------------------
  // Same header pattern as the plugin popup (glyph + title + version pill),
  // own PopupCard with the settingsOwner as dismissal owner. Content: the
  // update-poll interval selector with an immediate-refresh button, status
  // lines, the batch "Update N plugins now" action (hidden when nothing is
  // updatable), the unverified-versions toggle, and the two browser-store
  // links with per-family installed indicators.
  PopupCard {
    id: settingsPopup
    anchorItem: button
    owner: root.settingsOwner
    bar: root.bar
    open: root.settingsOpen
    padding: Style.space(24)
    contentWidth: settingsPopup.fittedContentWidth(Style.space(430))
    contentHeight: settingsPopup.fittedContentHeight(settingsColumn.implicitHeight, Style.space(560))

    Column {
      id: settingsColumn
      width: parent ? parent.width : 0
      spacing: Style.space(14)

      Row {
        width: settingsColumn.width
        spacing: Style.space(14)

        Text {
          text: ""
          font.family: Style.font.family
          font.pixelSize: Math.max(Style.font.heading,
            Math.round(spHeaderTextCol.implicitHeight))
          color: Color.accent
          anchors.verticalCenter: parent.verticalCenter
        }

        Column {
          id: spHeaderTextCol
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(2)

          Row {
            spacing: Style.space(8)

            Text {
              text: "Browser Plugin Manager"
              font.family: Style.font.family
              font.pixelSize: Style.font.title
              font.bold: true
              color: Color.foreground
              anchors.verticalCenter: parent.verticalCenter
            }

            Rectangle {
              visible: root.managerVersion !== ""
              anchors.verticalCenter: parent.verticalCenter
              height: Style.space(18)
              width: spVersionText.implicitWidth + Style.space(12)
              radius: Style.cornerRadius > 0 ? 4 : 0
              color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.15)
              border.color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.4)
              border.width: 1

              Text {
                id: spVersionText
                anchors.centerIn: parent
                text: "v" + root.managerVersion
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: true
                color: Color.accent
              }
            }
          }

          Text {
            text: "Settings \u00b7 updates every "
              + root.pollIntervalLabels[Math.max(0, root.pollIntervalMinutes.indexOf(root.pollMinutes))]
              + (root.updateChecking ? "  \u00b7  checking\u2026"
                : root.lastCheckText !== "never" ? "  \u00b7  last check " + root.lastCheckText : "")
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            color: Color.muted
          }
        }
      }

      // Poll interval: five equal segments (selected one primary-marked)
      // and the refresh button to check for updates immediately.
      BWLine {
        width: settingsColumn.width
        text: "Check for plugin updates:"
      }
      GridLayout {
        width: settingsColumn.width
        columns: 6
        columnSpacing: Style.spacing.controlGap

        Repeater {
          model: root.pollIntervalMinutes
          delegate: BWButton {
            Layout.fillWidth: true
            Layout.preferredHeight: Style.space(30)
            label: root.pollIntervalLabels[index]
            primary: root.pollMinutes === modelData
            onClickedBw: root.setPollInterval(modelData)
          }
        }
        BWButton {
          Layout.preferredWidth: Style.space(30)
          Layout.preferredHeight: Style.space(30)
          label: "\uF021"
          enabled: !root.updateChecking
          onClickedBw: root.checkForUpdates()
        }
      }

      BWLine {
        width: settingsColumn.width
        visible: root.updateCount > 0
        text: root.updateCount + " installed plugin" + (root.updateCount === 1 ? " has" : "s have")
          + " updates"
          + (root.eligibleCount < root.updateCount
            ? " \u00b7 " + root.eligibleCount + " updatable with the current verification setting"
            : "")
      }
      BWLine {
        width: settingsColumn.width
        visible: !root.updateChecking && !root.updateCheckFailed
          && root.updateCount === 0 && root.lastCheckText !== "never"
        text: "All installed plugins are up to date."
      }
      BWLine {
        width: settingsColumn.width
        visible: root.updateCheckFailed
        text: "Catalog unreachable: showing the last known update list."
      }
      BWLine {
        width: settingsColumn.width
        visible: root.settingsSaveFailed
        color: Color.urgent
        text: "Settings file could not be written: changes apply this session only."
      }

      // Per-plugin update lists: verified first, unverified below, each
      // with a concise title, a live count, a capped scrollable area, and
      // an install button per row that updates just that plugin through
      // the same detached worker as the batch button (startUpdate).
      BWUpdateSection {
        width: settingsColumn.width
        title: "Verified plugin updates"
        items: root.verifiedUpdates()
        onPluginPicked: function (id) { root.startUpdate([id]) }
      }

      BWUpdateSection {
        width: settingsColumn.width
        title: "Unverified plugin updates"
        items: root.unverifiedUpdates()
        onPluginPicked: function (id) { root.startUpdate([id]) }
      }

      // Batch update (hidden while nothing is updatable): runs the
      // eligible plugins through detached workers, one notification at the
      // end (startBatchUpdate).
      BWButton {
        visible: root.eligibleCount > 0
        width: settingsColumn.width
        height: Style.space(30)
        primary: true
        label: "Update " + root.eligibleCount + " plugin"
          + (root.eligibleCount === 1 ? "" : "s") + " now"
        onClickedBw: root.startBatchUpdate()
      }

      // Unverified toggle: default off (verified catalog entries only).
      Row {
        width: settingsColumn.width
        spacing: Style.space(10)

        Column {
          width: parent.width - spUnverifiedSwitch.implicitWidth - parent.spacing
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(2)

          Text {
            text: "Update to unverified versions"
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            color: Color.foreground
          }
          Text {
            width: parent.width
            wrapMode: Text.Wrap
            text: "Off: plugins only update to catalog-verified versions."
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            color: Color.muted
          }
        }

        ToggleSwitch {
          id: spUnverifiedSwitch
          anchors.verticalCenter: parent.verticalCenter
          checked: root.allowUnverified
          onToggled: root.setAllowUnverified(!checked)
        }
      }

      // Browser stores: the supported-browser list with installed names
      // highlighted in accent, above half-width buttons that open the
      // store page in the first installed browser of that family. One
      // grid (text row, button row) so the rows size to their tallest
      // cell and the buttons align. The cells take an explicit equal
      // half width (the grid's fill alone sizes columns to content, which
      // makes the two store buttons uneven). RichText is required: the
      // StyledText format silently drops the span color.
      GridLayout {
        id: spStoreGrid
        width: settingsColumn.width
        columns: 2
        columnSpacing: Style.spacing.controlGap
        rowSpacing: Style.space(6)

        Text {
          Layout.fillWidth: true
          Layout.preferredWidth: (spStoreGrid.width - spStoreGrid.columnSpacing) / 2
          wrapMode: Text.Wrap
          textFormat: Text.RichText
          text: root.chromeSupportHtml
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          color: Color.muted
        }
        Text {
          Layout.fillWidth: true
          Layout.preferredWidth: (spStoreGrid.width - spStoreGrid.columnSpacing) / 2
          wrapMode: Text.Wrap
          textFormat: Text.RichText
          text: root.firefoxSupportHtml
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          color: Color.muted
        }

        BWButton {
          Layout.fillWidth: true
          Layout.preferredWidth: (spStoreGrid.width - spStoreGrid.columnSpacing) / 2
          Layout.preferredHeight: Style.space(30)
          label: root.storeButtonLabel("Chrome Web Store", root.chromeLaunchLabel)
          onClickedBw: root.openStore(root.chromeStoreUrl, root.chromeLaunchBin)
        }
        BWButton {
          Layout.fillWidth: true
          Layout.preferredWidth: (spStoreGrid.width - spStoreGrid.columnSpacing) / 2
          Layout.preferredHeight: Style.space(30)
          label: root.storeButtonLabel("Firefox Add-ons", root.firefoxLaunchLabel)
          onClickedBw: root.openStore(root.firefoxStoreUrl, root.firefoxLaunchBin)
        }
      }
    }
  }
}
