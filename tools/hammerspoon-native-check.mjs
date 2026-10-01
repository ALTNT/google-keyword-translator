// Opt-in integration checks in an already trusted Hammerspoon instance.
// Requires require("hs.ipc") in its console, Playwright and a headed Chromium.
// Uses a temporary browser profile and local fixture, never existing documents.
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { createRequire } from "node:module";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || "playwright");
const cli = process.env.HAMMERSPOON_CLI || "/Applications/Hammerspoon.app/Contents/Frameworks/hs/hs";
const source = fileURLToPath(new URL("../hammerspoon/keyword_translator.lua", import.meta.url));
const lua = text => JSON.stringify(text);
function call(code) {
  const result = spawnSync(cli, ["-t", "4", "-c", code], { encoding: "utf8" });
  assert.equal(result.status, 0, result.stderr || result.stdout);
  assert.ok(!/stack traceback|Error:/.test(result.stdout), result.stdout);
  return result.stdout.trim();
}
assert.match(call('return hs.accessibilityState()'), /true$/);
const profile = fs.mkdtempSync(path.join(os.tmpdir(), "translator-native-check-"));
let context;
let passed = 0;
try {
  context = await chromium.launchPersistentContext(profile, {
    executablePath: process.env.BROWSER_EXECUTABLE,
    headless: false, viewport: { width: 900, height: 650 },
    args: ["--force-renderer-accessibility"]
  });
  const page = await context.newPage();
  await page.setContent('<title>Keyword translator native regression</title><meta charset="utf-8">'
    + '<input id="single"><textarea id="multi" style="width:180px;height:180px"></textarea>'
    + '<div id="rich" contenteditable="true" style="width:180px;white-space:pre-wrap"></div>');
  call(`_translatorNativePreviousApp = hs.application.frontmostApplication(); _translatorNativeCheck = dofile(${lua(source)}).new(); _translatorNativeCheck.running = true`);

  async function prepare(id, value, start, length = 0) {
    await page.locator(`#${id}`).evaluate((el, value) => {
      if (el.isContentEditable) el.textContent = value; else el.value = value;
    }, value);
    await page.locator(`#${id}`).click();
    await page.locator(`#${id}`).evaluate((el, range) => {
      el.focus();
      if (el.isContentEditable) {
        const selection = window.getSelection(), r = document.createRange();
        r.setStart(el.firstChild, range[0]); r.setEnd(el.firstChild, range[0] + range[1]);
        selection.removeAllRanges(); selection.addRange(r);
      } else el.setSelectionRange(range[0], range[0] + range[1]);
    }, [start, length]);
    await page.bringToFront();
    call('for _, a in ipairs(hs.application.runningApplications()) do for _, w in ipairs(a:allWindows()) do '
      + 'if w:title():find("Keyword translator native regression",1,true) then a:activate(); w:focus() end end end');
    await page.waitForTimeout(180);
    // Exact comparison makes interference abort before any write.
    assert.match(call(`local s = assert(_translatorNativeCheck:capture()); assert(s.original == ${lua(value)}); `
      + `assert(s.selection.location == ${start} and s.selection.length == ${length}); return true`), /true$/);
  }
  const valueOf = id => page.locator(`#${id}`).evaluate(el => el.isContentEditable ? el.innerText : el.value);
  async function replace(id, original, start, length, translated, expected) {
    await prepare(id, original, start, length);
    // Only the external translation response is supplied here. AX capture,
    // listeners, selection, Cmd+V, clipboard restoration and Cmd+Z are native.
    call(`_translatorNativeClipboard = hs.pasteboard.readAllData(); local t = _translatorNativeCheck; local s = assert(t:capture()); `
      + '_translatorNativeElement=s.element; local j = {snapshot=s}; t.job=j; assert(t:watch(s)); '
      + `t:replace(j, ${lua(translated)})`);
    try { await page.waitForFunction(({ id, expected }) => {
      const el = document.getElementById(id); return (el.isContentEditable ? el.innerText : el.value) === expected;
    }, { id, expected }, { timeout: 2500 }); } catch (error) {
      console.error("Native diagnostic:", call('return _translatorNativeCheck.status'), "Fixture value:", await valueOf(id));
      throw error;
    }
    await page.waitForTimeout(400);
    assert.match(call('local after = hs.pasteboard.readAllData(); '
      + 'for k,v in pairs(_translatorNativeClipboard) do assert(after[k] == v, "clipboard format not restored") end; '
      + 'for k,v in pairs(after) do assert(_translatorNativeClipboard[k] == v, "unexpected clipboard format") end; '
      + 'return _translatorNativeCheck.job == nil and not _translatorNativeCheck.pasting'), /true$/);
    call(`local s = assert(_translatorNativeCheck:capture()); assert(s.element == _translatorNativeElement and s.original == ${lua(expected)}, "fixture lost focus before undo"); `
      + 'hs.eventtap.event.newKeyEvent({"cmd"}, "z", true):post(); '
      + 'hs.eventtap.event.newKeyEvent({}, "z", false):post()');
    try { await page.waitForFunction(({ id, original }) => {
      const el = document.getElementById(id); return (el.isContentEditable ? el.innerText : el.value) === original;
    }, { id, original }, { timeout: 2500 }); } catch (error) {
      console.error("Undo diagnostic:", call('return _translatorNativeCheck.status'), "Fixture value:", await valueOf(id));
      throw error;
    }
    assert.equal(await valueOf(id), original);
    passed++; console.log(`PASS ${id}: ${length ? "selected text" : "current logical line"}, paste and native Cmd+Z`);
  }
  await replace("single", "🙂机器学习", 3, 0, "🙂Machine learning", "🙂Machine learning");
  await replace("multi", "Keep\n  机器学习  \nKeep too", 8, 0, "  Machine learning  ", "Keep\n  Machine learning  \nKeep too");
  const wrap = "这是一行用于检查自动折行的中文文字，机器学习与人工智能都在这一行中。";
  await replace("multi", "Keep\n" + wrap + "\nKeep too", 18, 0, "A long translated logical line that also wraps across the narrow text field.",
    "Keep\nA long translated logical line that also wraps across the narrow text field.\nKeep too");
  await replace("multi", "🙂机器学习\n\n人工智能尾", 2, 10, "Machine learning\n\nAI", "🙂Machine learning\n\nAI尾");
  await replace("single", "前🙂机器学习后", 3, 4, "Machine learning", "前🙂Machine learning后");
  await replace("rich", "Keep\n机器学习\nKeep too", 7, 0, "Machine learning", "Keep\nMachine learning\nKeep too");
  await replace("rich", "🙂机器学习\n\n人工智能尾", 2, 10, "Machine learning\n\nAI", "🙂Machine learning\n\nAI尾");
  console.log(`${passed} native editor checks passed; translation response supplied by fixture.`);
} finally {
  try { call('_translatorNativeCheck:stop(); _translatorNativeCheck=nil'); } catch (error) { console.error(error.message); }
  if (context) await context.close();
  fs.rmSync(profile, { recursive: true, force: true });
  try { call('if _translatorNativePreviousApp then _translatorNativePreviousApp:activate() end; '
    + '_translatorNativePreviousApp=nil; _translatorNativeClipboard=nil; _translatorNativeElement=nil'); } catch (error) { console.error(error.message); }
}
