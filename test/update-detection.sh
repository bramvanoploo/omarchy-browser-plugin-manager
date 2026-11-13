#!/bin/bash
# Fixture harness for the shared detector bin/omarchy-plugin-update check
# (the single behind-set implementation behind the bar widget's poll, the
# extension's Update buttons via the host cache, and the wizard):
#   - omaplug's git-ancestry model: a plugin is behind only when its HEAD
#     is a strict ancestor of origin's freshly fetched tip; symlinks, dirty
#     trees, detached HEADs, diverged clones, and invalid id spellings never
#     appear in the result
#   - catalog decoration: latest version from the catalog, verified true
#     only when the fetched tip IS the catalog's verificationCommit (an
#     upstream that advanced past the reviewed commit demotes to unverified;
#     so does verificationStatus != "verified")
#   - a behind plugin missing from the catalog is still reported (unverified)
#   - catalog failure prints {"ok":false,"error":"catalog-unreachable"} so
#     callers keep their last-good view
#   - installedVersion/latestVersion alias keys ride along for the host's
#     update-cache.json schema
#
# Fake omarchy (plugin list) and curl (catalog) shims run off PATH; the git
# work is real, against throwaway origins under a sandbox HOME/XDG dirs.
#
# Usage: test/update-detection.sh   (exit 0 = all checks pass)
set -u

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
UPD="$REPO_ROOT/bin/omarchy-plugin-update"
[[ -f $UPD ]] || { echo "detector not found: $UPD"; exit 1; }

TESTHOME=$(mktemp -d)
trap 'rm -rf "$TESTHOME"' EXIT
export HOME="$TESTHOME"
export XDG_CONFIG_HOME="$TESTHOME/.config"
export GIT_AUTHOR_NAME=tester GIT_AUTHOR_EMAIL=t@example.com
export GIT_COMMITTER_NAME=tester GIT_COMMITTER_EMAIL=t@example.com
PLUG="$XDG_CONFIG_HOME/omarchy/plugins"
mkdir -p "$PLUG"

SHIMBIN="$TESTHOME/shim/bin"
mkdir -p "$SHIMBIN"
cat > "$SHIMBIN/omarchy" <<'EOF'
#!/bin/bash
case "$1 $2" in
  "plugin list") cat "${FIX_LIST:-[]}";;
  *) exit 0;;
esac
EOF
cat > "$SHIMBIN/curl" <<'EOF'
#!/bin/bash
[ -n "${FIX_CATALOG_FAIL:-}" ] && exit 22
cat "${FIX_CATALOG:?}"
EOF
chmod +x "$SHIMBIN/omarchy" "$SHIMBIN/curl"
export PATH="$SHIMBIN:$PATH"

FAILURES=0
check() { # check <label> <expected> <actual>
  if [[ "$2" == "$3" ]]; then
    echo "ok   $1"
  else
    echo "FAIL $1: expected [$2] got [$3]"
    FAILURES=$((FAILURES + 1))
  fi
}
gca() { git -c user.email=t@example.com -c user.name=tester "$@"; } # git commit args

# mk_plugin <id> <installed-version> -> echoes "A_sha B_sha"; the clone sits
# at A (manifest.json with the given version), origin advanced to B.
mk_plugin() {
  local id="$1" ver="$2"
  local d="$TESTHOME/origin-$id.git" w="$TESTHOME/work-$id"
  git init -q --bare -b main "$d"
  git init -q -b main "$w"
  printf '{"id":"%s","name":"%s","version":"%s"}' "$id" "${id%%.*} Name" "$ver" > "$w/manifest.json"
  git -C "$w" add manifest.json >/dev/null
  gca -C "$w" commit -q -m "base for $id"
  git -C "$w" remote add origin "$d"
  gca -C "$w" push -q origin main
  local a; a=$(git -C "$w" rev-parse HEAD)
  git clone -q "$d" "$PLUG/$id"
  git -C "$w" commit -q --allow-empty -m "advance $id"
  gca -C "$w" push -q origin main
  local b; b=$(git -C "$w" rev-parse HEAD)
  printf '%s %s' "$a" "$b"
}

