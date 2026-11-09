# Omarchy PlugBrug

One-click plugin installs from [plugins.omarchy.org](https://plugins.omarchy.org),
with the browser extension available in both stores: the
[Chrome Web Store](https://chromewebstore.google.com/detail/nalcgjmbglkcmohokidcmogcbpmhkdjf)
for Chromium-based browsers and
[Firefox Add-ons (AMO)](https://addons.mozilla.org/en-US/firefox/addon/omarchy-browser-plugin-manager/)
for Firefox-based ones.

![Omarchy PlugBrug](preview.png)

**Bar-icon watcher**: the Omarchy bar icon lights up while a plugin page is
the active tab. Left click opens a dropdown to **Install**, **Update**,
**Uninstall**, and move the icon; right click opens settings (update polling,
bulk update, verified-only toggle) and the icon shows an update counter.

## Installation

1. Add the Omarchy shell plugin (wizard + native messaging host):

```bash
omarchy plugin add https://github.com/bramvanoploo/omarchy-browser-plugin-manager --enable
```

2. Install the browser extension from the table in **Browser extensions**
   below — the wizard's one-time prompt right after step 1 links the right
   page. No manual host setup is needed. For installing without the browser
   stores, see [documentation/INSTALL.md](documentation/INSTALL.md).

## Uninstall

The wizard path (the browser's Uninstall button, or "Uninstall Omarchy
plugin" in the extension prompt) unregisters the native messaging host and
removes the plugin in one confirmed action.

Terminal removal works too:

```bash
omarchy plugin remove bramvanoploo.omarchy-browser-plugin-manager
```

After removing the plugin, also remove the browser extension
(chrome://extensions / about:addons).

## Browser extensions

| Browser | Extension |
| --- | --- |
| Firefox-based (Firefox incl. ESR, Waterfox, LibreWolf, Tor Browser, GNU IceCat, Zen) | [Firefox Add-ons (AMO)](https://addons.mozilla.org/en-US/firefox/addon/omarchy-browser-plugin-manager/) |
| Chromium-based (Chrome, Chromium, Brave, Edge, Vivaldi, Opera) | [Chrome Web Store](https://chromewebstore.google.com/detail/nalcgjmbglkcmohokidcmogcbpmhkdjf) |

Prefer not to use the stores? Every [GitHub release](https://github.com/bramvanoploo/omarchy-browser-plugin-manager/releases/latest) ships the extension packages for direct download — the AMO-signed Firefox `.xpi`, the Chrome-family build, and the full source archive; see [documentation/INSTALL.md](documentation/INSTALL.md).

The Omarchy plugin registers the native messaging host itself (every shell
start, idempotently); the browser extension alone is not enough.

## Architecture

See [documentation/ARCHITECTURE.md](documentation/ARCHITECTURE.md) for the
component overview (extension, native messaging host, setup script, wizard
overlay, bar watcher) and the full behavior spec.

## Security model

See [documentation/SECURITY.md](documentation/SECURITY.md) for the layered
validation: extension scoping, native host manifest origin pinning, fresh
catalog re-validation, and the wizard's consent gate.

## Roadmap

See [documentation/ROADMAP.md](documentation/ROADMAP.md) for what is planned
and already shipped.
