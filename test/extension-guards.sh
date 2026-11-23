#!/bin/bash
# Regression harness for the browser extension's security gate
# (browser/extension/background.js): the only path between a marketplace
# page and the native host.
#   - isTrustedSender: sender.id must equal the extension id AND the sender
#     origin must be exactly https://plugins.omarchy.org (lookalike domains,
#     http, extra ports and missing urls all refused; sender.tab.url counts)
#   - sanitizeMessage: only whitelisted types survive; string fields are
#     sliced to fixed caps; unknown fields are dropped; `paused` boolean kept
#   - the onMessage relay refuses untrusted senders and bad payloads
#
# background.js is a plain MV3 service-worker script (not a module): it is
# loaded inside a node `vm` context with a minimal chrome.* stub, and its
# top-level functions land on the context global. No npm dependencies.
#
# Usage: test/extension-guards.sh   (exit 0 = all checks pass)
set -u

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BG="$REPO_ROOT/browser/extension/background.js"
[[ -f $BG ]] || { echo "background script not found: $BG"; exit 1; }
command -v node >/dev/null 2>&1 || { echo "node is required for this test" >&2; exit 1; }

BG="$BG" node - <<'NODE'
const fs = require("fs");
const vm = require("vm");

let failures = 0;
const check = (label, ok) => {
  if (ok) console.log(`ok   ${label}`);
  else { console.log(`FAIL ${label}`); failures += 1; }
};
process.on("unhandledRejection", () => {});

const captured = { onMessage: null };
const fakePort = {
  postMessage() {},
  disconnect() {},
  onMessage: { addListener() {} },
  onDisconnect: { addListener() {} },
};
const chromeStub = {
  runtime: {
    id: "plugbrug-ext-id",
    lastError: null,
    onMessage: { addListener(fn) { captured.onMessage = fn; } },
    connectNative: () => fakePort,
    getBrowserInfo: () => Promise.reject(new Error("not firefox")),
  },
  tabs: {
    onCreated: { addListener() {} },
    onRemoved: { addListener() {} },
    onUpdated: { addListener() {} },
    query: () => Promise.resolve([]),
    update: () => Promise.resolve(),
  },
  windows: {
    getAll: () => Promise.resolve([]),
    update: () => Promise.resolve(),
    query: () => Promise.resolve([]),
  },
};

const ctx = vm.createContext({
  chrome: chromeStub,
  URL,
  console,
  setTimeout: () => 0,
  setInterval: () => 0,
  clearTimeout: () => {},
  clearInterval: () => {},
});
vm.runInContext(fs.readFileSync(process.env.BG, "utf8"), ctx, { filename: "background.js" });

check("gate functions present",
  typeof ctx.isTrustedSender === "function" && typeof ctx.sanitizeMessage === "function");
check("onMessage relay registered", typeof captured.onMessage === "function");

const T = "https://plugins.omarchy.org";
check("valid marketplace sender accepted",
  ctx.isTrustedSender({ id: "plugbrug-ext-id", url: `${T}/plugin.html?id=x` }) === true);
check("wrong extension id refused",
  ctx.isTrustedSender({ id: "someone-else", url: `${T}/` }) === false);
check("lookalike origin refused",
  ctx.isTrustedSender({ id: "plugbrug-ext-id", url: "https://plugins.omarchy.org.evil.example/" }) === false);
check("subdomain-lookalike refused",
  ctx.isTrustedSender({ id: "plugbrug-ext-id", url: "https://plugins.omarchy.org.example.com/" }) === false);
check("http scheme refused",
  ctx.isTrustedSender({ id: "plugbrug-ext-id", url: "http://plugins.omarchy.org/" }) === false);
check("nondefault port refused",
  ctx.isTrustedSender({ id: "plugbrug-ext-id", url: "https://plugins.omarchy.org:444/" }) === false);
check("prefix-trick origin refused",
  ctx.isTrustedSender({ id: "plugbrug-ext-id", url: "https://plugins.omarchy.orgx/" }) === false);
check("sender.tab.url fallback accepted",
  ctx.isTrustedSender({ id: "plugbrug-ext-id", tab: { url: `${T}/plugin.html` } }) === true);
check("missing url refused", ctx.isTrustedSender({ id: "plugbrug-ext-id" }) === false);
check("null sender refused", ctx.isTrustedSender(null) === false);

check("unknown message type dropped", ctx.sanitizeMessage({ type: "frobnicate" }) === null);
check("null message dropped", ctx.sanitizeMessage(null) === null);
const big = (c) => c.repeat(300);
const sliced = ctx.sanitizeMessage({
  type: "install", id: big("i"), repo: big("r"), name: big("n"),
  source: big("s"), key: big("k"), url: "u".repeat(700), evil: "field",
});
check("unknown type kept? no: install kept", sliced !== null && sliced.type === "install");
check("id sliced to 128", sliced.id.length === 128);
check("repo sliced to 256", sliced.repo.length === 256);
check("name sliced to 128", sliced.name.length === 128);
check("source sliced to 32", sliced.source.length === 32);
check("key sliced to 64", sliced.key.length === 64);
check("url sliced to 512", sliced.url.length === 512);
check("unknown fields dropped",
  !("evil" in sliced) && Object.keys(sliced).sort().join(",") === "id,key,name,repo,source,type,url");
const paused = ctx.sanitizeMessage({ type: "watch", key: "abc", paused: true });
check("paused boolean kept", paused.paused === true && paused.key === "abc");

// The onMessage relay: refuse untrusted senders and bad payloads outright.
const sendResponse = () => {};
check("relay refuses untrusted sender",
  captured.onMessage({ type: "ping" }, { id: "intruder", url: T + "/" }, sendResponse) === false);
check("relay refuses bad payload from trusted sender",
  captured.onMessage({ type: "frobnicate" }, { id: "plugbrug-ext-id", url: T + "/" }, sendResponse) === false);
check("relay accepts valid pair (keeps channel open)",
  captured.onMessage({ type: "ping" }, { id: "plugbrug-ext-id", url: T + "/" }, sendResponse) === true);

console.log();
if (failures > 0) {
  console.log(`${failures} check(s) failed`);
  process.exitCode = 1;
} else {
  console.log("all checks passed");
}
NODE