# Fixtures: behind+verified, behind+catalog-lag, behind+pending,
# behind+missing-from-catalog, detached, dirty, symlinked, diverged.
read -r A_BEHIND B_BEHIND < <(mk_plugin behind.plugin 0.1.0)
read -r A_LAG B_LAG < <(mk_plugin lag.plugin 0.1.0)
read -r A_PENDING B_PENDING < <(mk_plugin pending.plugin 0.1.0)
read -r A_MISS B_MISS < <(mk_plugin missing.plugin 0.1.0)
read -r A_DET B_DET < <(mk_plugin detached.plugin 0.1.0)
git -C "$PLUG/detached.plugin" checkout -q --detach "$A_DET"
read -r A_DIRTY B_DIRTY < <(mk_plugin dirty.plugin 0.1.0)
echo "// local edits" >> "$PLUG/dirty.plugin/manifest.json"
read -r A_LINK B_LINK < <(mk_plugin linked.plugin 0.1.0)
mv "$PLUG/linked.plugin" "$TESTHOME/real-linked-plugin"
ln -s "$TESTHOME/real-linked-plugin" "$PLUG/linked.plugin"
read -r A_DIV B_DIV < <(mk_plugin diverged.plugin 0.1.0)
# origin force-moves to an unrelated root commit (rewritten history): the
# clone's HEAD is no longer an ancestor of the tip, so it is not "behind":
W="$TESTHOME/work-diverged.plugin"
U=$(git -C "$W" commit-tree "$(git -C "$W" rev-parse 'HEAD^{tree}')" -m "rewritten history")
git -C "$W" push -qf origin "$U:refs/heads/main"
git -C "$W" fetch -q origin main 2>/dev/null || true

FIX_LIST="$TESTHOME/list.json"
jq -n --arg a behind.plugin --arg b lag.plugin --arg c pending.plugin \
  --arg d missing.plugin --arg e detached.plugin --arg f dirty.plugin \
  --arg g linked.plugin --arg h diverged.plugin \
  '[{id:$a,name:"Behind",version:"0.1.0",firstParty:false},
    {id:$b,name:"Lag",version:"0.1.0",firstParty:false},
    {id:$c,name:"Pending",version:"0.1.0",firstParty:false},
    {id:$d,name:"Missing",version:"0.1.0",firstParty:false},
    {id:$e,name:"Detached",version:"0.1.0",firstParty:false},
    {id:$f,name:"Dirty",version:"0.1.0",firstParty:false},
    {id:$g,name:"Linked",version:"0.1.0",firstParty:false},
    {id:$h,name:"Diverged",version:"0.1.0",firstParty:false},
    {id:"First.Party",name:"Core",version:"1.0.0",firstParty:true},
    {id:"Bad.Id",name:"Bad",version:"1.0.0",firstParty:false}]' > "$FIX_LIST"
export FIX_LIST

FIX_CATALOG="$TESTHOME/catalog.json"
jq -n --arg v1 "$B_BEHIND" --arg v2 "$A_LAG" --arg v3 "$B_PENDING" \
  '{"plugins":[
    {id:"behind.plugin",name:"Behind Plugin",version:"0.2.0",description:"advance behind.plugin",
     sha:$v1,verificationStatus:"verified",verificationCommit:$v1},
    {id:"lag.plugin",name:"Lag Plugin",version:"0.2.0",description:"advance lag.plugin",
     sha:$v2,verificationStatus:"verified",verificationCommit:$v2},
    {id:"pending.plugin",name:"Pending Plugin",version:"0.2.0",description:"advance pending.plugin",
     sha:$v3,verificationStatus:"pending",verificationCommit:$v3},
    {id:"first.party",name:"Core",version:"9.9.9",sha:$v1,verificationStatus:"verified",verificationCommit:$v1}
  ]}' > "$FIX_CATALOG"
export FIX_CATALOG

