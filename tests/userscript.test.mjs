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
  vm.runInContext(read("userscript/config.js"), context);
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
  assert.match(source, /@match\s+https:\/\/\*\/\*/);
  assert.match(source, /@match\s+http:\/\/\*\/\*/);
  assert.match(source, /@grant\s+GM_registerMenuCommand/);
  assert.match(source, /@grant\s+GM_addValueChangeListener/);
  assert.equal((source.match(/@match\s/g) || []).length, 2);
});

test("GM transport joins translations, encodes text and requests no cookies", async () => {
  const h = harness(options => options.onload({ status: 200, response: [[["machine "], ["learning"]]] }));
  const result = await h.translate("  机器 & #学习  ");
  assert.equal(result.ok, true);
  assert.equal(result.text, "  machine learning  ");
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

test("selected multi-line translation preserves whitespace, blank lines and line separators", async () => {
  const h = harness(options => options.onload({
    status: 200, response: [[["Machine learning\n\nAI"]]]
  }));
  const result = await h.translate("  机器学习\r\n  \r\n\t人工智能  \n");
  assert.equal(result.ok, true);
  assert.equal(result.text, "  Machine learning\r\n  \r\n\tAI  \n");
});

test("a translation that drops line breaks is rejected rather than flattening the selection", async () => {
  const h = harness(options => options.onload({ status: 200, response: [[["Machine learning AI"]]] }));
  const result = await h.translate("机器学习\n人工智能");
  assert.equal(result.ok, false);
  assert.match(result.error, /换行/);
});

test("a translation that erases a non-empty line is rejected", async () => {
  const h = harness(options => options.onload({ status: 200, response: [[["Machine learning\n\nAI"]]] }));
  const result = await h.translate("机器学习\n中文\n人工智能");
  assert.equal(result.ok, false);
  assert.match(result.error, /遗漏/);
});

test("range rules choose selections, the current logical line, or the entire single-line field", () => {
  const context = vm.createContext({ URL });
  vm.runInContext(read("userscript/config.js"), context);
  const config = vm.runInContext("KeywordTranslatorConfig", context);
  const select = (...args) => JSON.parse(JSON.stringify(config.translationRange(...args)));
  const value = "第一行\n机器学习\n第三行";
  assert.deepEqual(select(value, 5, 5, true), { start: 4, end: 8, scope: "当前行" });
  assert.deepEqual(select(value, 3, 3, true), { start: 0, end: 3, scope: "当前行" });
  assert.deepEqual(select(value, 9, 9, true), { start: 9, end: 12, scope: "当前行" });
  assert.deepEqual(select(value, 1, 10, true), { start: 1, end: 10, scope: "选中文字" });
  assert.deepEqual(select("\n中文\n", 0, 0, true), { start: 0, end: 0, scope: "当前行" });
  assert.deepEqual(select("\n中文\n", 4, 4, true), { start: 4, end: 4, scope: "当前行" });
  assert.deepEqual(select("中文", 1, 1, false), { start: 0, end: 2, scope: "输入内容" });
  assert.deepEqual(select("中文", 0, 1, false), { start: 0, end: 1, scope: "选中文字" });
  assert.equal(config.isSupportedPage("https://example.com/path"), true);
  assert.equal(config.isSupportedPage("http://localhost:8000/path"), true);
  assert.equal(config.isSupportedPage("chrome://settings"), false);
});
