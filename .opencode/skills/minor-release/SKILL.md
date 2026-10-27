---
name: Minor Release
description: Create and ship a new MINOR release of omarchy-browser-plugin-manager on GitHub — bump the minor version across shell plugin, extension, native host, and docs, review and harden the code changes, build the extension packages (xpi, chrome zip, signed xpi, source zip), commit, push, tag, and publish a GitHub release with the packages as assets. Use for "create a new minor release", "bump the minor version and release", "ship a minor", "new minor version". Never use for patch/major bumps.
---

# Minor Release

Cut the next minor release (x.Y+1.0, patch reset to 0) of this repository end-to-end. Work from
the repo root (the directory containing `manifest.json` and `bin/`).

## Ground rules

- Minor bumps only. If the user asks for patch/major, say this skill covers
  minor releases only and stop.
- Never amend, re-tag, or re-create an existing tag/version. If the computed
  tag already exists on the remote, stop and report.
- Read the current version from `manifest.json` (`.version`). New version =
  minor + 1 with the patch reset to 0, format `X.Y.Z`, tag `vX.Y.Z`.
- Run `git status --short` first. Uncommitted edits outside this release's
  scope (e.g. unrelated work-in-progress files) must be committed as their own
  logical commit(s) BEFORE the release commit, using messages describing those
  changes. The release commit contains only version-sync changes.

## Steps

1. **Review & harden the code changes** — do this before anything is committed
   or pushed. Read the full change set: `git log v<prev>..HEAD -p` and
   `git diff` (uncommitted). Review for the risks this repo actually has:
   - Detached bash workers (`Wizard.qml` `buildWorkerScript`) and `bin/*`:
     one command per script line (a value split across two lines becomes two
     commands), arguments passed through argv rather than interpolated,
     `set -u` respected, every exit path notifies, and no command runs with an
     empty option value (e.g. `enable --section ""` fails).
   - `Wizard.qml`: no leftover debug `console.log`, no unguarded shell/IPC
     calls, every action ends in a notification plus close, guards re-run
     through the shell's post-clone config sweep.
   - `bin/omarchy-plugin-install-host`: catalog + repo validation intact,
     request frames length-checked, and debug tracing stays opt-in (never
     default-on).
   - `extension/manifest.json`: permissions and extension ID unchanged; no
     secrets, tokens, `.env` content, or machine-specific paths shipped.
   Prove it with the smallest checks that cover the change: `qmllint` on
   `Wizard.qml` (no new warning classes beyond the file's existing
   unqualified-access/import-path noise), `bash -n` on each extracted worker
   script, the host ping frame, and a stubbed-`omarchy` run of the affected
   flow when install/enable/uninstall behavior changed.
   Classification: fixes that provably preserve behavior (quoting, lint,
   dead debug code, a command the shell rejects outright) may be applied
   directly and re-proved, each as its own commit. Any fix that changes
   behavior in a way that might break things — validation, the install/enable
   sequence, notifications, packaging, extension surface — MUST stop first:
   explain what needs to change and why, and its blast radius, ask for
   confirmation, and apply it only after the user confirms. Then re-run the
   checks and continue the release. If the user declines, stop and report;
   do not ship.

2. **Version sync** — set the new version in all of:
   - `manifest.json` (shell plugin, `.version`)
   - `extension/manifest.json` (browser extension, `.version`)
   - `bin/omarchy-plugin-install-host` (`HOST_VERSION="..."`)
   - `README.md` (the ping `# expect:` example line, `"version":"X.Y.Z"`)
   Verify: `grep -rn "<old-version>" manifest.json extension/manifest.json bin/ README.md`
   must return nothing, and
   `printf '\x0f\x00\x00\x00{"type":"ping"}' | bin/omarchy-plugin-install-host | tail -c +5`
   must answer with the new version (the frame length must be exactly 15 bytes).

3. **Build packages** (all outputs land in `dist/`, which is gitignored):
   - `./bin/package` → `dist/<slug>-X.Y.Z.xpi`, `dist/<slug>-X.Y.Z-chrome.zip`,
     `dist/<slug>-X.Y.Z-<YYYYMMDD>.zip` (`<slug>` = kebab manifest name,
     currently `omarchy-browser-plugin-manager`).
   - If `.env` exists in the repo root (AMO API keys): `set -a && source .env && set +a && ./bin/sign`
     → `dist/signed/<slug>-X.Y.Z-signed.xpi`. Never read, print, or commit `.env`.
     If `.env` is absent, skip the signed build and omit it from the release notes.

4. **Commit** — the version-sync edits as one commit:
   `git add manifest.json extension/manifest.json bin/omarchy-plugin-install-host README.md`
   (drop `bin/omarchy-plugin-install-host` from this list if its version line
   already went in with an earlier feature commit) then
   `git commit -m "Release X.Y.Z: version aligned in shell plugin, extension, and docs"`.
   Commit style: one-line subject, no conventional-commit prefix; bodies allowed.

5. **Push, tag, release**:
   - `git push origin main`
   - `git tag -a vX.Y.Z -m "Omarchy Browser Plugin Manager X.Y.Z" && git push origin vX.Y.Z`
   - `gh release create vX.Y.Z --title "vX.Y.Z" --notes-file <notes> <assets...>`
     Assets (exact files from step 3):
     - `dist/<slug>-X.Y.Z-chrome.zip`
     - `dist/<slug>-X.Y.Z.xpi`
     - `dist/signed/<slug>-X.Y.Z-signed.xpi` (only if built)
     - `dist/<slug>-X.Y.Z-<YYYYMMDD>.zip`

6. **Release notes** — mirror the existing releases' shape
   (`gh release view v<prev> --json body -q .body`): a `# <name> X.Y.Z` line,
   a `### Changes` list summarizing the commits since the previous tag
   (`git log v<prev>..HEAD --oneline`), then a `### Assets` list describing
   each package:
   - chrome.zip: Chrome/Chromium/Brave build with pinned stable extension ID
   - .xpi: Firefox add-on (unsigned; ESR/Dev Edition/Nightly)
   - signed.xpi: AMO unlisted-signed Firefox add-on; add-on ID
     `bramvanoploo.omarchy-browser-plugin-manager@bram.dev`
   - source zip: full source + native host setup (see INSTALL.md)
   Close with `Install steps: see INSTALL.md.`

## Verify before reporting done

- `gh release view vX.Y.Z --json assets -q '.assets[].name'` lists every asset.
- `git status --short` is clean and `git log --oneline -1` is the release commit.
- Report the release URL from `gh release create` output.
