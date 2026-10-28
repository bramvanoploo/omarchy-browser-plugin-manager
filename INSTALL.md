# Install without the browser stores

This archive contains everything needed to run the Omarchy Browser Plugin Manager
without installing the browser extension from the Chrome Web Store or AMO
(the stores carry identical code, see the README's browser table).

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

The shell plugin also registers the host by itself on every shell start,
pinned to this directory's `extension/` — if you add the shell plugin from
this same unpacked directory (`omarchy plugin add file://$PWD --enable`),
registration happens automatically and this step is redundant.

## 2. Load the browser extension

**Chrome / Chromium / Brave**

1. Open `chrome://extensions` (`brave://extensions` for Brave)
2. Enable **Developer mode** (top right)
3. **Load unpacked** -> select the `extension/` directory from this archive

Load unpacked gets the path-derived ID. The store artifact
`omarchy-browser-plugin-manager-<version>-chrome.zip` (built by `bin/package`) is
the Chrome Web Store upload format (the CWS dashboard rejects a `"key"`
field, so the store assigns its own ID: `nalcgjmbglkcmohokidcmogcbpmhkdjf`).
Zipped packed installs get the key-pinned ID
`nbngempephjmagmlfbfdodboeimfoibp`, derived from `chrome-key.pem`. The
setup script registers all three IDs, so native messaging works for any of
them. Keep `chrome-key.pem` safe — without it the packed-install ID cannot
be reproduced.

**Firefox (release builds, >= 121): signed `.xpi` required**

Easiest: install the add-on from the AMO listing
([addons.mozilla.org](https://addons.mozilla.org/nl/firefox/addon/omarchy-browser-plugin-manager/));
its listed ID `omarchy-browser-plugin-manager@sudo-systems.com` is registered
by the setup script alongside the self-distribution ID below.

Without the listing, release Firefox permanently installs only AMO-signed add-ons, and the
native-messaging allowlist matches the stable add-on ID
`bramvanoploo.omarchy-browser-plugin-manager@bram.dev` — which only a permanent install gives:

1. Obtain `omarchy-browser-plugin-manager-<version>-signed.xpi` — the maintainer signs it
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
ls ~/.config/google-chrome/NativeMessagingHosts/bramvanoploo_omarchy_browser_plugin_manager.json \
   ~/.config/mozilla/native-messaging-hosts/bramvanoploo_omarchy_browser_plugin_manager.json
```

Both host manifests must exist (the setup script writes one per browser
family). A terminal ping of `./bin/omarchy-plugin-install-host` answers
nothing by design: the host authenticates its caller, and a terminal run
feeds it no browser origin, so it exits silently. The extension pings it on
every plugin page; the Install button appearing is the live proof.

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
`omarchy plugin remove bramvanoploo.omarchy-browser-plugin-manager`.
Removing the shell plugin while the shell runs also triggers the wizard's
self-cleanup, which unregisters the host a few seconds later; the command
above is the deterministic way, and works even with the shell stopped.
