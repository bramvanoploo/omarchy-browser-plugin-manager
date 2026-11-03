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
// Left click focuses the browser and selects the first open marketplace
// tab (plugins.omarchy.org) when one is present — the extension keeps the
// host posted with every open tab, and the click routes through a focus
// request the tab answers — and the dropdown stays closed for that click.
// Without a marketplace tab, left click opens a dropdown with the watched
// plugin's header title (the same identity line the wizard panels show)
// and buttons to manage it:
// Install, Uninstall, Update, and moving its bar icon (a grid over every
// shell bar section, the active one marked).
// Install, Uninstall, and Update summon the wizard overlay: the beacon
// record is a display hint only, and every action is re-validated and
// confirmed there, exactly like the browser buttons. Moving the icon is a
// plain layout change, so it runs the official `omarchy bar move` directly.
//
// Right click opens the settings panel (same header pattern): two per-plugin
// update lists capped to three visible rows that fade at the edge when more
// rows scroll below (verified first, then unverified; each
// with a title, a count, and a compact install button that updates just that
// plugin) with a "Update N plugins now" button above them (only while updates
// are available), a plugin-update poll every 10m / 30m / 1h / 5h / daily with
// a refresh button below the lists, a toggle for updating to unverified
// latest versions (default:
// verified only), and the two browser-store links with per-family installed
// indicators. Every update, single or batch, goes through a confirmation card
// in the panel before the worker runs. The poll
// detects outdated plugins exactly like omaplug does (git HEAD behind
// origin/HEAD via fetch + merge-base); the bar icon carries an
// omaplug-identical accent pill counting the updates the verification
// setting allows to apply, in its top-right corner (hidden at 0), a poll
// that finds new outdated plugins sends a notification offering the update
// (silenceable from settings), and the settings persist to settings.json in
// the state dir.
Panel {
  id: root
  moduleName: "bramvanoploo.omarchy-browser-plugin-manager"
  ipcTarget: "bramvanoploo.omarchy-browser-plugin-manager"

  IpcHandler {
    target: "bramvanoploo.omarchy-browser-plugin-manager.bar"
    function openSettings(): void { root.toggleSettings() }
    function closeSettings(): void { root.settingsOpen = false }
    function toggleSettings(): void { root.toggleSettings() }
    function togglePopup(): void { root.toggleLeft() }
  }

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
  readonly property string tabsPath: stateDir + "/browser-tabs.json"
  readonly property string focusPath: stateDir + "/browser-focus.json"

  // Presence heartbeats: every open marketplace tab (catalog or detail,
  // focused or not) renews a record in browser-tabs.json every ~2s. A
  // fresh record means a left click can jump the browser to that tab
  // instead of opening the dropdown. Records age out by ts (host prunes
  // on write; killed browsers simply stop renewing).
  readonly property int tabStaleMs: 10000
  property int liveTabCount: 0

  // True while a fresh heartbeat marks the tab the user is looking at (the
  // active tab of a focused browser window) as a plugin detail page. The
  // bar icon's left click then opens the popup panel straight away: the
  // plugin is on screen, so there is nothing to jump to.
  property bool activePluginPage: false

  // Focus jump request: written to browser-focus.json; the host stamps
  // consumedBy with the key of the visiting tab that answers, and that tab
  // asks the browser to focus its window and select itself. The popup
  // stays closed for that click. A request nobody answers is dropped by
  // the host as stale; the local timer forgets it in parallel.
  property bool focusPending: false
  property int focusNonce: 0
  readonly property int focusRequestTimeoutMs: 6000

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
  property bool isBarWidget: false
  property string statusForId: ""
  property string moveSection: ""
  property string moveOutput: ""
  property string enabledOutput: ""

  // ---- settings panel ----------------------------------------------------
  // The settings panel is a system overlay (the wizard): it opens on right
  // click independently of any watched page, renders the snapshot published
  // below, and routes every control back through the cmd file. Opening
  // never starts a check (the poll and the setting toggles refresh the
  // lists). Re-summoning while open refreshes the panel in place; the
  // wizard sends a "closed" command when it closes, which stops the
  // republish timer.
  property bool settingsOpen: false

  function toggleSettings() {
    root.close()
    // Fresh command session: drop the seen-seq bookkeeping, truncate
    // any log a previous (possibly crashed) session left on disk, and
    // mint a session id the wizard echoes in its "closed" command. The
    // truncate is async, so a stale "closed" can be read before it
    // lands; the session gate makes that read inert.
    root.settingsSeenCmd = ({})
    root.settingsSession = String(Date.now()) + "-"
      + String(Math.floor(Math.random() * 1e6))
    root.consumeSettingsCmd()
    root.settingsOpen = true
    root.publishSettingsSnapshot()
    root.summonSettingsWizard()
  }

  function toggleLeft() {
    root.settingsOpen = false
    root.toggle()
  }

  // Settings (persisted to settings.json in the state dir, beside the
  // beacon): update-poll interval, the unverified toggle, and the
  // update-notification toggle. Defaults: 1h, verified-only, notifications
  // on.
  readonly property string settingsPath: stateDir + "/settings.json"
  // System settings panel plumbing: the wizard overlay renders from a
  // snapshot published to settings-payload.json and writes commands back
  // through settings-cmd.json. The widget owns settings.json, the catalog
  // poll, and the detached workers; the wizard is pure presentation.
  readonly property string settingsPayloadPath: stateDir + "/settings-payload.json"
  readonly property string settingsCmdPath: stateDir + "/settings-cmd.json"
  property var settingsSeenCmd: ({})
  // Identifies the current settings-panel open session. The wizard echoes
  // it in its "closed" command; a "closed" from an older session (one left
  // on disk, read before the truncate-on-open lands) is ignored, so it can
  // never instantly re-close a freshly opened panel.
  property string settingsSession: ""
  readonly property var pollIntervalMinutes: [10, 30, 60, 300, 1440]
  readonly property var pollIntervalLabels: ["10m", "30m", "1h", "5h", "Daily"]
  property int pollMinutes: 60
  property bool allowUnverified: false
  property bool notifyUpdates: true
  property bool settingsLoaded: false
  property bool settingsSaving: false
  property bool settingsSaveFailed: false

  function settingsObject() {
    return { pollMinutes: root.pollMinutes, allowUnverified: root.allowUnverified,
      notifyUpdates: root.notifyUpdates }
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
        else
          root.allowUnverified = false
        if (typeof d.notifyUpdates === "boolean")
          root.notifyUpdates = d.notifyUpdates
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

  function setNotifyUpdates(on) {
    var next = on === true
    if (root.notifyUpdates === next) return
    root.notifyUpdates = next
    root.saveSettings()
    // Re-enabling should offer the currently pending set again: clear the
    // dedupe key and re-poll. Turning it off needs nothing: the poll keeps
    // updating the badge and lists silently.
    root.lastNotifiedKey = ""
    root.checkForUpdates()
  }

  // ---- update poll -------------------------------------------------------
  // Every installed user (non-first-party) plugin whose git HEAD is behind
  // origin (omaplug's fetch/merge-base model, so both widgets count the same
  // set). updateList holds the outdated ones ({id, name, installed, latest,
  // remote, verified}); the bar badge and tooltip show the eligibleCount
  // size (hidden at 0) — the subset the verification setting allows to
  // update (all when unverified is on, verified-only otherwise).
  property var updateList: []
  readonly property int updateCount: root.updateList.length
  readonly property int eligibleCount: root.allowUnverified
    ? root.updateCount
    : root.updateList.filter(function (p) { return p.verified === true }).length
  property bool updateChecking: false
  property bool updateCheckFailed: false
  property string lastCheckText: "never"
  // True when the settings group between the update rules carries content
  // (a status line, the batch button, or a list): with no updates, no
  // status line, and no batch button — e.g. first open before the first
  // check — the rule above the group must hide, or two rules stack.
  readonly property bool updatesGroupVisible: root.updateChecking
    || root.updateCount > 0
    || root.updateCheckFailed
    || root.settingsSaveFailed
    || (root.lastCheckText !== "never")
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
    root.publishSettingsSnapshot()
    updateCheckProc.running = true
  }

  function applyCheckResult(res) {
    root.updateChecking = false
    if (res && res.ok === true && Array.isArray(res.plugins)) {
      root.updateList = res.plugins
      root.updateCheckFailed = false
      root.lastCheckText = Qt.formatTime(new Date(), "hh:mm")
      // Offer the update when a check finds a new eligible set: the
      // notification is how this widget "offers" anything (the button lives
      // in the settings panel). Unverified updates are not counted while
      // "Update to unverified versions" is disabled; they stay visible in
      // the panel and tooltip, and the badge/notification count only the
      // eligible ones.
      var eligible = root.eligibleUpdates()
      var ids = eligible.map(function (p) { return String(p.id) }).sort().join(",")
      if (ids !== root.lastNotifiedKey) {
        root.lastNotifiedKey = ids
        // The dedupe key tracks the set even while notifications are off,
        // so re-enabling offers only a set that changed in the meantime
        // (setNotifyUpdates clears the key to re-offer the current one).
        if (ids !== "" && root.notifyUpdates) {
          var n = eligible.length
          root.notify("Plugin updates available",
            n + " plugin" + (n === 1 ? " update is" : " updates are") + " available."
            + " Right-click the bar icon to update.")
        }
      }
    } else {
      // A failed catalog fetch keeps the last known list (offline must not
      // blank the badge); the panel explains the failed check.
      root.updateCheckFailed = true
    }
    root.publishSettingsSnapshot()
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
  // reloads the shell and destroys this widget mid-run. Specs ride in as
  // argv ($1..$n) as "id:expected_sha" (sha empty for unverified): no shell
  // interpolation of plugin ids. A verified spec pins the update to the
  // catalog's verificationCommit: the worker re-fetches and fast-forwards to
  // exactly that commit, and fails closed if upstream advanced past it after
  // the poll, so confirming a "Verified plugin update" can never load an
  // unreviewed commit. Unverified specs (and verified rows whose poll fetch
  // had no sha) go through the plain CLI, which loads the current branch tip
  // under the user's explicit unverified choice.
  // Each CLI call ends with "omarchy-shell shell rescanPlugins" when it
  // updated something, which reloaded the bar once per plugin. The worker
  // shadows omarchy-shell on PATH to swallow those per-plugin rescans and
  // fires one real rescan after the whole batch, so the bar reloads once.
  readonly property string updateWorkerScript: [
    "set -u",
    "export PATH=\"${OMARCHY_PATH:-/usr/share/omarchy}/bin:$PATH\"",
    "notify_cmd=\"${OMARCHY_PATH:-/usr/share/omarchy}/bin/omarchy-notification-send\"",
    "command -v \"$notify_cmd\" >/dev/null 2>&1 || notify_cmd=\"$(command -v omarchy-notification-send 2>/dev/null || echo omarchy-notification-send)\"",
    "notify() {",
    "  \"$notify_cmd\" --app-name omarchy-browser-plugin-manager --expire-time 8000 \"$1\" \"$2\"",
    "}",
    "real_shell=\"${OMARCHY_PATH:-/usr/share/omarchy}/bin/omarchy-shell\"",
    "command -v \"$real_shell\" >/dev/null 2>&1 || real_shell=\"$(command -v omarchy-shell 2>/dev/null || echo /usr/share/omarchy/bin/omarchy-shell)\"",
    "plug=\"${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins\"",
    // In-progress system panel (same protocol as the wizard's workers): the
    // first argv is a display label (plugin name, or "N plugins" for a
    // batch); publish a marker file per run (removed on any exit) and
    // summon the wizard on its running stage, which polls the marker
    // directory and closes itself once no fresh marker remains.
    "LABEL=\"${1:-plugins}\"; shift",
    "STATE_DIR=\"${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/bramvanoploo.omarchy-browser-plugin-manager\"",
    "MARK_DIR=\"$STATE_DIR/in-progress\"",
    "mkdir -p \"$MARK_DIR\" 2>/dev/null || true",
    "MARK=\"$MARK_DIR/$$-$(date +%s)-${RANDOM:-0}.json\"",
    "trap 'rm -f \"$MARK\"' EXIT",
    "jq -cn --arg mode \"update\" --arg name \"$LABEL\" '{mode:$mode,id:\"\",name:$name,started:(now|floor)}' > \"$MARK\" 2>/dev/null || true",
    "PAYLOAD=$(jq -cn --arg name \"$LABEL\" '{source:\"worker\",mode:\"running\",id:\"\",name:$name,action:\"update\"}' 2>/dev/null)",
    "[ -n \"$PAYLOAD\" ] && \"$real_shell\" -q shell summon bramvanoploo.omarchy-browser-plugin-manager \"$PAYLOAD\" >/dev/null 2>&1 || true",
    "export GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=true",
    "export GIT_SSH_COMMAND=\"${GIT_SSH_COMMAND:-ssh -oBatchMode=yes}\"",
    "# Verified pin: refuse unless the freshly fetched tip is exactly the",
    "# reviewed commit, then fast-forward to only that commit and validate",
    "# (same validation and ORIG_HEAD rollback as the CLI). Fails closed:",
    "# any divergence between poll and update leaves the plugin untouched.",
    "update_pinned() { # id expected_sha -> stdout explains the outcome",
    "  local id=\"$1\" sha=\"$2\" d=\"$plug/$1\" tip",
    "  timeout 30 git -C \"$d\" fetch --quiet origin HEAD || { echo \"fetch failed\"; return 1; }",
    "  tip=$(git -C \"$d\" rev-parse --verify FETCH_HEAD 2>/dev/null) || { echo \"fetch produced no tip\"; return 1; }",
    "  [ \"$tip\" = \"$sha\" ] || { echo \"upstream advanced past the verified commit\"; return 1; }",
    "  git -C \"$d\" merge --ff-only \"$sha\" >/dev/null 2>&1 || { echo \"cannot fast-forward to the verified commit\"; return 1; }",
    "  if ! omarchy plugin validate \"$d\" >/dev/null 2>&1; then",
    "    git -C \"$d\" reset --hard ORIG_HEAD >/dev/null 2>&1",
    "    echo \"update failed validation (rolled back)\"",
    "    return 1",
    "  fi",
    "  echo \"pinned\"",
    "}",
    "bin_dir=$(mktemp -d)",
    "printf '%s\\n' '#!/bin/bash' '[ \"${1:-}\" = shell ] && [ \"${2:-}\" = rescanPlugins ] && exit 0' 'exec '\"$real_shell\"' \"$@\"' > \"$bin_dir/omarchy-shell\"",
    "chmod +x \"$bin_dir/omarchy-shell\"",
    "export PATH=\"$bin_dir:$PATH\"",
    "ok=0; fail=0; failed=\"\"",
    "while [ $# -gt 0 ]; do",
    "  spec=\"$1\"",
    "  id=\"${spec%%:*}\"; expected=\"${spec#*:}\"",
    "  case \"$id\" in *[!a-z0-9.-]*|.*|*..*|*:*) id=\"\" ;; esac",
    "# A spec carrying a pin must pin to a full 40 hex sha; an unpinned spec",
    "# carries an empty sha. A present-but-invalid sha is a violation and",
    "# never falls through to the unverified CLI path (fail closed).",
    "  bad_sha=0",
    "  if [ -n \"$expected\" ]; then",
    "    if [ ${#expected} -ne 40 ]; then",
    "      bad_sha=1",
    "    else",
    "      tmp_sha=\"${expected//[0-9a-f]/}\"",
    "      [ -n \"$tmp_sha\" ] && bad_sha=1",
    "    fi",
    "  fi",
    "  OUT=\"\"",
    "  if [ -n \"$id\" ] && [ \"$bad_sha\" -eq 0 ] && [ -n \"$expected\" ] && [ -d \"$plug/$id/.git\" ]; then",
    "    if OUT=$(update_pinned \"$id\" \"$expected\"); then",
    "      ok=$((ok+1))",
    "    else",
    "      fail=$((fail+1)); failed=\"$failed $id ($OUT)\"",
    "    fi",
    "  elif [ -n \"$id\" ] && [ \"$bad_sha\" -eq 0 ] && OUT=\"$(omarchy plugin update \"$id\" --yes 2>&1)\" && [ $? -eq 0 ]; then",
    "    ok=$((ok+1))",
    "  else",
    "    fail=$((fail+1)); failed=\"$failed ${id:-$spec}\"",
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
    "  notify \"Plugins updated\" \"$ok plugin(s) updated to the latest verified version.\"",
    "else",
    "  notify \"No plugin updated\" \"No plugin update was applied.\"",
    "fi"
  ].join("\n")

  // The worker spec for one poll entry: "id:remote_sha". The sha is the
  // commit the poll fetched and matched against the catalog's
  // verificationCommit; the worker pins verified updates to it and ignores
  // it for unverified ones (entries never carry a sha the poll did not see).
  function updateSpec(p) {
    return String(p.id) + ":" + (p.remote ? String(p.remote) : "")
  }

  // Worker specs for a whole list (the batch button).
  function updateSpecs(list) {
    return (list || []).map(updateSpec)
  }

  // Uninstall worker: runs the official CLI removal (omarchy plugin remove
  // --yes) per plugin id, mirroring its id validation (same pattern as the
  // CLI's valid_plugin_id), then fires one rescan so the bar drops removed
  // icons. The CLI unloads an enabled plugin from the shell itself; a
  // symlinked plugin (dev clone) is only unlinked, never followed. Detached
  // like the update worker, so removing this manager itself still finishes
  // and notifies after the shell reload destroys the widget.
  readonly property string uninstallWorkerScript: [
    "set -u",
    "export PATH=\"${OMARCHY_PATH:-/usr/share/omarchy}/bin:$PATH\"",
    "notify_cmd=\"${OMARCHY_PATH:-/usr/share/omarchy}/bin/omarchy-notification-send\"",
    "command -v \"$notify_cmd\" >/dev/null 2>&1 || notify_cmd=\"$(command -v omarchy-notification-send 2>/dev/null || echo omarchy-notification-send)\"",
    "notify() {",
    "  \"$notify_cmd\" --app-name omarchy-browser-plugin-manager --expire-time 8000 \"$1\" \"$2\"",
    "}",
    "real_shell=\"${OMARCHY_PATH:-/usr/share/omarchy}/bin/omarchy-shell\"",
    "command -v \"$real_shell\" >/dev/null 2>&1 || real_shell=\"$(command -v omarchy-shell 2>/dev/null || echo /usr/share/omarchy/bin/omarchy-shell)\"",
    // In-progress system panel (same protocol as the wizard's workers): the
    // first argv is a display label (plugin name, or "N plugins" for a
    // batch); publish a marker file per run (removed on any exit) and
    // summon the wizard on its running stage, which polls the marker
    // directory and closes itself once no fresh marker remains.
    "LABEL=\"${1:-plugins}\"; shift",
    "STATE_DIR=\"${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/bramvanoploo.omarchy-browser-plugin-manager\"",
    "MARK_DIR=\"$STATE_DIR/in-progress\"",
    "mkdir -p \"$MARK_DIR\" 2>/dev/null || true",
    "MARK=\"$MARK_DIR/$$-$(date +%s)-${RANDOM:-0}.json\"",
    "trap 'rm -f \"$MARK\"' EXIT",
    "jq -cn --arg mode \"uninstall\" --arg name \"$LABEL\" '{mode:$mode,id:\"\",name:$name,started:(now|floor)}' > \"$MARK\" 2>/dev/null || true",
    "PAYLOAD=$(jq -cn --arg name \"$LABEL\" '{source:\"worker\",mode:\"running\",id:\"\",name:$name,action:\"uninstall\"}' 2>/dev/null)",
    "[ -n \"$PAYLOAD\" ] && \"$real_shell\" -q shell summon bramvanoploo.omarchy-browser-plugin-manager \"$PAYLOAD\" >/dev/null 2>&1 || true",
    "ok=0; fail=0; failed=\"\"",
    "while [ $# -gt 0 ]; do",
    "  id=\"$1\"",
    "  case \"$id\" in *[!A-Za-z0-9._-]*|*..*|'') id=\"\" ;; esac",
    "  if [ -n \"$id\" ] && omarchy plugin remove \"$id\" --yes >/dev/null 2>&1; then",
    "    ok=$((ok+1))",
    "  else",
    "    fail=$((fail+1)); failed=\"$failed $id\"",
    "  fi",
    "  shift",
    "done",
    "if [ \"$ok\" -gt 0 ]; then",
    "  \"$real_shell\" -q shell rescanPlugins >/dev/null 2>&1 || true",
    "fi",
    "if [ \"$fail\" -gt 0 ]; then",
    "  notify \"Plugin removals finished\" \"$ok removed, $fail failed:$failed\"",
    "elif [ \"$ok\" -gt 0 ]; then",
    "  notify \"Plugins uninstalled\" \"$ok plugin(s) removed.\"",
    "else",
    "  notify \"No plugin removed\" \"No plugin was uninstalled.\"",
    "fi"
  ].join("\n")

  // Runs the detached uninstall worker for the given plugin ids (the
  // per-row uninstall buttons pass a single one, after confirmation).
  function startUninstall(ids) {
    ids = (ids || []).map(String).filter(function (s) { return s !== "" })
    if (ids.length === 0) return
    var argv = ["bash", "-c", root.uninstallWorkerScript, "omarchy-bpm-uninstall",
      ids.length === 1 ? ids[0] : ids.length + " plugins"]
    Quickshell.execDetached(argv.concat(ids))
    // Closing the popups is harmless: removing this manager unloads the
    // widget, and the detached worker outlives that with its notification.
    root.settingsOpen = false
    root.close()
  }

  // Runs the detached worker for the given specs: the batch button passes
  // every eligible spec, the per-row install buttons a single one.
  function startUpdate(specs) {
    specs = (specs || []).map(String)
    if (specs.length === 0) return
    var label = specs.length === 1
      ? String(specs[0]).split(":")[0] : specs.length + " plugins"
    var argv = ["bash", "-c", root.updateWorkerScript, "omarchy-bpm-update", label]
    Quickshell.execDetached(argv.concat(specs))
    // Closing the popups is harmless: the shell reloads when the manager
    // itself is among the updated plugins, and the detached worker
    // outlives that reload with its summary notification.
    root.settingsOpen = false
    root.close()
  }

  // ---- system settings panel (wizard overlay) ----------------------------
  // Snapshot the wizard renders: settings, check state, and the two update
  // lists (names/versions only: plain-text rendering on the wizard side
  // keeps remote strings inert). Published on open and while the panel is
  // open (FileView skips identical content, so the wizard repaints only on
  // real changes).
  function settingsSnapshotRows(list) {
    return (list || []).map(function (p) {
      return {
        id: String(p.id), name: String(p.name || p.id),
        from: String(p.installed || ""), to: String(p.latest || ""),
        verified: p.verified === true
      }
    })
  }

  function settingsSnapshot() {
    return {
      managerVersion: String(root.managerVersion || ""),
      pollMinutes: Number(root.pollMinutes),
      pollValues: root.pollIntervalMinutes,
      pollLabels: root.pollIntervalLabels,
      allowUnverified: root.allowUnverified === true,
      notifyUpdates: root.notifyUpdates === true,
      lastCheckText: String(root.lastCheckText || "never"),
      updateChecking: root.updateChecking === true,
      updateCheckFailed: root.updateCheckFailed === true,
      settingsSaveFailed: root.settingsSaveFailed === true,
      verified: settingsSnapshotRows(root.verifiedUpdates()),
      unverified: settingsSnapshotRows(root.unverifiedUpdates()),
      chromeLabel: root.storeButtonLabel("Chrome Web Store", root.chromeLaunchLabel),
      firefoxLabel: root.storeButtonLabel("Firefox Add-ons", root.firefoxLaunchLabel),
      chromeUrl: root.chromeStoreUrl,
      firefoxUrl: root.firefoxStoreUrl,
      chromeBin: String(root.chromeLaunchBin || ""),
      firefoxBin: String(root.firefoxLaunchBin || ""),
      // Supported-browser highlight lines: built locally from hardcoded
      // family labels (installed ones wrapped in an accent span), so the
      // RichText never carries remote markup.
      chromeSupport: root.chromeSupportHtml,
      firefoxSupport: root.firefoxSupportHtml
    }
  }

  // Publishing rides a Process (same pattern as the wizard's command
  // writer): FileView writes are unreliable in this environment (external
  // deletes desync its in-memory text, and non-atomic setText silently
  // no-ops), which showed up as the overlay never learning that a clicked
  // value landed. The snapshot rides in as a process argument — a stdin-
  // fed `cat > file` hangs because Quickshell never closes the stdin pipe,
  // so the process never finishes and every later publish is stuck behind
  // it — and `head -c` with a bound above the real byte count ends the
  // stream at printf's EOF. The flush chain serializes back-to-back
  // publishes.
  Process {
    id: settingsPayloadWriteProc
    command: ["sh", "-c",
      'mkdir -p "${1%/*}" && printf %s "$3" | head -c "$2" > "$1"',
      "sh", root.settingsPayloadPath,
      // 3x the JS string length (a UTF-16 unit is at most 3 UTF-8 bytes)
      // plus one, so the bound always exceeds the byte count.
      String(Math.min(65536, root.settingsPayloadWriteText.length * 3 + 1)),
      root.settingsPayloadWriteText]
    // Quickshell Process exit notification: overridable onExited handler
    // (onFinished: is not a signal; assigning it fails the component load).
    onExited: function (exitCode) { root.flushSettingsPayload() }
  }
  property string settingsPayloadWriteText: ""
  property string settingsPayloadStarted: "\u0000"

  function flushSettingsPayload() {
    if (settingsPayloadWriteProc.running) return
    if (root.settingsPayloadWriteText === root.settingsPayloadStarted) return
    root.settingsPayloadStarted = root.settingsPayloadWriteText
    settingsPayloadWriteProc.running = true
  }

  function publishSettingsSnapshot() {
    root.settingsPayloadWriteText = JSON.stringify(root.settingsSnapshot()) + "\n"
    root.flushSettingsPayload()
  }

  function summonSettingsWizard() {
    var payload = JSON.stringify({
      source: "bar", mode: "settings", snapshot: root.settingsSnapshot(),
      session: root.settingsSession
    })
    var summoned = false
    if (root.bar && root.bar.shell && typeof root.bar.shell.summon === "function")
      summoned = root.bar.shell.summon(root.moduleName, payload) === true
    if (!summoned)
      Quickshell.execDetached(["omarchy-shell", "-q", "shell", "summon", root.moduleName, payload])
  }

  // Commands from the settings overlay: the file is an append log (one
  // JSON object per line, see the wizard's writeSettingsCmd). Every line
  // with an unseen seq is dispatched; commands carry the session id the
  // wizard received with its summon payload, and a command from any other
  // session (the log the bar's truncate removes lazily, a panel that
  // closed, a previous session's clicks) is ignored, so stale lines can
  // never replay settings writes. run_update re-derives the worker specs
  // from the live eligible list by id, so a stale panel can never update
  // a plugin the current poll no longer offers.
  function dispatchSettingsCmd(raw) {
    var lines = String(raw || "").split("\n")
    var handled = false
    for (var i = 0; i < lines.length; i++) {
      var cmd = null
      try { cmd = JSON.parse(String(lines[i] || "")) } catch (e) { continue }
      if (!cmd || typeof cmd !== "object") continue
      var seq = String(cmd.seq || "")
      if (seq === "" || root.settingsSeenCmd[seq] === true) continue
      var session = String(cmd.session || "")
      // The overlay announces itself while it is open (on summon and with
      // every snapshot poll). The open flag can drift from the overlay's
      // real state (a re-summon after a shell reload, any summon that did
      // not route through toggleSettings), and while it is stale every
      // control in the panel is inert: the widget republishes the
      // pre-click snapshot and the overlay repaints back to it. The
      // announcement re-adopts the overlay's session and opens the widget
      // side, so the channel self-heals within a poll cycle.
      if (String(cmd.action || "") === "panel_open") {
        root.settingsSeenCmd[seq] = true
        if (session !== root.settingsSession) {
          root.settingsSession = session
          root.settingsOpen = true
          root.publishSettingsSnapshot()
        } else
          root.settingsOpen = true
        handled = true
        continue
      }
      if (!root.settingsOpen) continue
      if (session !== root.settingsSession) continue
      root.settingsSeenCmd[seq] = true
      root.applySettingsCmd(cmd)
      handled = true
    }
    if (handled) root.consumeSettingsCmd()
  }

  function applySettingsCmd(cmd) {
    var action = String(cmd.action || "")
    if (action === "closed") {
      // Strict session match: a "closed" carrying no (or an older) session
      // id predates this panel opening and must never close it.
      if (String(cmd.session || "") !== root.settingsSession) return
      root.settingsOpen = false
    } else if (action === "set_allow_unverified") {
      root.setAllowUnverified(cmd.on === true)
    } else if (action === "set_notify_updates") {
      root.setNotifyUpdates(cmd.on === true)
    } else if (action === "set_poll_interval") {
      root.setPollInterval(cmd.minutes)
    } else if (action === "refresh") {
      root.checkForUpdates()
    } else if (action === "open_store") {
      root.openStore(String(cmd.url || ""), String(cmd.bin || ""))
    } else if (action === "run_update") {
      var ids = (cmd.ids || []).map(String)
      var list = root.eligibleUpdates().filter(function (p) {
        return ids.indexOf(String(p.id)) !== -1
      })
      root.startUpdate(root.updateSpecs(list))
    } else if (action === "run_uninstall") {
      root.startUninstall((cmd.ids || []).map(String))
    }
  }

  // Truncate the command log (consumed after dispatch, and on open, so a
  // previous session's never-dispatched commands never replay). The rm
  // rides a Process: FileView.setText("") silently skips when its
  // in-memory text already matches, which in this environment (external
  // writes invisible) it nearly always does after the wizard's first
  // write, so the truncate would never land. The consume flag chains a
  // consume requested while a rm is still running.
  property bool settingsCmdConsumePending: false

  function consumeSettingsCmd() {
    root.settingsCmdConsumePending = true
    if (!settingsCmdConsumeProc.running)
      settingsCmdConsumeProc.running = true
  }

  Process {
    id: settingsCmdConsumeProc
    command: ["sh", "-c", 'rm -f "$1"', "sh", root.settingsCmdPath]
    onExited: function (exitCode) {
      if (root.settingsCmdConsumePending) {
        root.settingsCmdConsumePending = false
        settingsCmdConsumeProc.running = true
      }
    }
  }

  // Command channel: neither FileView's file watch (no external-write
  // events in this environment) nor FileRead's promise (never settles
  // here) can deliver the commands, so the file is cat'ed by a Process
  // on a poll. The poll runs always: while the panel is open every 500ms,
  // and while the widget thinks it is closed at a slower cadence, so a
  // panel that opens without routing through toggleSettings (a re-summon
  // after a shell reload) is heard by its self-announcements and the
  // channel self-heals. Commands are deduped by seq, so re-reading the
  // same file is inert.
  Process {
    id: settingsCmdReadProc
    command: ["cat", root.settingsCmdPath]
    // StdioCollector.streamFinished is a promise-style signal that, like
    // FileRead, never settles in this environment, so it silently drops
    // every batch and the buttons look dead. The collected stdout is
    // readable on the StdioCollector itself, so dispatch on onExited,
    // which the consume (rm) process shows is delivered reliably.
    stdout: StdioCollector {
      id: settingsCmdReadOut
      waitForEnd: true
    }
    onExited: function (_code) {
      root.dispatchSettingsCmd(String(settingsCmdReadOut.text || ""))
    }
  }

  Timer {
    interval: root.settingsOpen ? 500 : 1800
    running: true
    repeat: true
    triggeredOnStart: true
    // Self-heal: assigning running = true is a no-op on a Process that is
    // still running, so one run that wedges (a cat killed by a config
    // reload mid-stream, stdout never reported finished) stops the loop
    // forever and every later command piles up in the file unconsumed,
    // which is what makes the settings buttons look dead. A healthy cat
    // of a small file finishes in milliseconds, so if it is still running
    // a full interval after it was started it is wedged: kill it, and the
    // next tick starts a fresh one.
    onTriggered: {
      if (settingsCmdReadProc.running)
        settingsCmdReadProc.signal(9)
      else
        settingsCmdReadProc.running = true
    }
  }

  // Republish while the settings panel is open: list, check-state, and
  // setting changes land in the overlay within 400ms (FileView writes
  // identical content as a no-op, so this is cheap when idle).
  Timer {
    interval: 400
    running: root.settingsOpen
    triggeredOnStart: false
    onTriggered: root.publishSettingsSnapshot()
  }

  // Installed plugin version, from the local plugin manifest (display gate
  // for the Update button: show it only when the catalog version is newer).
  property string installedVersion: ""

  readonly property string pluginsDir: {
    var base = Quickshell.env("XDG_CONFIG_HOME") || ((Quickshell.env("HOME") || "/tmp") + "/.config")
    return base + "/omarchy/plugins"
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

  // Version of the watched plugin: prefers local installed version, falls back
  // to catalog version, displayed in the panel header next to the title.
  readonly property string watchedVersion: {
    if (root.installedVersion) return String(root.installedVersion)
    var e = root.catalogEntry
    if (e && e.version) return String(e.version)
    return ""
  }

  function compareVersions(a, b) {
    var sa = String(a || "").trim().replace(/^v/i, "")
    var sb = String(b || "").trim().replace(/^v/i, "")
    var pa = sa.split(".")
    var pb = sb.split(".")
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

  // Section of the omarchy bar layout (one of Util.barSections) that holds
  // the watched plugin's icon, "" when unknown. Bar layout entries carry
  // the plugin id; omarchy bar move writes the same file we read.
  property string iconSection: ""
  function parseIconSection(raw) {
    var sec = ""
    var id = root.watchState ? String(root.watchState.id) : ""
    // Scan every section the shell knows, not just the classic trio:
    // omarchy bar move can place icons in any of them.
    var order = (typeof Util !== "undefined" && Array.isArray(Util.barSections))
      ? Util.barSections : ["left", "centerBegin", "center", "centerEnd", "right", "tray"]
    try {
      var d = JSON.parse(raw)
      var lay = d && d.bar && d.bar.layout ? d.bar.layout : {}
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
      root.isBarWidget = false
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

  // Presence records: count the tabs with a fresh heartbeat. Shape-checked
  // (the file is host-written, a corrupt/foreign file must not light the
  // click path).
  function applyTabs(raw) {
    var count = 0
    var activePage = false
    var s = String(raw || "").trim()
    if (s) {
      var obj = null
      try { obj = JSON.parse(s) } catch (e) { obj = null }
      var tabs = obj && Array.isArray(obj.tabs) ? obj.tabs : []
      var nowSec = Date.now() / 1000
      for (var i = 0; i < tabs.length; ++i) {
        var t = tabs[i]
        if (t && typeof t === "object" && typeof t.key === "string" && t.key !== ""
          && typeof t.url === "string" && t.url.indexOf("https://plugins.omarchy.org/") === 0
          && Number(t.ts) > 0 && !isNaN(Number(t.ts))
          && (nowSec - Number(t.ts)) * 1000 < root.tabStaleMs
          && (Number(t.ts) - nowSec) * 1000 < root.tabStaleMs) {
          count++
          // The heartbeat flags the tab the user is looking at (active tab
          // of a focused window); on a plugin detail page that is the
          // left-click-opens-the-panel case.
          if (t.active === true
            && t.url.indexOf("https://plugins.omarchy.org/plugin.html") === 0)
            activePage = true
        }
      }
    }
    root.liveTabCount = count
    root.activePluginPage = activePage
  }

  // Ask the browser to raise the first live marketplace tab: write the
  // focus request; the next visit heartbeat from any tab answers it (the
  // host stamps consumedBy) and that tab focuses its window and selects
  // itself. This click never opens the dropdown.
  function requestFocusTab() {
    root.focusNonce += 1
    root.focusPending = true
    focusFile.setText(JSON.stringify({ ts: Date.now(), nonce: root.focusNonce, consumedBy: "" }))
    focusTimer.restart()
  }

  function clearFocusRequest() {
    focusTimer.stop()
    if (root.focusPending) {
      root.focusPending = false
      if (focusFile.text() !== "")
        focusFile.setText("") // atomicWrites: empty content removes the file
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
  // Bar sections offered by the "move this plugin's bar icon" row: the
  // shell's own section list (Util.barSections), the same source the
  // wizard's placement stage uses. omarchy bar move accepts each.
  readonly property var barMoveSections: {
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

  function moveIcon(section) {
    if (!root.watchState) return
    if (root.barMoveSections.indexOf(section) === -1) return
    root.moveSection = section
    root.moveOutput = ""
    moveProc.command = [
      "bash", "-c",
      'omarchy bar move "$1" --section "$2" 2>/dev/null || omarchy bar put "$1" --section "$2" 2>/dev/null || omarchy plugin enable "$1" --section "$2"',
      "bpm-move",
      String(root.watchState.id),
      section
    ]
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

  // Presence records (visited marketplace tabs). Like the beacon, the host
  // rewrites atomically, so this is polled on the 2s timer, not watched.
  FileView {
    id: tabFile
    path: root.tabsPath
    printErrors: false
    onLoaded: root.applyTabs(text())
    onLoadFailed: function (_error) {
      root.applyTabs("")
    }
  }

  // Focus jump request round-trip: we write it, the host stamps consumedBy
  // when a visiting tab answers, and our polls see that and remove the
  // file. The host removes an unanswered request as stale (FileNotFound
  // here), which also ends the request locally.
  FileView {
    id: focusFile
    path: root.focusPath
    printErrors: false
    atomicWrites: true
    onLoaded: {
      if (!root.focusPending) return
      var obj = null
      try { obj = JSON.parse(String(text() || "{}")) } catch (e) { obj = null }
      if (obj && typeof obj === "object" && String(obj.consumedBy || "") !== "")
        root.clearFocusRequest()
    }
    onLoadFailed: function (error) {
      if (root.focusPending && error === FileViewError.FileNotFound)
        root.clearFocusRequest()
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
  // ({ok, plugins: [{id, name, installed, latest, remote, verified}]}); the
  // catalog (15 MB, far over the kernel's per-arg limit, so it rides in on
  // stdin — --argjson on the command line fails with "Argument list too
  // long") only decorates entries with the latest version and the verified
  // flag. Verification is pinned to the catalog's verificationCommit, so an
  // entry is verified only when the fetched remote tip IS that exact commit:
  // if upstream advanced after the catalog observation (remote tip differs),
  // the new tip was never reviewed and the update is demoted to unverified.
  // Each entry's remote (the fetched tip sha) is the commit a verified
  // update pins to in the worker (updateWorkerScript re-verifies it).
  readonly property string checkScript: [
    "set -u",
    "export GIT_TERMINAL_PROMPT=0",
    "export GIT_ASKPASS=true",
    "export GIT_SSH_COMMAND=\"${GIT_SSH_COMMAND:-ssh -oBatchMode=yes}\"",
    "PLUG=\"${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins\"",
    "list=$(omarchy plugin list --json 2>/dev/null) || list=\"[]\"",
    "catalog=$(curl -fsSL --proto '=https' --max-time 30 --max-filesize 16777216 \"https://plugins.omarchy.org/catalog.json\" 2>/dev/null) || catalog=\"\"",
    "[ -n \"$catalog\" ] || { printf '%s' '{\"ok\":false,\"error\":\"catalog-unreachable\"}'; exit 0; }",
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
    "    VER=$(jq -r '.version // \"\"' \"$M\" 2>/dev/null | tr -d '\\t\\r\\n')",
    "    NAME=$(jq -r '.name // \"\"' \"$M\" 2>/dev/null | tr -d '\\t\\r\\n')",
    "    rows+=$(printf '%s\\t%s\\t%s\\t%s' \"$ID\" \"$VER\" \"$NAME\" \"$REMOTE\")$'\\n'",
    "  fi",
    "done",
    "plugins=$(printf '%s' \"$catalog\" | jq -c --arg rows \"$rows\" '",
    "(.plugins // []) as $pl",
    "| [ $rows | split(\"\\n\")[] | select(length > 0) | split(\"\\t\")",
    "  | {id: .[0], installed: .[1], name: (if length > 2 then .[2] else \"\" end), remote: (if length > 3 then .[3] else \"\" end) }",
    "] | map(. as $p",
    "  | ($pl | map(select(type == \"object\" and .id == $p.id)) | first) as $e",
    "  | ((if $e == null then \"\" else ($e.verificationCommit // \"\") end) | tostring) as $vc",
    "  | {id: $p.id, name: (if $p.name != \"\" then $p.name else $p.id end),",
    "    installed: ($p.installed | tostring),",
    "    latest: ((if $e == null then \"\" else ($e.version // \"\") end) | tostring),",
    "    remote: $p.remote,",
    "    verified: ((if $e == null then \"\" else ($e.verificationStatus // \"\") end) | tostring) == \"verified\"",
    "      and $vc != \"\" and $p.remote == $vc})",
    "' 2>/dev/null) || plugins=\"[]\"",
    "[ \"${plugins:0:1}\" = \"[\" ] || plugins=\"[]\"",
    "printf '%s' \"{\\\"ok\\\":true,\\\"plugins\\\":$plugins}\""
  ].join("\n")

  Process {
    id: updateCheckProc
    command: ["bash", "-c", root.checkScript]
    stdout: StdioCollector {
      id: updateCheckOut
      waitForEnd: true
    }
    onExited: function (exitCode) {
      if (exitCode === 0) {
        var res = null
        try { res = JSON.parse(String(updateCheckOut.text || "")) } catch (e) { res = null }
        root.applyCheckResult(res)
      } else if (root.updateChecking) {
        root.updateChecking = false
        root.updateCheckFailed = true
        root.publishSettingsSnapshot()
      }
    }
  }

  // Self-heal: a check script hanging (curl or git stalling past its timeout)
  // must not keep updateChecking permanently stuck true.
  Timer {
    interval: 45000
    running: root.updateChecking
    onTriggered: {
      if (root.updateChecking) {
        root.updateChecking = false
        root.updateCheckFailed = true
        if (updateCheckProc.running) updateCheckProc.signal(9)
        root.publishSettingsSnapshot()
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
      id: browserCheckOut
      waitForEnd: true
    }
    onExited: function (_code) {
      root.applyProbeOutput(String(browserCheckOut.text || ""))
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
      tabFile.reload()
      if (root.focusPending) focusFile.reload()
    }
  }

  // Backstop for a focus request nobody answers (all tabs just closed):
  // forget it so the next click behaves normally again. The host drops the
  // file itself as stale around the same time.
  Timer {
    id: focusTimer
    interval: root.focusRequestTimeoutMs
    onTriggered: root.clearFocusRequest()
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
      id: listProcOut
      waitForEnd: true
    }
    onExited: function (exitCode) {
      if (exitCode !== 0) {
        root.statusChecked = false
        return
      }
      var entry = null
      var parsed = false
      try {
        var plugins = JSON.parse(String(listProcOut.text || "[]"))
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
        root.isBarWidget = !!entry && Array.isArray(entry.kinds) && entry.kinds.indexOf("bar-widget") !== -1
        root.statusChecked = true
      }
    }
  }

  // Marketplace catalog, same fetch the wizard validates against; used here
  // for display only (preview thumbnail, description, author, version).
  Process {
    id: catalogProc
    command: ["curl", "-fsSL", "--proto", "=https", "--max-time", "15", "--", "https://plugins.omarchy.org/catalog.json"]
    stdout: StdioCollector {
      id: catalogProcOut
      waitForEnd: true
    }
    onExited: function (exitCode) {
      if (exitCode !== 0) {
        root.catalogEntry = null
        root.catalogLoading = false
        return
      }
      var entry = null
      try {
        var catalog = JSON.parse(String(catalogProcOut.text || "{}"))
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
      if (entry && ((entry.kind || "").indexOf("Bar widget") !== -1 || entry.category === "Bar widgets" || entry.category === "Widgets")) {
        root.isBarWidget = true
      }
      root.catalogLoading = false
    }
  }

  Process {
    id: moveProc
    stdout: StdioCollector {
      id: moveProcOut
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: moveProcErr
      waitForEnd: true
    }
    onExited: function (exitCode) {
      var name = root.watchedName()
      var out = (String(moveProcOut.text || "") + "\n" + String(moveProcErr.text || "")).trim()
      shellFile.reload() // reflect the new section in the move buttons
      if (exitCode === 0) {
        root.notify("Bar icon moved", name + "'s icon now sits in the " + root.sectionLabel(root.moveSection) + " section.")
      } else {
        root.notify("Bar icon move failed",
                    name + ": could not move icon to " + root.sectionLabel(root.moveSection)
                    + (out ? ": " + out : ""))
      }
    }
  }

  Process {
    id: enabledProc
    stdout: StdioCollector {
      id: enabledProcOut
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: enabledProcErr
      waitForEnd: true
    }
    onExited: function (exitCode) {
      var name = root.watchedName()
      var verb = String(enabledProc.command[2] || "")
      var out = (String(enabledProcOut.text || "") + "\n" + String(enabledProcErr.text || "")).trim()
      if (exitCode === 0) {
        root.notify("Plugin " + verb + "d", name + " " + verb + "d.")
      } else {
        root.notify("Plugin " + verb + " failed",
                    name + ": omarchy plugin " + verb + " exited with code " + exitCode
                    + (out ? ": " + out : ""))
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
    // The inherited default is the bar's urgent (red) role; this widget's
    // "lit up" state is an accent highlight, matching the accent update pill
    // and the panel's accent styling, so follow the theme accent.
    activeColor: Color.accent
    tooltipText: (root.beaconLive
      ? root.watchedName() + " \u00b7 open in browser"
      : "Browser Plugin Manager")
      + (root.eligibleCount > 0
        ? " \u00b7 " + root.eligibleCount + " plugin" + (root.eligibleCount === 1 ? " has" : "s have")
          + " updates (right-click)"
        : root.updateCount > 0
          ? " \u00b7 " + root.updateCount + " plugin" + (root.updateCount === 1 ? " has" : "s have")
            + " updates, all unverified (right-click)"
          : "")

    onPressed: function (code) {
      // Left: with a live marketplace tab, jump the browser to it (focus
      // the window, select the tab) and do NOT open the dropdown — except
      // when the tab the user is looking at already is a plugin page: the
      // plugin is on screen, so the click shows the plugin popup. Without
      // a live tab, the plugin popup. Right: the settings panel (mutually
      // exclusive, both route through the toggle helpers).
      if (code === Qt.LeftButton) {
        if (root.liveTabCount > 0 && !root.activePluginPage) {
          root.requestFocusTab()
          return
        }
        root.toggleLeft()
      } else if (code === Qt.RightButton) root.toggleSettings()
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
    property string tooltipText: ""
    property bool primary: false
    property bool danger: false
    property bool spin: false
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
      transformOrigin: Item.Center

      // NumberAnimation (GUI-thread timer driven) rather than
      // RotationAnimator: the shell's composited windows do not advance
      // render-thread animators, and this is the same mechanism the
      // thumbnail shimmer uses successfully. Loops 0->360 for as long as
      // the check runs (the button is disabled), so the icon keeps
      // turning full circles until the check completes.
      NumberAnimation on rotation {
        from: 0
        to: 360
        duration: 900
        loops: Animation.Infinite
        running: bwButton.spin
        // Stopping mid-loop leaves the last animated angle on the label;
        // reset so the icon sits upright again once the check finishes.
        onRunningChanged: if (!running) bwLabel.rotation = 0
      }
    }
    MouseArea {
      id: bwMouse
      anchors.fill: parent
      hoverEnabled: true
      // Stay enabled while the button is disabled so the tooltip (e.g.
      // "Checking for updates ...") still follows the pointer; the click
      // is gated on the button's own enabled state instead.
      cursorShape: bwButton.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: if (bwButton.enabled) bwButton.clickedBw()
    }
    PanelToolTip {
      visible: bwMouse.containsMouse && bwButton.tooltipText !== ""
      text: bwButton.tooltipText
    }
  }

  // Plain text on purpose: lines here carry remote marketplace metadata
  // (catalog blurb, author, versions, plugin names). AutoText would
  // interpret markup in it, so a remote <img src=...> tag would fetch
  // from the network while the panel is merely open.
  component BWLine: Text {
    width: popupColumn.width
    wrapMode: Text.Wrap
    textFormat: Text.PlainText
    color: Util.alpha(Color.foreground, 0.75)
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
  }

  // Hairline separator dividing the settings panel into groups; a muted
  // foreground alpha so it reads as a rule in any theme.
  component BWRule: Rectangle {
    width: settingsColumn.width
    height: 1
    color: Util.alpha(Color.foreground, 0.15)
  }

  // Icon-only square variant of BWButton, used by positioning rows and update-list rows.
  component BWIconButton: BorderSurface {
    id: bwIcon
    property string label: ""
    property string tooltipText: ""
    property bool primary: false
    property bool danger: false
    property bool active: false
    property int size: Style.space(30)
    signal clickedBw
    width: size
    height: size
    radius: Style.cornerRadius
    readonly property color tone: root.bar ? root.bar.urgent : Color.urgent
    color: active
      ? Util.alpha(Color.accent, 0.25)
      : (!enabled ? "transparent"
        : primary
          ? (bwIconMouse.containsMouse ? Util.alpha(Color.accent, 0.2) : Util.alpha(Color.accent, 0.12))
          : danger
            ? (bwIconMouse.containsMouse ? Util.alpha(tone, 0.2) : Util.alpha(tone, 0.12))
            : (bwIconMouse.containsMouse ? Util.alpha(Color.foreground, 0.12) : Util.alpha(Color.foreground, 0.05)))
    borderSpec: Border.flat(active ? Color.accent
      : (enabled
        ? (primary ? Color.accent : danger ? tone : Util.alpha(Color.foreground, 0.3))
        : Util.alpha(Color.foreground, 0.2)), 1)
    Text {
      anchors.centerIn: parent
      text: bwIcon.label
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Math.round(size * 0.5)
      color: bwIcon.active ? Color.accent
        : (bwIcon.enabled
          ? (bwIcon.primary ? Color.accent : bwIcon.danger ? bwIcon.tone : Color.foreground)
          : Util.alpha(Color.foreground, 0.35))
    }
    MouseArea {
      id: bwIconMouse
      anchors.fill: parent
      hoverEnabled: true
      enabled: bwIcon.enabled && !bwIcon.active
      cursorShape: (bwIcon.enabled && !bwIcon.active) ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: bwIcon.clickedBw()
    }
    PanelToolTip {
      visible: bwIconMouse.containsMouse && bwIcon.tooltipText !== ""
      text: bwIcon.tooltipText
    }
  }

  PopupCard {
    id: popup
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    padding: Style.space(24)
    contentWidth: popup.fittedContentWidth(Style.space(380))
    contentHeight: popup.fittedContentHeight(popupColumn.implicitHeight - Math.round(Style.space(24) * 0.2), Style.space(560))

    Column {
      id: popupColumn
      anchors.top: parent ? parent.top : undefined
      anchors.topMargin: -Math.round(Style.space(24) * 0.2)
      width: parent ? parent.width : 0
      spacing: Style.space(14)

      // Header block (the wizard/OmaGuake panel header pattern): extensions
      // glyph (accent Text, no background, no border) + plugin name +
      // version pill + muted status/id subtitle, with equal margins above
      // and below (20% less than the left margin) and a divider spanning
      // the full card width underneath.
      Item {
        id: bwHeaderBlock
        width: popupColumn.width
        implicitHeight: bwHeaderRow.implicitHeight + Math.round(Style.space(24) * 0.8)
        height: implicitHeight

      Row {
        id: bwHeaderRow
        width: parent.width
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
              textFormat: Text.PlainText
              text: root.popupLive ? root.watchedName() : "Browser Plugin Manager"
              font.family: Style.font.family
              font.pixelSize: Style.font.title
              font.bold: true
              color: Color.foreground
              anchors.verticalCenter: parent.verticalCenter
            }

            Rectangle {
              visible: root.popupLive && root.watchedVersion !== ""
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
                text: "v" + String(root.watchedVersion)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: true
                color: Color.accent
              }
            }
          }

          Text {
            textFormat: Text.PlainText
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

        // Divider spanning the full card width, under the header.
        Rectangle {
          anchors.bottom: parent.bottom
          x: -Style.space(24)
          width: popup.width
          height: 1
          color: Qt.rgba(Color.foreground.r, Color.foreground.g,
            Color.foreground.b, 0.18)
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

      // Divider spanning the full card width, above the bottom action buttons.
      Item {
        id: bwActionDivider
        width: popupColumn.width
        implicitHeight: 1
        height: implicitHeight

        Rectangle {
          x: -Style.space(24)
          width: popup.width
          height: 1
          color: Qt.rgba(Color.foreground.r, Color.foreground.g,
            Color.foreground.b, 0.18)
        }
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
        visible: root.popupLive && root.statusChecked && root.pluginInstalled && root.pluginEnabled && (root.isBarWidget || root.iconSection !== "")
        text: "Move this plugin's bar icon:"
        horizontalAlignment: Text.AlignHCenter
      }
      Row {
        visible: root.popupLive && root.statusChecked && root.pluginInstalled && root.pluginEnabled && (root.isBarWidget || root.iconSection !== "")
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.space(6)
        Repeater {
          model: root.barMoveSections
          delegate: BWIconButton {
            size: Style.space(48)
            label: root.sectionIcon(modelData)
            tooltipText: root.sectionLabel(modelData)
              + (root.iconSection === modelData ? " (active)" : "")
            active: root.iconSection === modelData
            onClickedBw: root.moveIcon(modelData)
          }
        }
      }
    }
  }

}
