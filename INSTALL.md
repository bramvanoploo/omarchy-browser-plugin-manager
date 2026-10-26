# Install without the browser stores

This archive contains everything needed to run the Omarchy Plugin Installer
without publishing to the Chrome Web Store or AMO.

Unpack this archive wherever you want to keep it, e.g. `~/apps/`. All paths
below are relative to the unpacked directory.

## 1. Register the native messaging host

```sh
./bin/plugin-installer-setup --extension-dir ./extension
```

The setup script registers the host with Chrome, Chromium, Brave, and Firefox
and prints the exact extension ID derived from *your* unpack location. You
must load the browser extension from exactly that `--extension-dir` path,
otherwise the native host will reject its connection.

## 2. Load the browser extension

**Chrome / Chromium / Brave**

1. Open `chrome://extensions` (`brave://extensions` for Brave)
2. Enable **Developer mode** (top right)
3. **Load unpacked** -> select the `extension/` directory from this archive

**Firefox (release builds, >= 121)**

1. Open `about:debugging#/runtime/this-firefox`
2. **Load Temporary Add-on** -> select `extension/manifest.json`
3. Note: temporary add-ons reset at every Firefox restart; re-add them after
   restarts (or use `*.xpi` below on a Firefox flavor that allows unsigned
   add-ons).

**Firefox ESR / Developer Edition / Nightly**

These builds allow unsigned add-ons. Install `*.xpi` from this archive via
`about:addons` -> gear icon -> **Install Add-on From File...**, with
`xpinstall.signatures.required` set to `false` in `about:config` if needed.

## 3. Verify

```sh
printf '\x10\x00\x00\x00{"type":"ping"}' | ./bin/omarchy-plugin-install-host | tail -c +5 ; echo
```

Expected: `{"ok":true}`

## 4. Use it

Open a one-click-installable plugin page on
[plugins.omarchy.org](https://plugins.omarchy.org) — an **Install** button
appears below the install command (Enable/Disable/Uninstall once the plugin
is installed). Clicking it opens the Omarchy shell wizard, which performs the
actual `omarchy plugin add/enable/disable/remove` after you confirm.

## Uninstall

```sh
./bin/plugin-installer-setup --uninstall
```

Then remove the extension from the browser (chrome://extensions /
about:addons), and remove the shell plugin with
`omarchy plugin remove dev.bram.plugin-installer`.
