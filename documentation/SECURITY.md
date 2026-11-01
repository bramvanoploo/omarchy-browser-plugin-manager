# Security model

1. **Browser**: the extension is scoped to `plugins.omarchy.org` only.
2. **Native host manifest** pins allowed origins/add-ons to the known
   extension IDs (Chrome family: path-derived unpacked, key-pinned packed,
   CWS item; Firefox: self-distribution + AMO listing) — no other extension
   can talk to it.
3. **Host** re-validates every action against a fresh live catalog fetch;
   forged payloads for manual-setup or compatibility-failed plugins are
   rejected.
4. **Wizard** is the consent gate: it re-validates the request (fresh
   catalog entry, repository manifest, live local plugin list), shows what
   will happen, and runs the official `omarchy plugin` CLI only after you
   confirm; the host rejects toggles for plugins not in the marketplace
   catalog.
5. Installs the repo's current HEAD, which may differ from the marketplace's
   verified snapshot — the wizard says so.
