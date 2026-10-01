import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";
import test from "node:test";

const extension = new URL("../extension/", import.meta.url);
const read = name => fs.readFileSync(new URL(name, extension), "utf8");

function harness(fetchImpl = async () => ({ ok: true, json: async () => [[["machine learning"]]] })) {
  let listener;
  let timerCallback;
  let timerCleared = false;
  const calls = [];
  const context = vm.createContext({
    URL, URLSearchParams, AbortController, TypeError,
    setTimeout(callback) { timerCallback = callback; return 1; },
    clearTimeout() { timerCleared = true; },
    fetch: async (...args) => { calls.push(args); return fetchImpl(...args); },
    chrome: { runtime: { id: "our-extension", onMessage: { addListener(fn) { listener = fn; } } } }
  });
  context.importScripts = name => vm.runInContext(read(name), context);
  vm.runInContext(read("background.js"), context);
  const sender = {
    id: "our-extension", tab: { id: 1 }, frameId: 0, url: "https://www.google.com/search?q=test"
  };
  return {
    context, calls, sender,
    expire: () => timerCallback(),
    timerCleared: () => timerCleared,
    send(message, source = sender) {
      let keepAlive;
      const result = new Promise(resolve => { keepAlive = listener(message, source, resolve); });
      return { result, keepAlive };
    }
  };
}

const message = text => ({ type: "TRANSLATE_SEARCH_KEYWORDS", text });

test("manifest references bundled files and grants only the translation network host", () => {
  const manifest = JSON.parse(read("manifest.json"));
  assert.equal(manifest.manifest_version, 3);
  assert.deepEqual(manifest.host_permissions, ["https://translate.googleapis.com/*"]);
  assert.equal(manifest.permissions, undefined);
  assert.equal(manifest.commands, undefined);
  for (const file of [manifest.background.service_worker, manifest.action.default_popup,
    ...manifest.content_scripts[0].js]) assert.ok(fs.existsSync(new URL(file, extension)));
  const { context } = harness();
  const expected = Array.from(context.KeywordTranslatorConfig.domains).flatMap(domain => [
    `https://${domain}/*`, `https://www.${domain}/*`, `https://scholar.${domain}/*`
  ]);
  assert.deepEqual(manifest.content_scripts[0].matches, expected);
});

test("accepts Google and Scholar searches, rejects spoofed domains and unrelated pages", () => {
  const { context } = harness();
  const supported = context.KeywordTranslatorConfig.isSupportedPage;
  for (const url of ["https://www.google.com/", "https://google.com/webhp?hl=zh-CN",
    "https://www.google.com.hk/search?q=中文", "https://scholar.google.com/scholar?q=中文",
    "https://scholar.google.com/scholar_advanced"]) assert.equal(supported(url), true, url);
  for (const url of ["https://google.com.evil.example/search", "https://evilgoogle.com/",
    "http://www.google.com/", "https://mail.google.com/", "https://www.google.com/maps",
    "https://scholar.google.com/citations", "not a URL"]) assert.equal(supported(url), false, url);
});

test("translates joined segments, safely encodes query, and omits credentials", async () => {
  const h = harness(async () => ({ ok: true, json: async () => [[["machine "], ["learning"]]] }));
  const { result, keepAlive } = h.send(message("  机器 & AI #学习  "));
  assert.equal(keepAlive, true);
  const response = await result;
  assert.equal(response.ok, true);
  assert.equal(response.text, "machine learning");
  const [rawUrl, options] = h.calls[0];
  const url = new URL(rawUrl);
  assert.equal(url.origin, "https://translate.googleapis.com");
  assert.equal(url.searchParams.get("q"), "机器 & AI #学习");
  assert.equal(url.searchParams.get("tl"), "en");
  assert.equal(url.searchParams.get("sl"), "auto");
  assert.equal(options.credentials, "omit");
  assert.equal(options.redirect, "error");
  assert.equal(options.cache, "no-store");
  assert.equal(h.timerCleared(), true);
});

test("validates text before making a request", async () => {
  const h = harness();
  for (const text of [null, 123, "", "   ", "machine learning", "中".repeat(2001)]) {
    const { result, keepAlive } = h.send(message(text));
    assert.equal(keepAlive, false);
    assert.equal((await result).ok, false);
  }
  assert.equal(h.calls.length, 0);
});

test("validates sender identity, page and frame", async () => {
  const h = harness();
  for (const patch of [{ id: "other-extension" }, { tab: undefined }, { frameId: 1 },
    { url: "https://www.google.com/maps" }, { url: "https://google.com.evil.example/" }]) {
    const { result, keepAlive } = h.send(message("机器学习"), { ...h.sender, ...patch });
    assert.equal(keepAlive, false);
    assert.equal((await result).ok, false);
  }
  assert.equal(h.calls.length, 0);
});

test("ignores unrelated messages", () => {
  const h = harness();
  assert.equal(h.send({ type: "OTHER" }).keepAlive, false);
  assert.equal(h.send(null).keepAlive, false);
  assert.equal(h.calls.length, 0);
});

test("reports service rate limiting and HTTP failure", async () => {
  for (const status of [429, 503]) {
    const h = harness(async () => ({ ok: false, status }));
    const response = await h.send(message("机器学习")).result;
    assert.equal(response.ok, false);
    assert.match(response.error, status === 429 ? /频繁/ : /503/);
    assert.equal(h.timerCleared(), true);
  }
});

test("rejects empty, malformed, unchanged or partly Chinese translations", async () => {
  for (const data of [null, {}, [], [[]], [[null]], [[["机器学习"]]], [[["machine 学习"]]]]) {
    const h = harness(async () => ({ ok: true, json: async () => data }));
    const response = await h.send(message("机器学习")).result;
    assert.equal(response.ok, false);
    assert.match(response.error, /英文译文/);
  }
});

test("network failures return a readable error", async () => {
  const h = harness(async () => { throw new TypeError("Failed to fetch"); });
  const response = await h.send(message("机器学习")).result;
  assert.equal(response.ok, false);
  assert.match(response.error, /检查网络/);
});

test("aborts a stalled fetch at the deadline", async () => {
  const h = harness((_url, options) => new Promise((_resolve, reject) => {
    options.signal.addEventListener("abort", () => reject(new Error("aborted")));
  }));
  const { result } = h.send(message("机器学习"));
  h.expire();
  const response = await result;
  assert.equal(response.ok, false);
  assert.match(response.error, /超时/);
  assert.equal(h.timerCleared(), true);
});
