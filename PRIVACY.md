# Privacy Policy — Omarchy Browser Plugin Manager

Last updated: 2026-10-28

## Data collection

The Omarchy Browser Plugin Manager browser extension collects, stores, and
transmits **no user data**. It contains no analytics, no telemetry, no
tracking code, and no remote server of its own.

## How it works

- The extension runs only on `plugins.omarchy.org` (the Omarchy plugin
  marketplace). On that site it reads the public plugin catalog and adds
  Install / Uninstall / Enable / Disable buttons to plugin cards.
- Plugin state (which plugins are installed and enabled) is read from a
  **local native messaging host** that the user installs manually
  (`omarchy-plugin-install-host`). Communication between the extension and
  this host happens entirely on the user's machine via stdin/stdout.
- Install, enable, disable, and uninstall actions are performed by the
  Omarchy shell plugin on the desktop, only after the user explicitly
  confirms in the desktop wizard.
- The extension never reads page content outside the plugin catalog, never
  modifies pages on other sites, and sends nothing to any server.

## Personal data

No personal data of any kind is collected, processed for the developer's
purposes, sold, rented, shared, or otherwise used. Nothing leaves the
user's machine through the extension.

## Contact

Bram van Oploo — https://github.com/bramvanoploo
