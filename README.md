# Omarchy Browser Plugin Manager

One-click plugin installs from [plugins.omarchy.org](https://plugins.omarchy.org).

> **Note:** The Firefox and Chromium browser extensions are currently under
> review and will be available soon from their respective official sources
> (Firefox Add-ons and the Chrome Web Store). Until then, both extensions can
> be downloaded from the assets section of the
> [latest release](https://github.com/bramvanoploo/omarchy-browser-plugin-manager/releases/latest)
> and installed manually — see [documentation/INSTALL.md](documentation/INSTALL.md).

![Omarchy Browser Plugin Manager](preview.png)

Clicking **Install** on a plugin page opens a desktop wizard: it re-validates
the request against the live catalog, asks what to do (bar section for
widgets), and only installs the official `omarchy plugin` CLI way after you
confirm. Once installed, the page swaps Install for **Enable/Disable** and
**Uninstall**; every action ends in a notification, not a dialog.

**Bar-icon watcher**: the Omarchy bar icon lights up while a plugin page is
the active tab. Left click opens a dropdown to **Install**, **Update**,
**Uninstall**, and move the icon; right click opens settings (update polling,
bulk update, verified-only toggle) and the icon shows an update counter.

## Browser extensions

| Browser | Extension |
| --- | --- |
| Firefox-based (Firefox incl. ESR, Waterfox, LibreWolf, Tor Browser, GNU IceCat, Zen) | [Firefox Add-on](https://addons.mozilla.org/nl/firefox/addon/omarchy-browser-plugin-manager/) |
| Chromium-based (Chrome, Chromium, Brave, Edge, Vivaldi, Opera) | [Chrome Web Store](https://chromewebstore.google.com/detail/nalcgjmbglkcmohokidcmogcbpmhkdjf) |

Prefer not to use the stores? Every [GitHub release](https://github.com/bramvanoploo/omarchy-browser-plugin-manager/releases/latest) ships the extension packages for direct download — the AMO-signed Firefox `.xpi`, the Chrome-family build, and the full source archive; see [documentation/INSTALL.md](documentation/INSTALL.md).

The Omarchy plugin registers the native messaging host itself (every shell
start, idempotently); the browser extension alone is not enough.

After installing this plugin in Omarchy, the wizard shows a one-time prompt
(install only, not on later enables): it detects the default browser
(`xdg-settings get default-web-browser`, falling back to the
`x-scheme-handler/https` association), opens the matching extension page
from the table above, and links the other family's page. Cancelling shows a
warning that the plugin is inert without its browser extension, with buttons
to open the extension page, cancel, or uninstall the Omarchy plugin.

## Architecture

See [documentation/ARCHITECTURE.md](documentation/ARCHITECTURE.md) for the
component overview (extension, native messaging host, setup script, wizard
overlay, bar watcher) and the full behavior spec.

## Installation

1. Add the Omarchy shell plugin (wizard + native messaging host):

```bash
omarchy plugin add https://github.com/bramvanoploo/omarchy-browser-plugin-manager --enable
```

2. Install the browser extension from the table above — the wizard's
   one-time prompt right after step 1 links the right page. No manual host
   setup is needed. For installing without the browser stores, see
   [documentation/INSTALL.md](documentation/INSTALL.md).

## Uninstall

The wizard path (the browser's Uninstall button, or "Uninstall Omarchy
plugin" in the extension prompt) unregisters the native messaging host and
removes the plugin in one confirmed action.

Terminal removal works too:

```bash
omarchy plugin remove bramvanoploo.omarchy-browser-plugin-manager
```

Removing the plugin unloads the wizard, whose detached self-cleanup
unregisters the host a few seconds later (best effort: it needs the shell
running at removal time). If the manifests survive anyway, run
`~/.config/omarchy/plugins/bramvanoploo.omarchy-browser-plugin-manager/bin/plugin-installer-setup --uninstall`
before removing — the script lives inside the plugin folder. Then remove the
browser extension (chrome://extensions / about:addons).

## Security model

See [documentation/SECURITY.md](documentation/SECURITY.md) for the layered
validation: extension scoping, native host manifest origin pinning, fresh
catalog re-validation, and the wizard's consent gate.

## Roadmap

See [documentation/ROADMAP.md](documentation/ROADMAP.md) for what is planned
and already shipped.
