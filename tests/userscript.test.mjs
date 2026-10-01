import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";
import test from "node:test";

const read = file => fs.readFileSync(new URL(`../${file}`, import.meta.url), "utf8");
function harness(handler) {
  let expire;
  let request;
  let aborts = 0;
  let clears = 0;
  const context = vm.createContext({
    URL, URLSearchParams,
    setTimeout(fn) { expire = fn; return 1; },
    clearTimeout() { clears++; },
    GM_xmlhttpRequest(options) {
      request = options;
      handler?.(options);
      return { abort() { aborts++; options.onabort(); } };
    }
  });
  vm.runInContext(read("extension/shared.js"), context);
  vm.runInContext(read("userscript/transport.js"), context);
  return {
    translate: text => context.translateSearchKeywords(text),
    request: () => request,
    expire: () => expire(),
    aborts: () => aborts,
    clears: () => clears,
    context
  };
}

test("generated userscript is standalone and declares only required GM access", () => {
  const source = read("userscript/google-keyword-translator.user.js");
  new vm.Script(source);
  assert.match(source, /@grant\s+GM_xmlhttpRequest/);
  assert.match(source, /@connect\s+translate\.googleapis\.com/);
  assert.match(source, /@noframes/);
  assert.match(source, /@sandbox\s+DOM/);
  assert.doesNotMatch(source, /chrome\.runtime\.sendMessage|@require|@connect\s+\*/);
  assert.equal((source.match(/@match\s/g) || []).length, 39);
});

test("GM transport joins translations, encodes text and requests no cookies", async () => {
  const h = harness(options => options.onload({ status: 200, response: [[["machine "], ["learning"]]] }));
  const result = await h.translate("  机器 & #学习  ");
  assert.equal(result.ok, true);
  assert.equal(result.text, "machine learning");
  assert.equal(new URL(h.request().url).searchParams.get("q"), "机器 & #学习");
  assert.equal(h.request().anonymous, true);
  assert.equal(h.request().timeout, 12000);
  assert.equal(h.clears(), 1);
});

test("GM transport supports responseText and rejects invalid translations", async () => {
  const h = harness(options => options.onload({ status: 200, responseText: '[[["artificial intelligence"]]]' }));
  assert.equal((await h.translate("人工智能")).text, "artificial intelligence");
  for (const response of [null, {}, [], [[["人工智能"]]], [[["artificial 人工智能"]]]]) {
    const invalid = harness(options => options.onload({ status: 200, response }));
    assert.equal((await invalid.translate("人工智能")).ok, false);
  }
});

test("invalid input does not send a request", async () => {
  for (const text of [null, "", "English", "中".repeat(2001)]) {
    const h = harness();
    assert.equal((await h.translate(text)).ok, false);
    assert.equal(h.request(), undefined);
  }
});

test("GM failures are readable and clear the timer", async () => {
  for (const [event, expected] of [
    ["onerror", /检查网络/], ["ontimeout", /超时/], ["onabort", /取消/]
  ]) {
    const h = harness(options => options[event]());
    const result = await h.translate("中文");
    assert.equal(result.ok, false);
    assert.match(result.error, expected);
    assert.equal(h.clears(), 1);
  }
  for (const status of [429, 503]) {
    const h = harness(options => options.onload({ status }));
    assert.match((await h.translate("中文")).error, status === 429 ? /频繁/ : /503/);
  }
});

test("independent timeout aborts a hanging anonymous request and ignores late responses", async () => {
  const h = harness();
  const pending = h.translate("中文");
  h.expire();
  const result = await pending;
  assert.equal(result.ok, false);
  assert.match(result.error, /超时/);
  assert.equal(h.aborts(), 1);
  h.request().onload({ status: 200, response: [[["Chinese"]]] });
  assert.equal(h.clears(), 1);
});

test("unexpected redirect and missing manager return errors", async () => {
  const h = harness(options => options.onload({
    status: 200, finalUrl: "https://other.example/", response: [[["Chinese"]]]
  }));
  assert.match((await h.translate("中文")).error, /地址发生变化/);
  const missing = harness();
  delete missing.context.GM_xmlhttpRequest;
  assert.match((await missing.translate("中文")).error, /Tampermonkey/);
});
