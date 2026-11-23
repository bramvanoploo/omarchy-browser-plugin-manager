---
name: PlugBrug publish browser extensions
description: Build, sign and submit fresh PlugBrug browser extension artifacts to AMO and the Chrome Web Store after the extension version was bumped. Use when the extension version changed and new builds must be generated, published, or attached to a GitHub release.
---

## Preconditions

- Hard rule: never bump a version yourself — neither for the shell plugin
  (`manifest.json`) nor for the browser extension
  (`browser/extension/manifest.json`). This flow runs only after the
  developer explicitly requested a bump and it was performed. If the
  versions did not change, there is nothing new to publish: stop and ask.
- Both manifests declare the SAME new version (the version-bump skill keeps
  them in sync; `package` refuses otherwise).
- Chrome and AMO reject a version they already received — never republish a
  version number.
- Credentials live OUTSIDE the repo in `~/.config/plugbrug/store.env`
  (mode 600): `AMO_API_KEY/AMO_API_SECRET`, `GOOGLE_CWS_*`. Load them with
  `set -a; source ~/.config/plugbrug/store.env; set +a` and never print or
  echo their values.

## Build (in repo root)

```sh
./browser/store/bin/package
```

Produces `dist/omarchy-plugbrug-<version>-{.xpi,-listed.xpi,-chrome.zip,-<date>.zip}`
(slug comes from the extension manifest name).

## Sign for release Firefox (AMO unlisted signing)

```sh
set -a; source ~/.config/plugbrug/store.env; set +a
./browser/store/bin/sign
```

Output: `dist/signed/omarchy-plugbrug-<version>-signed.xpi`.

## Submit to the stores

```sh
./browser/store/bin/publish-firefox   # AMO listed; skips if already current; auto-approval usually lands in minutes
./browser/store/bin/publish-chrome    # CWS Publish API v2: upload, then submit for review
```

Known failure: `publish-chrome` HTTP 400 `INVALID_ITEM_METADATA` means the
package UPLOAD succeeded but SUBMIT was refused — the listing metadata needs
the Developer Dashboard, the API cannot show what. Resolve it at the dashboard
edit page for item `nalcgjmbglkcmohokidcmogcbpmhkdjf`, then re-run the script.
Verify AMO afterwards:
`curl -fsS https://addons.mozilla.org/api/v5/addons/addon/omarchy-browser-plugin-manager/ | jq .current_version.version`.

## Attach to the GitHub release (pattern used since v0.8.0)

Four assets: source zip (`-<date>.zip`), `-chrome.zip`, `-signed.xpi`
(from `dist/signed/`), unsigned `.xpi`.

```sh
gh release create v<version> --title "Omarchy PlugBrug <version>" \
  --notes-file <body.md> <the four artifacts>
```