res=$(bash "$UPD" check)
jq -e '.ok == true and (.plugins | type == "array")' <<<"$res" >/dev/null
check "ok:true envelope" "true" "$(jq -r '.ok' <<<"$res")"
check "behind set exactly the reportable four" "behind.plugin,lag.plugin,missing.plugin,pending.plugin" \
  "$(jq -r '[.plugins[].id] | sort | join(",")' <<<"$res")"

q() { jq -r --arg id "$1" '.plugins[] | select(.id==$id) | .'"$2" <<<"$res"; }
check "behind: verified"        "true"    "$(q behind.plugin verified)"
check "behind: remote = tip"    "$B_BEHIND" "$(q behind.plugin remote)"
check "behind: installed"       "0.1.0"   "$(q behind.plugin installed)"
check "behind: latest from catalog" "0.2.0" "$(q behind.plugin latest)"
check "behind: name from manifest"  "behind Name" "$(q behind.plugin name)"
check "behind: installedVersion alias" "0.1.0" "$(q behind.plugin installedVersion)"
check "behind: latestVersion alias"    "0.2.0" "$(q behind.plugin latestVersion)"
check "lag (catalog vc != fetched tip): unverified" "false" "$(q lag.plugin verified)"
check "lag: remote still reported"  "$B_LAG" "$(q lag.plugin remote)"
check "pending verificationStatus: unverified" "false" "$(q pending.plugin verified)"
check "missing from catalog: listed" "true" "$(jq -e --arg id missing.plugin '[.plugins[].id] | index($id) != null' <<<"$res")"
check "missing from catalog: unverified" "false" "$(q missing.plugin verified)"
check "missing from catalog: latest empty" "" "$(q missing.plugin latest)"
check "missing from catalog: remote kept" "$B_MISS" "$(q missing.plugin remote)"

# Catalog unreachable: ok:false envelope, exit 0 (callers keep last good):
FIX_CATALOG_FAIL=1 res2=$(FIX_CATALOG_FAIL=1 bash "$UPD" check); rc=$?
check "catalog failure exit 0" "0" "$rc"
check "catalog failure ok:false" "false" "$(jq -r '.ok' <<<"$res2")"
check "catalog failure error tag" "catalog-unreachable" "$(jq -r '.error' <<<"$res2")"

# Garbage plugin list degrades to an empty behind set, not a crash:
FIX_LIST='not json' res3=$(FIX_LIST='not json' bash "$UPD" check); rc=$?
check "garbage list still ok:true" "0" "$rc"
check "garbage list -> no plugins" "[]" "$(jq -c '.plugins' <<<"$res3")"

# Non-JSON HTML error page from CDN must fail closed as catalog-unreachable:
HTML_CATALOG="$TESTHOME/html-catalog.html"
printf '<html><body>502 Bad Gateway</body></html>\n' > "$HTML_CATALOG"
res_html=$(FIX_CATALOG="$HTML_CATALOG" bash "$UPD" check); rc=$?
check "html catalog failure exit 0" "0" "$rc"
check "html catalog failure ok:false" "false" "$(jq -r '.ok' <<<"$res_html")"
check "html catalog failure error tag" "catalog-unreachable" "$(jq -r '.error' <<<"$res_html")"

# Corrupt stats cache must not break details map; multiple local manifest versions stay separated:
STATS_CACHE="$TESTHOME/.cache/omarchy/plugins-stats.json"
mkdir -p "${STATS_CACHE%/*}"
printf '{corrupt json\n' > "$STATS_CACHE"
res_stats=$(FIX_LIST="$TESTHOME/list.json" bash "$UPD" check)
check "corrupt stats cache preserves behind details version" "0.1.0" "$(jq -r '.details["behind.plugin"].version // ""' <<<"$res_stats")"
check "corrupt stats cache preserves sibling details version" "0.1.0" "$(jq -r '.details["lag.plugin"].version // ""' <<<"$res_stats")"

echo
if (( FAILURES > 0 )); then
  echo "$FAILURES check(s) failed"
  exit 1
fi
echo "all checks passed"
