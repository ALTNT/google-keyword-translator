// Optional browser checks. Provide Playwright and BROWSER_EXECUTABLE.
// GM functions are mocked; this verifies the generated script, not manager installation.
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || "playwright");
const script = fileURLToPath(new URL("../userscript/google-keyword-translator.user.js", import.meta.url));
const profile = fs.mkdtempSync(path.join(os.tmpdir(), "text-translator-check-"));
let context;
let passed = 0;

try {
  context = await chromium.launchPersistentContext(profile, {
    executablePath: process.env.BROWSER_EXECUTABLE,
    headless: true,
    viewport: { width: 1100, height: 800 }
  });
  console.log(`Browser: ${context.browser().version()}; generated userscript with mocked GM APIs`);
  const page = await context.newPage();
  page.setDefaultTimeout(6000);
  await page.route("**/*", route => route.request().resourceType() === "document"
    ? route.fulfill({ contentType: "text/html", body: `<!doctype html><meta charset="utf-8">
      <form><input id="single" type="text"><input id="search" type="search">
      <textarea id="multi" rows="5"></textarea><button type="submit">Submit</button></form>
      <div id="rich" contenteditable="true">机器学习</div><div id="shadow"></div>
      <script>window.submissions=0; window.inputs=0; window.changes=0;
      document.querySelector('form').onsubmit=e=>{e.preventDefault();submissions++};
      document.addEventListener('input',()=>inputs++);
      document.addEventListener('change',()=>changes++);</script>` }) : route.abort());
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
  async function waitNotice(text) {
    const deadline = Date.now() + 6000;
    while (Date.now() < deadline) {
      const node = await noticeNode(text);
      if (node) return node;
      await page.waitForTimeout(40);
    }
    throw new Error(`Notice missing: ${text}`);
  }
  async function undo() {
    const nodeId = await waitNotice("恢复原文");
    const { model } = await cdp.send("DOM.getBoxModel", { nodeId });
    const q = model.border;
    await page.mouse.click((q[0] + q[4]) / 2, (q[1] + q[5]) / 2);
  }
  async function load(url = "https://example.test/editor", hosts = []) {
    await page.goto(url);
    await page.evaluate(hosts => {
      globalThis.testRequests = [];
      globalThis.testMode = "success";
      globalThis.testPending = [];
      globalThis.testReplyText = null;
      globalThis.testHosts = hosts;
      globalThis.testMenus = {};
      globalThis.testListeners = [];
      globalThis.testMenuId = 0;
      globalThis.GM_getValue = (_key, fallback) => testHosts || fallback;
      globalThis.GM_setValue = (key, value) => {
        const old = testHosts; testHosts = value;
        testListeners.forEach(fn => fn(key, old, value, false));
      };
      globalThis.GM_registerMenuCommand = (label, fn) => {
        const id = ++testMenuId; testMenus[id] = { label, fn }; return id;
      };
      globalThis.GM_unregisterMenuCommand = id => { delete testMenus[id]; };
      globalThis.GM_addValueChangeListener = (_key, fn) => { testListeners.push(fn); return testListeners.length; };
      globalThis.GM_xmlhttpRequest = options => {
        testRequests.push(options);
        const reply = () => {
          const source = new URL(options.url).searchParams.get("q");
          const translated = testReplyText ?? source.replaceAll("机器学习", "Machine learning")
            .replaceAll("人工智能", "AI").replaceAll("中文", "Chinese")
            .replace(/\p{Script=Han}+/gu, "Translated");
          options.onload({ status: testMode === "error" ? 503 : 200, response: [[[translated]]] });
        };
        if (testMode === "hold") testPending.push(reply);
        else queueMicrotask(reply);
        return { abort() { options.onabort(); } };
      };
    }, hosts);
    await page.addScriptTag({ path: script });
  }
  const single = page.locator("#single");
  const multi = page.locator("#multi");
  const hotkey = () => page.keyboard.press("Control+Quote");
  const count = () => page.evaluate(() => testRequests.length);
  const select = (field, start, end = start, direction = "none") => field.evaluate(
    (el, range) => { el.focus(); el.setSelectionRange(...range); }, [start, end, direction]);
  const input = (field, value) => field.fill(value);
  const mode = value => page.evaluate(value => { testMode = value; }, value);
  const resolvePending = () => page.evaluate(() => {
    testMode = "success"; testPending.splice(0).forEach(fn => fn());
  });
  const toggle = () => page.evaluate(() => Object.values(testMenus)[0].fn());
  async function hold(field, value) {
    await mode("hold"); await input(field, value);
    const before = await count(); await hotkey();
    await page.waitForFunction(before => testRequests.length > before, before);
  }
  async function check(label, fn) {
    await fn(); passed++; console.log(`PASS ${label}`);
  }

  for (const url of ["https://www.google.com/", "https://scholar.google.com/",
    "https://www.bing.com/search?q=test", "https://example.test/editor", "http://localhost:8000/form"]) {
    await check(`ordinary inputs on ${url}`, async () => {
      await load(url); await input(single, "机器学习"); await hotkey(); await waitNotice("已将输入内容");
      assert.equal(await single.inputValue(), "Machine learning");
      await input(page.locator("#search"), "机器学习"); await hotkey(); await waitNotice("已将输入内容");
      assert.equal(await page.locator("#search").inputValue(), "Machine learning");
      assert.equal(await page.evaluate(() => submissions), 0);
      assert.ok(await page.evaluate(() => inputs > 0 && changes > 0));
    });
  }

  await check("textarea translates only the current logical line, preserving indentation", async () => {
    await load();
    const value = "保留上行\n  机器学习  \n保留下行";
    await input(multi, value); await select(multi, value.indexOf("机器学习") + 1);
    await hotkey(); await waitNotice("已将当前行");
    assert.equal(await multi.inputValue(), "保留上行\n  Machine learning  \n保留下行");
    assert.equal(await page.evaluate(() => new URL(testRequests[0].url).searchParams.get("q")), "机器学习");
  });
  await check("empty and English current lines never fall back to the entire textarea", async () => {
    const before = await count();
    await input(multi, "中文\n\nEnglish\n中文"); await select(multi, 3);
    await hotkey(); await waitNotice("当前行为空");
    await select(multi, 5); await hotkey(); await waitNotice("没有中文");
    assert.equal(await count(), before);
    assert.equal(await multi.inputValue(), "中文\n\nEnglish\n中文");
  });
  await check("visual wrapping is still one logical line", async () => {
    await multi.evaluate(el => { el.style.width = "55px"; });
    await input(multi, "机器学习".repeat(10)); await select(multi, 5);
    await hotkey(); await waitNotice("已将当前行");
    assert.equal(await multi.inputValue(), "Machine learning".repeat(10));
  });
  await check("selected multi-line text changes only the selection and preserves blank lines", async () => {
    const value = "前缀：机器学习\n  \n\t人工智能：后缀";
    const start = value.indexOf("机器学习"); const end = value.indexOf("人工智能") + 4;
    await input(multi, value); await select(multi, start, end, "backward");
    await hotkey(); await waitNotice("已将选中文字");
    assert.equal(await multi.inputValue(), "前缀：Machine learning\n  \n\tAI：后缀");
    await undo(); await waitNotice("已恢复原文");
    assert.equal(await multi.inputValue(), value);
    assert.deepEqual(await multi.evaluate(el => [el.selectionStart, el.selectionEnd, el.selectionDirection]), [start, end, "backward"]);
  });
  await check("single-line partial selection preserves search syntax and surrounding text", async () => {
    await input(single, "site:example.com 机器学习 AND AI"); await select(single, 17, 21);
    await hotkey(); await waitNotice("已将选中文字");
    assert.equal(await single.inputValue(), "site:example.com Machine learning AND AI");
  });
  await check("restore does not overwrite subsequent edits", async () => {
    await input(single, "机器学习"); await hotkey(); await waitNotice("已将输入内容");
    await input(single, "新的内容"); await undo(); await waitNotice("未覆盖当前内容");
    assert.equal(await single.inputValue(), "新的内容");
  });
  await check("empty, English and oversized targets do not send requests", async () => {
    const before = await count();
    await input(single, ""); await hotkey(); await waitNotice("为空");
    await input(single, "English"); await hotkey(); await waitNotice("没有中文");
    await input(single, "中".repeat(2001)); await hotkey(); await waitNotice("超过 2000");
    assert.equal(await count(), before);
  });
  await check("small selections in large text fields remain supported", async () => {
    await input(multi, "x".repeat(3000) + "机器学习"); await select(multi, 3000, 3004);
    await hotkey(); await waitNotice("已将选中文字");
    assert.equal(await multi.inputValue(), "x".repeat(3000) + "Machine learning");
  });
  await check("IME composition and other modifier combinations do not translate", async () => {
    const before = await count(); await input(single, "中文");
    await single.dispatchEvent("compositionstart"); await hotkey();
    await single.dispatchEvent("compositionend");
    await page.keyboard.press("Meta+Quote"); await page.keyboard.press("Control+Shift+Quote");
    assert.equal(await count(), before);
  });
  await check("webpage-generated shortcuts cannot trigger a translation", async () => {
    const before = await count();
    await single.dispatchEvent("keydown", { key: "'", code: "Quote", ctrlKey: true });
    assert.equal(await count(), before);
  });
  await check("pending responses cannot overwrite edits even when changed back", async () => {
    await hold(single, "机器学习"); await input(single, "中文"); await input(single, "机器学习");
    await resolvePending(); await waitNotice("未替换内容");
    assert.equal(await single.inputValue(), "机器学习");
  });
  await check("changing selection while waiting cancels replacement", async () => {
    await hold(single, "机器学习 中文"); await select(single, 0, 4);
    await resolvePending(); await waitNotice("未替换内容");
    assert.equal(await single.inputValue(), "机器学习 中文");
  });
  await check("pending responses do not steal focus", async () => {
    await hold(single, "机器学习"); await multi.focus();
    await resolvePending(); await waitNotice("未替换内容");
    assert.equal(await single.inputValue(), "机器学习");
  });
  await check("repeated shortcuts while waiting send only one request", async () => {
    const before = await count(); await hold(single, "机器学习"); await hotkey(); await hotkey();
    assert.equal(await count(), before + 1); await resolvePending(); await waitNotice("已将输入内容");
  });
  await check("service errors preserve text and allow retry", async () => {
    await mode("error"); await input(single, "机器学习"); await hotkey(); await waitNotice("503");
    assert.equal(await single.inputValue(), "机器学习");
    await mode("success"); await hotkey(); await waitNotice("已将输入内容");
  });
  await check("maxlength is respected instead of inserting an overlong translation", async () => {
    await single.evaluate(el => { el.maxLength = 5; });
    await input(single, "机器学习"); await hotkey(); await waitNotice("长度限制");
    assert.equal(await single.inputValue(), "机器学习");
    await single.evaluate(el => { el.removeAttribute("maxlength"); });
  });
  await check("a translation dropping newlines does not flatten the selected text", async () => {
    await input(multi, "机器学习\n人工智能"); await select(multi, 0, 9);
    await page.evaluate(() => { testReplyText = "Machine learning AI"; });
    await hotkey(); await waitNotice("换行");
    assert.equal(await multi.inputValue(), "机器学习\n人工智能");
    await page.evaluate(() => { testReplyText = null; });
  });
  await check("structured and sensitive fields do not translate", async () => {
    const before = await count();
    for (const attrs of [{type:"password"}, {type:"email"}, {type:"url"}, {type:"number"}, {type:"tel"},
      {type:"text", autocomplete:"one-time-code"}, {type:"text", autocomplete:"cc-number"},
      {type:"text", id:"verification_code"}, {type:"text", inputmode:"numeric"},
      {type:"text", readonly:""}, {type:"text", "aria-hidden":"true"}]) {
      await page.evaluate(attrs => {
        document.querySelector("#excluded")?.remove();
        const field = document.createElement("input"); field.id="excluded";
        for (const [key, value] of Object.entries(attrs)) field.setAttribute(key,value);
        field.value="中文"; document.body.append(field); field.focus();
      }, attrs);
      await hotkey();
    }
    assert.equal(await count(), before);
  });
  await check("disabled fieldsets and rich editors are excluded", async () => {
    const before = await count();
    await page.evaluate(() => {
      const group=document.createElement("fieldset"); group.disabled=true;
      const field=document.createElement("input"); field.value="中文"; group.append(field);
      document.body.append(group); field.focus();
    });
    await hotkey(); await page.locator("#rich").focus(); await hotkey();
    assert.equal(await count(), before);
    assert.equal(await page.locator("#rich").textContent(), "机器学习");
  });
  await check("dynamically created inputs and open Shadow DOM fields work", async () => {
    await page.evaluate(() => {
      const root=document.querySelector("#shadow").attachShadow({mode:"open"});
      const field=document.createElement("textarea"); field.id="shadow-field"; root.append(field);
    });
    const field=page.locator("#shadow-field");
    await input(field,"机器学习"); await hotkey(); await waitNotice("已将当前行");
    assert.equal(await field.inputValue(),"Machine learning");
    await undo(); await waitNotice("已恢复原文"); assert.equal(await field.inputValue(),"机器学习");
  });
  await check("sites rejecting synthetic input receive a compatibility notice", async () => {
    await single.evaluate(el => { el.addEventListener("input", e => { if(!e.isTrusted) el.value="机器学习"; }, {once:true}); });
    await single.evaluate(el => { el.value="机器学习"; el.focus(); el.setSelectionRange(4,4); });
    await hotkey(); await waitNotice("网站未接受译文");
    assert.equal(await single.inputValue(),"机器学习");
  });
  await check("site disable and enable menu works immediately and survives reload", async () => {
    await toggle(); const hosts=await page.evaluate(()=>testHosts);
    assert.ok(hosts.includes("example.test"));
    await input(single,"机器学习"); const before=await count(); await hotkey();
    assert.equal(await count(),before);
    await load("https://example.test/editor",hosts); await input(single,"机器学习"); await hotkey();
    assert.equal(await count(),0);
    await toggle(); await hotkey(); await waitNotice("已将输入内容");
    assert.equal(await single.inputValue(),"Machine learning");
  });
  await check("disabling and re-enabling a site invalidates its pending translation", async () => {
    await hold(single,"机器学习"); await toggle(); await toggle();
    await resolvePending(); await waitNotice("未替换内容");
    assert.equal(await single.inputValue(),"机器学习");
  });
  await check("site setting changes from another tab update the current instance", async () => {
    await page.evaluate(()=>{testHosts=["example.test"];testListeners.forEach(fn=>fn("disabledHosts",[],testHosts,true));});
    const before=await count(); await input(single,"机器学习"); await hotkey();
    assert.equal(await count(),before);
    assert.match(await page.evaluate(()=>Object.values(testMenus)[0].label),/启用/);
  });
  console.log(`${passed} browser checks passed.`);
} finally {
  await context?.close();
  fs.rmSync(profile,{recursive:true,force:true});
}
