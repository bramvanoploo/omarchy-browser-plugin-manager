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

The manifest pins a stable extension ID (`ojmmnnlphgmhjlmcfmanmnfialliaehj`)
via its `"key"` field, so zipped installs (and a future Chrome Web Store
listing — upload `plugin-installer-<version>-chrome.zip`) keep the same ID;
the setup script registers both this ID and the path-derived unpacked ID, so
native messaging works for either. Keep `chrome-key.pem` safe — without it
the ID cannot be reproduced.

**Firefox (release builds, >= 121): signed `.xpi` required**

Release Firefox permanently installs only AMO-signed add-ons, and the
native-messaging allowlist matches the stable add-on ID
`plugin-installer@bram.dev` — which only a permanent install gives:

1. Obtain `plugin-installer-<version>-signed.xpi` — the maintainer signs it
   with AMO *unlisted* signing (`bin/sign`; a free AMO developer account, no
   store listing), or sign it yourself the same way.
2. `about:addons` -> gear icon -> **Install Add-on From File...** -> the
   signed `.xpi`.

Installing the *unsigned* `*.xpi` fails with *"the file appears to be
corrupt"* — Firefox's generic signature-rejection message, not a broken file.

**Do not use "Load Temporary Add-on" (about:debugging):** temporary installs
are allowlisted by a random Internal UUID that is re-generated on every
load, and Firefox reads native-messaging host manifests only at startup —
so the allowlist can never catch up and the Install button never appears.

**Firefox ESR / Developer Edition / Nightly: unsigned `.xpi`**

These builds allow unsigned add-ons. Install `*.xpi` from this archive via
`about:addons` -> gear icon -> **Install Add-on From File...**, with
`xpinstall.signatures.required` set to `false` in `about:config` if needed.
Permanent installs use the stable add-on ID, so native messaging works.

## 3. Verify

```sh
printf '\x10\x00\x00\x00{"type":"ping"}' | ./bin/omarchy-plugin-install-host | tail -c +5 ; echo
```

Expected: `{"ok":true}`

## 4. Use it

Open a one-click-installable plugin page on
[plugins.omarchy.org](https://plugins.omarchy.org) — an **Install** button
appears below the install command (Enable/Disable/Uninstall once the plugin
is installed). Clicking it opens the Omarchy shell wizard, which validates the
request, asks you to confirm, and then runs the actual
`omarchy plugin add/enable/disable/remove`. The outcome is a desktop
notification.

## Uninstall

```sh
./bin/plugin-installer-setup --uninstall
```

Then remove the extension from the browser (chrome://extensions /
about:addons), and remove the shell plugin with
`omarchy plugin remove dev.bram.plugin-installer`.
