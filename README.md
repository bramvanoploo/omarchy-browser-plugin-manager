# Omarchy Plugin Installer

One-click plugin installs from [plugins.omarchy.org](https://plugins.omarchy.org).

Clicking **Install with Omarchy** on a plugin page opens a wizard overlay on the
desktop. The wizard shows the plugin's marketplace verification state, installs
via the official `omarchy plugin add` (clone + manifest validation, no code
execution), and — for bar widgets — lets you pick the bar section (left /
center / right) before enabling. Non-bar plugins finish in one step.

## Architecture

```
browser (extension)  ->  native messaging host  ->  shell IPC  ->  wizard overlay
                         validates vs catalog.json     omarchy plugin add/enable
                         never installs                user confirms, then installs
```

- **`extension/`** — MV3 WebExtension for Chrome, Chromium, Brave (Firefox MV3
  compatible). Content script matches `plugins.omarchy.org/plugin.html?id=...`
  and injects the Install button **only when**:
  1. the marketplace's own rule passes for the plugin
     (`installAvailable && upstreamCheckStatus !== "failed" && installCommand`), and
  2. a ping to the local native messaging host succeeds.
  Manual-setup pages (like `bramvanoploo.omaguake`) and machines without this
  plugin show no button — the site renders untouched.
- **`bin/omarchy-plugin-install-host`** — native messaging host. Validates the
  request against a **fresh** `catalog.json` fetch (id, repo match, one-click
  availability) and summons the wizard. It never installs anything.
- **`bin/plugin-installer-setup`** — registers the native host manifest for
  Chrome, Chromium, Brave, and Firefox, and prints extension-loading steps.
- **`Wizard.qml` + `manifest.json`** — the Omarchy shell overlay plugin
  (`dev.bram.plugin-installer`). It re-fetches catalog + repo manifest (payload
  is never trusted for display) and drives the install/enable flow.

## Security model

1. **Browser** shows its own "open in app?" style gate when relevant; the
   extension is scoped to `plugins.omarchy.org` only.
2. **Native host manifest** pins the allowed origin to the extension ID
   (Chrome family) / add-on ID (Firefox) — no other extension can talk to it.
3. **Host** re-validates against the live catalog; forged payloads for
   manual-setup or compatibility-failed plugins are rejected.
4. **Wizard** is the only consent gate. It installs disabled-first
   (`omarchy plugin add` without `--enable`), shows what will be installed,
   and runs the official installer path. Enablement is a user click.
5. Installs the repo's current HEAD, which may differ from the marketplace's
   verified snapshot — the wizard says so.

## Install (developer machine)

```bash
# 1. Shell plugin (the wizard) — from your clone of this repo:
git init . && git add -A && git commit -m "init"   # if not already a repo
omarchy plugin add file://$PWD --yes
omarchy plugin enable dev.bram.plugin-installer

# 2. Browser integration (registers the native messaging host):
bin/plugin-installer-setup
# then load the extension as printed by the setup script:
#   Chrome/Chromium/Brave: chrome://extensions -> Developer mode -> Load unpacked -> extension/
#   Firefox: about:debugging#/runtime/this-firefox -> Load Temporary Add-on -> extension/manifest.json
```

Verify without a browser:

```bash
printf '\x10\x00\x00\x00{"type":"ping"}' | bin/omarchy-plugin-install-host | tail -c +5; echo
# expect: {"ok":true,"host":"dev.bram.plugininstall","version":"0.1.0"}
```

## Uninstall

```bash
bin/plugin-installer-setup --uninstall
omarchy plugin disable dev.bram.plugin-installer
omarchy plugin remove dev.bram.plugin-installer --yes
```

## Roadmap

- Chrome Web Store listing (stable extension ID) + AMO-signed Firefox add-on,
  replacing load-unpacked/temporary installs.
- Bar-icon watcher mode: the icon lights up when a tab opens on an
  installable plugin page (reuses the same host).
- "Install verified snapshot exactly" mode using `listingValidatedCommit`.
