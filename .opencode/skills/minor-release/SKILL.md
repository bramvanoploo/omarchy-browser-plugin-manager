---
name: Minor Release
description: Create and ship a new MINOR release of omarchy-browser-plugin-manager on GitHub — bump the minor version across shell plugin, extension, native host, and docs, build the extension packages (xpi, chrome zip, signed xpi, source zip), commit, push, tag, and publish a GitHub release with the packages as assets. Use for "create a new minor release", "bump the minor version and release", "ship a minor", "new minor version". Never use for patch/major bumps.
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

1. **Version sync** — set the new version in all of:
   - `manifest.json` (shell plugin, `.version`)
   - `extension/manifest.json` (browser extension, `.version`)
   - `bin/omarchy-plugin-install-host` (`HOST_VERSION="..."`)
   - `README.md` (the ping `# expect:` example line, `"version":"X.Y.Z"`)
   Verify: `grep -rn "<old-version>" manifest.json extension/manifest.json bin/ README.md`
   must return nothing, and
   `printf '\x0f\x00\x00\x00{"type":"ping"}' | bin/omarchy-plugin-install-host | tail -c +5`
   must answer with the new version (the frame length must be exactly 15 bytes).

2. **Build packages** (all outputs land in `dist/`, which is gitignored):
   - `./bin/package` → `dist/<slug>-X.Y.Z.xpi`, `dist/<slug>-X.Y.Z-chrome.zip`,
     `dist/<slug>-X.Y.Z-<YYYYMMDD>.zip` (`<slug>` = kebab manifest name,
     currently `omarchy-browser-plugin-manager`).
   - If `.env` exists in the repo root (AMO API keys): `set -a && source .env && set +a && ./bin/sign`
     → `dist/signed/<slug>-X.Y.Z-signed.xpi`. Never read, print, or commit `.env`.
     If `.env` is absent, skip the signed build and omit it from the release notes.

3. **Commit** — the version-sync edits as one commit:
   `git add manifest.json extension/manifest.json bin/omarchy-plugin-install-host README.md`
   (drop `bin/omarchy-plugin-install-host` from this list if its version line
   already went in with an earlier feature commit) then
   `git commit -m "Release X.Y.Z: version aligned in shell plugin, extension, and docs"`.
   Commit style: one-line subject, no conventional-commit prefix; bodies allowed.

4. **Push, tag, release**:
   - `git push origin main`
   - `git tag -a vX.Y.Z -m "Omarchy Browser Plugin Manager X.Y.Z" && git push origin vX.Y.Z`
   - `gh release create vX.Y.Z --title "Omarchy Browser Plugin Manager X.Y.Z" --notes-file <notes> <assets...>`
     Assets (exact files from step 2):
     - `dist/<slug>-X.Y.Z-chrome.zip`
     - `dist/<slug>-X.Y.Z.xpi`
     - `dist/signed/<slug>-X.Y.Z-signed.xpi` (only if built)
     - `dist/<slug>-X.Y.Z-<YYYYMMDD>.zip`

5. **Release notes** — mirror the existing releases' shape
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
