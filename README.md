# Omarchy Browser Plugin Manager

One-click plugin installs from [plugins.omarchy.org](https://plugins.omarchy.org).

Clicking **Install** on a plugin page opens a wizard overlay on the desktop
that validates the request (live catalog entry + repository manifest), shows
what will be installed, and installs only after you confirm, via the official
`omarchy plugin add --enable` (clone + manifest validation, no code
execution): the plugin lands enabled immediately, bar widgets in their
manifest's default bar section.

Once a plugin is installed, the page swaps the Install button for
**Enable/Disable** and **Uninstall** buttons (state read live from the host,
never from the page). All four actions run through the wizard, which asks you
to confirm before anything runs. When an action finishes, the result is a
desktop notification: no completion dialog is shown.

On the catalog page (index.html), each card's "Copy install command" button
is kept and gains a single icon-only button directly to its left: a green
**Install** icon when the plugin is not installed, a red **Uninstall** icon
when it is (tooltips "Install directly"/"Uninstall directly", same icons,
tones, and actions as the plugin page). The no-action "Manual" badges are
never touched.

## Architecture

```
browser (extension)  ->  native messaging host  ->  shell IPC  ->  wizard overlay
                         validates vs catalog.json     omarchy plugin add/enable/
                         never installs                disable/remove; confirm
                                                       first, notify when done
```

- **`extension/`** — MV3 WebExtension for Chrome, Chromium, Brave (Firefox MV3
  compatible; the source manifest carries no Chrome-only `"key"` — Firefox
  flags unknown properties — `bin/package` injects it into the Chrome zip,
  pinning the packed/store ID `nbngempephjmagmlfbfdodboeimfoibp`).
  Content scripts match `plugins.omarchy.org/plugin.html?id=...`
  (`content.js`, button groups) and the catalog `index.html` (`catalog.js`,
  icon-only Install/Uninstall button beside each card's "Copy install command")
  and inject buttons **only when**:
  1. the marketplace's own rule passes for the plugin
     (`installAvailable && upstreamCheckStatus !== "failed" && installCommand`), and
  2. a ping to the local native messaging host succeeds.
  The button set then follows the host's live `status` report
  (`installed`/`enabled` from `omarchy plugin list --json`).
  Manual-setup pages (like `bramvanoploo.omaguake`) and machines without this
  plugin show no buttons — the site renders untouched.
- **`bin/omarchy-plugin-install-host`** — native messaging host. Message types:
  `ping`, `status` (local install state), `status_all` (batch report for the
  catalog page), `install`, `uninstall`, `enable`,
  `disable`. Each action is re-validated against a **fresh** `catalog.json`
  fetch (id, repo match) and live local state (`not-installed`,
  `already-enabled`, `already-disabled`, `already-installed`). It summons the
  wizard and never installs anything itself.
- **`bin/plugin-installer-setup`** — registers the native host manifest for
  Chrome, Chromium, Brave, and Firefox, and prints extension-loading steps.
- **`Wizard.qml` + `manifest.json`** — the Omarchy shell overlay plugin
  (`bramvanoploo.omarchy-browser-plugin-manager`). It re-fetches catalog + repo manifest (payload
  is never trusted for display), re-checks local state for destructive/toggle
  flows, refuses to uninstall itself, and drives
  install / enable / disable / remove via the official `omarchy plugin` CLI.

## Security model

1. **Browser** shows its own "open in app?" style gate when relevant; the
   extension is scoped to `plugins.omarchy.org` only.
2. **Native host manifest** pins the allowed origins to the extension IDs
   (Chrome family: the path-derived unpacked ID *and* the key-pinned stable
   ID) / add-on ID (Firefox) — no other extension can talk to it. Chrome also
   requires the host manifest's `description` field (the setup script sets it).
3. **Host** re-validates against the live catalog; forged payloads for
   manual-setup or compatibility-failed plugins are rejected.
4. **Wizard** is the consent gate: it re-validates the request (fresh catalog
   entry, repository manifest, live local plugin list), shows what will
   happen, and runs the official installer path
   (`omarchy plugin add/enable/disable/remove`) only after you confirm. When
   an action finishes the result is a desktop notification; no completion
   dialog is shown. The wizard refuses to uninstall itself, and the host
   rejects toggles for plugins that are not in the marketplace catalog.
5. Installs the repo's current HEAD, which may differ from the marketplace's
   verified snapshot — the wizard says so.

## Install (developer machine)

```bash
# 1. Shell plugin (the wizard) — from your clone of this repo:
git init . && git add -A && git commit -m "init"   # if not already a repo
omarchy plugin add file://$PWD --yes
omarchy plugin enable bramvanoploo.omarchy-browser-plugin-manager

# 2. Browser integration (registers the native messaging host):
bin/plugin-installer-setup
# then load the extension as printed by the setup script:
#   Chrome/Chromium/Brave: chrome://extensions -> Developer mode -> Load unpacked -> extension/
#   Firefox: about:debugging#/runtime/this-firefox -> Load Temporary Add-on -> extension/manifest.json
```

The Chrome zip's `"key"` (injected by `bin/package`, absent from the source
manifest) pins the Chrome Web Store / packed-install extension ID
(`nbngempephjmagmlfbfdodboeimfoibp`); "Load unpacked" uses the path-derived
ID. The private key lives in `chrome-key.pem`
(gitignored, mode 600) — back it up: losing it means losing that ID. The
setup script registers both IDs (deriving the key ID from the pem when the
manifest has no key).
(The 2026-10-27 identity rename rotated this key; the superseded keypair is
kept as `chrome-key-2026-10-27.pem.bak`, its ID
`ojmmnnlphgmhjlmcfmanmnfialliaehj` is unused.)

Verify without a browser:

```bash
printf '\x10\x00\x00\x00{"type":"ping"}' | bin/omarchy-plugin-install-host | tail -c +5; echo
# expect: {"ok":true,"host":"bramvanoploo_omarchy_browser_plugin_manager","version":"0.2.1"}
# (host version tracks releases; bump with each signed extension release)
```

## Uninstall

```bash
bin/plugin-installer-setup --uninstall
omarchy plugin disable bramvanoploo.omarchy-browser-plugin-manager
omarchy plugin remove bramvanoploo.omarchy-browser-plugin-manager --yes
```

## Roadmap

- Chrome Web Store listing (stable extension ID) + AMO-signed Firefox add-on,
  replacing load-unpacked/temporary installs.
- Bar-icon watcher mode: the icon lights up when a tab opens on an
  installable plugin page (reuses the same host).
- "Install verified snapshot exactly" mode using `listingValidatedCommit`.
