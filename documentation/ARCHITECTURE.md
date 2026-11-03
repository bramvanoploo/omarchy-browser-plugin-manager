# Architecture

## Behavior

Clicking **Install** on a plugin page opens a wizard overlay on the desktop:
it re-validates the request (live catalog entry + repository manifest), shows
what will be installed, and for bar widgets first asks which bar section the
icon goes in — a horizontal grid over the shell's live section list (left,
center begin, center, center end, right, tray), with the manifest's default
marked "(default)" (a manifest "center" maps to center end, exactly like
`omarchy plugin add` does). Nothing is installed before that choice, so
Cancel is a plain close. It installs only after you confirm, via the official
`omarchy plugin add` + `omarchy plugin enable --section` (clone + manifest
validation, no code execution), then verifies the result (enabled flag + bar
layout entry), re-applying the section if the shell's post-install config
sweep reverts it.

Actions run in a detached worker process; while one runs, the wizard shows a
running card (animated globe) that stays up until the worker exits — the
worker publishes a marker file that the panel polls, so the card survives a
shell reload (the manager's own install/update included). Confirmation cards
never show the globe. Escape closes any card; the primary action is always
the rightmost button.

Once a plugin is installed, the page swaps Install for **Enable/Disable** and
**Uninstall** buttons (state read live from the host, never from the page).
Every action ends in a desktop notification — no completion dialog. On the
catalog page, each card gains an icon-only Install/Uninstall button beside
its "Copy install command" button; "Manual" badges are never touched.

**Bar-icon watcher mode**: while a plugin page is the active tab of a
*focused* browser window, the extension renews a beacon with the local host
every 5s and the Omarchy bar icon lights up (accent tone); switching to
another plugin tab sends "unwatch" (id-scoped) and the icon and panel follow
right away, while switching to another application stamps the record
"paused" so the placeholder returns on the widget's next poll (≤2s);
focusing the browser again lights the icon immediately. Pages for plugins
that are *not* installable from the browser (no install command, built-in,
failed upstream check) light the icon too when the plugin is installed on
this machine, so its panel (update/uninstall/move icon) is reachable; no
page buttons appear there. Left click opens a dropdown with that plugin's
header (the wizard panel's header pattern: glyph, name, version pill, status
line) and buttons to **Install**, **Update**, **Uninstall**, and move its
bar icon: the move row is a grid over the shell's live bar-section list —
the same options as the wizard's placement step — with the section the icon
currently sits in marked "(active)". Install, Update, and Uninstall summon
the same wizard — the beacon is a display hint, the wizard re-validates and
asks for confirmation; moving the icon is plain layout config, so it runs
`omarchy bar move` directly.

Right click opens the settings wizard panel (the same system-panel card as
the install wizard: fixed header/footer, content-fit height, Escape closes):
a plugin-update poll every **10m / 30m / 1h / 5h / Daily** with a refresh
button to check
immediately, an **Update N plugins now** button (shown only while updates
are available), a toggle to also update plugins to their *unverified*
latest versions (default: latest verified only), and links to the Chrome
Web Store and Firefox Add-ons pages: the supported browsers are listed with
the installed ones highlighted, and each button names the browser it opens
the page in (the first installed browser of that family). The poll compares
every installed user plugin's version against the marketplace catalog;
while plugins have updates, the bar icon shows a counter in its top-right
corner (accent when the updates are updatable, muted when held back by the
verified-only setting; hidden at 0), and a poll that finds new updates sends
a notification offering them. Settings persist to `settings.json` in the
plugin's state directory.
Each updatable-plugin row carries two compact icon buttons: an
**uninstall** (trash) button, tooltip "Uninstall", left of the **update**
(level-up) button. Both arm the confirmation card over the panel before
anything runs: uninstall states exactly what `omarchy plugin remove --yes`
does (folder deleted — a symlinked dev folder is only unlinked, plugin
unloaded from the shell, bar icon dropped, reinstallable from the catalog)
and confirms with an urgent-toned button; the removal runs in the same
kind of detached worker as updates (id-validated, one rescan at the end,
summary notification, survives the shell reload when the manager itself
is removed).

**One-time extension prompt**: after this plugin is installed in Omarchy
(install only, not on later enables), the wizard shows a prompt that detects
the default browser (`xdg-settings get default-web-browser`, falling back to
the `x-scheme-handler/https` association), opens the matching browser
extension page (Firefox Add-ons / Chrome Web Store), and links the other
family's page. Cancelling shows a warning that the plugin is inert without
its browser extension, with buttons to open the extension page, cancel, or
uninstall the Omarchy plugin.

**Uninstall cleanup**: removing the plugin unloads the wizard, whose
detached self-cleanup unregisters the native messaging host a few seconds
later (best effort: it needs the shell running at removal time). If the
manifests survive anyway, run
`~/.config/omarchy/plugins/bramvanoploo.omarchy-browser-plugin-manager/bin/plugin-installer-setup --uninstall`
before removing — the script lives inside the plugin folder.

## Components

```
browser (extension)  ->  native messaging host  ->  shell IPC  ->  wizard overlay
                          validates vs catalog.json     omarchy plugin add/enable/
                          never installs                disable/remove/update;
                          watch beacon  ---------------->  bar widget (watcher)
                                                        confirm first, notify when done
```

- **`browser/extension/`** — MV3 WebExtension for Chrome, Chromium, Brave
  (Firefox-compatible MV3; the source manifest carries no Chrome-only
  `"key"` — Firefox flags it and the CWS dashboard rejects it). Buttons are
  injected on `plugin.html?id=...` (button groups) and the catalog
  `index.html` (icon-only button) only when the marketplace's own rule
  passes (`installAvailable && upstreamCheckStatus !== "failed" &&
  installCommand`) **and** a ping to the local host succeeds; the button set
  then follows the host's live `status` report (`omarchy plugin list
  --json`). Manual-setup pages and machines without this plugin show no
  buttons — the site renders untouched.
  While the plugin page is the visible tab, a `watch` beacon is renewed
  every 5s (`watch` with `"paused":true` on window blur, `unwatch` on
  leave).
- **`bin/omarchy-plugin-install-host`** — native messaging host: `ping`,
  `status`, `status_all` (batch for the catalog page), `install`,
  `uninstall`, `enable`, `disable`. Each action is re-validated against a
  **fresh** `catalog.json` fetch (id, repo match) and live local state
  (`not-installed`, `already-enabled`, `already-disabled`,
  `already-installed`). It summons the wizard and never installs anything.
  `watch` is format-checked only and records the page in
  `browser-watch.json` (state dir); a `"paused":true` watch stamps an
  existing same-id record paused, `unwatch` and host exit remove it.
- **`bin/plugin-installer-setup`** — registers the native host manifest for
  Chrome, Chromium, Brave, and Firefox; `--uninstall` unregisters. The
  shell plugin runs it automatically on every shell start (idempotent) and
  unregisters at uninstall.
- **`Wizard.qml` + `manifest.json`** — the shell overlay plugin
  (`bramvanoploo.omarchy-browser-plugin-manager`). Re-fetches catalog + repo
  manifest (the payload is never trusted for display), re-checks local
  state for destructive/toggle/update flows, and drives install / enable /
  disable / remove / update via the official `omarchy plugin` CLI; its own
  uninstall runs detached (unregistering the host first). The card fits its
  content height; the running stage polls the worker marker files under the
  state dir's `in-progress/` and closes when none is fresh, so the card
  reappears after a shell reload. The settings stage renders the panel
  content (toggles, update lists, poll interval, store links) and exchanges
  commands with the bar widget through the state dir's `settings-cmd.json`
  append-log: each command carries a sequence id the widget dedupes, and
  the panel echoes the widget's open-session id in its `closed` command so
  a stale file can never wedge the panel.
- **`BarWatch.qml`** — the bar widget: reads the beacon record, lights up
  while it is live (fresh ≤12s and not paused: a blurred browser dims the
  icon within its 2s poll, a killed browser clears itself via staleness),
  and offers the plugin’s manage dropdown. Install/Update/Uninstall route
  through the wizard with the beacon’s id/repo/name as hint only. It
  consumes the settings command log (deduped by sequence id) and owns the
  settings open-session token; the move-icon row and the wizard's placement
  step share the shell's live section list (`Util.barSections`).
