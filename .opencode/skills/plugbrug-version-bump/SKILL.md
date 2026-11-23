---
name: PlugBrug version bump
description: Keep every PlugBrug version location in sync and refresh preview.png. Use whenever the version in manifest.json or browser/extension/manifest.json is about to change or just changed, or when a version bump is requested.
---

## Hard rule

Never bump a version on your own initiative — that covers BOTH the shell
plugin (`manifest.json`) and the browser extension
(`browser/extension/manifest.json`). Change a version ONLY when the
developer explicitly requests a version bump in the current session.
Never tag, release, or publish a version that was not explicitly asked for.

## Version locations — all of these move together

| File | What |
| --- | --- |
| `manifest.json` | `.version` (shell plugin) |
| `browser/extension/manifest.json` | `.version` (must equal the root one) |
| `bin/omarchy-plugin-install-host` | the two hardcoded `HOST_VERSION="<old>"` fallbacks |
| `test/workers-regression.sh` | the "tampered manifest: version falls back" expected value |

`browser/store/bin/package` hard-fails when the two manifests disagree — it
no longer rewrites source.

## After any bump

1. `./preview/generate-preview.sh` — the banner's version pill is filled from
   `manifest.json`; it rewrites `preview.png`.
2. Run every suite; `workers-regression.sh` expects the NEW fallback string:
   `test/host-state-privacy.sh`, `test/plugin-installer-registration.sh`,
   `test/update-apply.sh`, `test/update-detection.sh`,
   `test/workers-regression.sh`, `test/host-action-validation.sh`,
   `test/extension-guards.sh`.
3. Commit the bump together with the regenerated `preview.png` in one commit
   (message convention: `chore(release): bump plugin and extension to X.Y.Z`).

A regenerated `preview.png` that is content-identical to the committed one
(PNG encoder noise) can be discarded with `git checkout -- preview.png`.
