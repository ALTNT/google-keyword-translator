// Optional integration checks using Playwright and a disposable browser profile.
// Set PLAYWRIGHT_MODULE to a Playwright package directory if it is not installed locally.
// Set BROWSER_EXECUTABLE to Brave, Chromium or Chrome. Chrome uses CONTENT_ONLY=1
// because recent branded Chrome releases disable command-line extension loading.
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || "playwright");
const extension = fileURLToPath(new URL("../extension/", import.meta.url));
const userscriptMode = process.env.USERSCRIPT === "1";
const contentOnly = userscriptMode || process.env.CONTENT_ONLY === "1";
const profile = fs.mkdtempSync(path.join(os.tmpdir(), "keyword-translator-check-"));
let context;
let passed = 0;

try {
  context = await chromium.launchPersistentContext(profile, {
    executablePath: process.env.BROWSER_EXECUTABLE,
    headless: true,
    ignoreDefaultArgs: ["--disable-extensions"],
    args: contentOnly ? [] : [
      `--disable-extensions-except=${extension}`, `--load-extension=${extension}`
    ],
    viewport: { width: 1100, height: 800 }
  });
  console.log(`Browser: ${context.browser().version()}; mode: ${userscriptMode ? "userscript with mocked GM bridge" : contentOnly ? "content script" : "loaded extension"}`);
  const worker = contentOnly ? null : context.serviceWorkers()[0] ||
    await context.waitForEvent("serviceworker", { timeout: 15000 });
  if (worker) console.log(`Service worker loaded: ${worker.url()}`);

  const fixture = `<!doctype html><html><head><meta charset="utf-8"></head><body>
    <form><textarea name="q" aria-label="Search"></textarea><input name="as_q">
    <input name="unrelated"><button type="submit">Search</button></form>
    <script>window.submissions = 0; window.inputs = 0; window.changes = 0;
    document.querySelector('form').addEventListener('submit', e => {e.preventDefault(); submissions++});
    document.addEventListener('input', () => inputs++);
    document.addEventListener('change', () => changes++);</script></body></html>`;
  const page = await context.newPage();
  page.setDefaultTimeout(6000);
  await page.route("**/*", route => route.request().resourceType() === "document"
    ? route.fulfill({ contentType: "text/html", body: fixture }) : route.abort());
  const cdp = await context.newCDPSession(page);

  async function noticeNode(text) {
    const { root } = await cdp.send("DOM.getDocument", { depth: -1, pierce: true });
    function search(node, inNotice = false) {
      if (["SCRIPT", "STYLE"].includes(node.nodeName)) return;
      inNotice ||= node.attributes?.includes("data-keyword-translator");
      if (inNotice && node.nodeValue?.includes(text)) return node.parentId;
      for (const child of [...(node.children || []), ...(node.shadowRoots || [])]) {
        child.parentId = node.nodeId;
        const found = search(child, inNotice);
        if (found) return found;
      }
    }
    return search(root);
  }

  async function waitNotice(text, timeout = 6000) {
    const deadline = Date.now() + timeout;
    while (Date.now() < deadline) {
      const node = await noticeNode(text);
      if (node) return node;
      await page.waitForTimeout(50);
    }
    throw new Error(`Notice missing: ${text}`);
  }

  const mock = () => {
    globalThis.testRequests = [];
    globalThis.testMode = "success";
    globalThis.testPending = [];
    globalThis.testOriginalFetch = globalThis.fetch;
    globalThis.testReply = () => ({ ok: true, text: "Cross-regional crop mapping" });
    if (globalThis.testUseUserscript) {
      globalThis.GM_xmlhttpRequest = options => {
        testRequests.push(options.url);
        const reply = () => options.onload({
          status: testMode === "error" ? 503 : 200,
          response: [[["Cross-regional crop mapping"]]]
        });
        if (testMode === "hold") testPending.push(reply);
        else queueMicrotask(reply);
        return { abort() { options.onabort(); } };
      };
      return;
    }
    if (typeof chrome.runtime?.sendMessage === "function" && !globalThis.document) {
      globalThis.fetch = async url => {
        testRequests.push(String(url));
        const reply = () => testMode === "error"
          ? new Response("unavailable", { status: 503 })
          : new Response(JSON.stringify([[["Cross-regional crop mapping"]]]), {
            headers: { "Content-Type": "application/json" }
          });
        if (testMode === "hold") return new Promise(resolve => testPending.push(() => resolve(reply())));
        return reply();
      };
    } else {
      chrome.runtime = {
        sendMessage: async message => {
          testRequests.push(message);
          const reply = () => testMode === "error"
            ? { ok: false, error: "翻译服务暂时不可用（HTTP 503）。" } : testReply();
          if (testMode === "hold") return new Promise(resolve => testPending.push(() => resolve(reply())));
          return reply();
        }
      };
    }
  };
  if (worker) await worker.evaluate(mock);
  const state = worker || page;
  async function load(url, input = false) {
    await page.goto(url);
    if (input) await page.locator('[name="q"]').evaluate(el => {
      const field = document.createElement("input"); field.name = "q"; field.type = "text";
      el.replaceWith(field);
    });
    if (contentOnly) {
      await page.evaluate(value => { globalThis.testUseUserscript = value; }, userscriptMode);
      await page.evaluate(mock);
      if (userscriptMode) {
        await page.addScriptTag({ path: fileURLToPath(new URL("../userscript/google-keyword-translator.user.js", import.meta.url)) });
      } else {
        await page.addScriptTag({ path: path.join(extension, "shared.js") });
        await page.addScriptTag({ path: path.join(extension, "content.js") });
      }
    }
    await page.waitForTimeout(100);
  }
  const field = page.locator('[name="q"]');
  const hotkey = () => page.keyboard.press("Control+Quote");
  const count = () => state.evaluate(() => testRequests.length);
  const mode = value => state.evaluate(value => { testMode = value; }, value);
  const resolvePending = () => state.evaluate(() => {
    testMode = "success"; testPending.splice(0).forEach(resolve => resolve());
  });
  async function check(label, fn) {
    await fn(); passed++; console.log(`PASS ${label}`);
  }
  async function translate() {
    await field.fill("跨区域农作物制图");
    await hotkey();
    await page.waitForFunction(() => document.querySelector('[name="q"]').value === "Cross-regional crop mapping");
    await waitNotice("已翻译为英文");
  }

  for (const [url, input] of [
    ["https://www.google.com/", false], ["https://www.google.com/search?q=test", false],
    ["https://scholar.google.com/", true], ["https://scholar.google.com/scholar?q=test", true]
  ]) {
    await check(`Ctrl + ' on ${url}`, async () => {
      await load(url, input);
      await translate();
      assert.equal(await page.evaluate(() => submissions), 0);
      assert.ok(await page.evaluate(() => inputs > 0 && changes > 0));
    });
  }

  await check("restore original Chinese with the visible button", async () => {
    const nodeId = await waitNotice("恢复中文");
    const { model } = await cdp.send("DOM.getBoxModel", { nodeId });
    const quad = model.border;
    await page.mouse.click((quad[0] + quad[4]) / 2, (quad[1] + quad[5]) / 2);
    assert.equal(await field.inputValue(), "跨区域农作物制图");
    await waitNotice("已恢复");
  });

  await check("restore does not overwrite newer edits", async () => {
    await translate();
    await field.fill("最新输入");
    const nodeId = await waitNotice("恢复中文");
    const { model } = await cdp.send("DOM.getBoxModel", { nodeId });
    const quad = model.border;
    await page.mouse.click((quad[0] + quad[4]) / 2, (quad[1] + quad[5]) / 2);
    assert.equal(await field.inputValue(), "最新输入");
    await waitNotice("未覆盖当前内容");
  });

  await check("no translation for other modifier keys or unrelated fields", async () => {
    const before = await count();
    await field.fill("中文");
    await page.keyboard.press("Meta+Quote");
    await page.keyboard.press("Control+Shift+Quote");
    await page.locator('[name="unrelated"]').fill("中文");
    await hotkey();
    await page.waitForTimeout(150);
    assert.equal(await count(), before);
  });

  await check("empty and English text do not make network requests", async () => {
    const before = await count();
    await field.fill(""); await hotkey(); await waitNotice("请先");
    await field.fill("crop mapping"); await hotkey(); await waitNotice("没有中文");
    assert.equal(await count(), before);
  });

  await check("IME composition does not trigger translation", async () => {
    const before = await count();
    await field.fill("中文");
    await field.dispatchEvent("compositionstart");
    await hotkey();
    await field.dispatchEvent("compositionend");
    await page.waitForTimeout(100);
    assert.equal(await count(), before);
  });

  await check("pending responses never overwrite edits, even if text is changed back", async () => {
    await mode("hold");
    const before = await count();
    await field.fill("原始中文"); await hotkey();
    while (await count() === before) await page.waitForTimeout(50);
    await field.fill("修改后的中文"); await field.fill("原始中文");
    await resolvePending(); await waitNotice("未替换关键词");
    assert.equal(await field.inputValue(), "原始中文");
  });

  await check("pending responses do not steal focus", async () => {
    await mode("hold");
    const before = await count();
    await field.fill("中文"); await hotkey();
    while (await count() === before) await page.waitForTimeout(50);
    await page.locator('[name="unrelated"]').focus();
    await resolvePending(); await waitNotice("未替换关键词");
    assert.equal(await field.inputValue(), "中文");
  });

  await check("repeated shortcut while pending sends only one request", async () => {
    await mode("hold");
    const before = await count();
    await field.fill("中文"); await hotkey(); await hotkey();
    await page.waitForTimeout(150);
    assert.equal(await count(), before + 1);
    await resolvePending(); await waitNotice("已翻译");
  });

  await check("service errors preserve original text and allow retry", async () => {
    await mode("error");
    await field.fill("中文"); await hotkey(); await waitNotice("503");
    assert.equal(await field.inputValue(), "中文");
    await mode("success"); await translate();
  });

  await check("dynamically replaced fields are supported", async () => {
    await field.evaluate(el => {
      const next = document.createElement("textarea"); next.name = "q"; el.replaceWith(next);
    });
    await translate();
  });

  await check("Scholar advanced all-words search field is supported", async () => {
    await load("https://scholar.google.com/scholar_advanced");
    await page.locator('[name="as_q"]').fill("中文");
    await hotkey(); await waitNotice("已翻译");
    assert.equal(await page.locator('[name="as_q"]').inputValue(), "Cross-regional crop mapping");
  });

  await check("unrelated Google pages do not translate", async () => {
    await load("https://www.google.com/maps");
    const before = await count();
    await field.fill("中文"); await hotkey(); await page.waitForTimeout(100);
    assert.equal(await count(), before);
  });

  if (worker) {
    await check("live Google Translate request from the extension service worker", async () => {
      await worker.evaluate(() => { fetch = testOriginalFetch; });
      await load("https://www.google.com/search?q=test");
      await field.fill("跨区域农作物制图"); await hotkey(); await waitNotice("已翻译为英文");
      const value = await field.inputValue();
      assert.match(value.toLowerCase(), /crop/);
      console.log(`LIVE ${value}`);
    });
    if (process.env.LIVE_PAGES === "1") {
      await check("real Google and Scholar home pages", async () => {
        await page.unroute("**/*");
        for (const url of ["https://www.google.com/", "https://scholar.google.com/"]) {
          await page.goto(url, { waitUntil: "domcontentloaded", timeout: 30000 });
          await page.waitForLoadState("load", { timeout: 30000 });
          await page.waitForTimeout(500);
          await field.fill("跨区域农作物制图"); await hotkey();
          await waitNotice("正在将关键词");
          await waitNotice("已翻译为英文", 18000);
          assert.match((await field.inputValue()).toLowerCase(), /crop/);
          console.log(`LIVE PAGE ${url}`);
        }
      });
    }
  }
  console.log(`${passed} browser checks passed.`);
} finally {
  await context?.close();
  fs.rmSync(profile, { recursive: true, force: true });
}
