// Opt-in native readonly-selection / editable-preview checks. Requires a trusted
// Hammerspoon with hs.ipc loaded and headed Playwright Chromium. Uses a temp profile.
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
assert.match(call("return hs.accessibilityState()"), /true$/);
const profile = fs.mkdtempSync(path.join(os.tmpdir(), "translator-preview-native-"));
let context;
try {
  context = await chromium.launchPersistentContext(profile, {
    executablePath: process.env.BROWSER_EXECUTABLE, headless: false,
    viewport: { width: 1000, height: 650 }, args: ["--force-renderer-accessibility"]
  });
  const page = await context.newPage();
  await page.setContent('<title>Keyword translator readonly regression</title><meta charset="utf-8">'
    + '<p id="text">前面 机器学习 后面</p><textarea readonly id="readonly">前面 机器学习 后面</textarea>');
  await page.evaluate(() => {
    window.blockedCopyEvents=0;
    document.addEventListener('copy', event => { window.blockedCopyEvents++; event.preventDefault(); });
  });
  // Supply only the translation response. All AX, timers, selection checks,
  // native WebKit, native keyboard editing and clipboard actions are real.
  call(`_previewNativePreviousApp=hs.application.frontmostApplication(); `
    + 'assert(#hs.pasteboard.allContentTypes()<=1,"copy tests need a single clipboard item"); '
    + '_previewNativeClipboard=hs.pasteboard.readAllData(); _previewNativeWrittenCount=hs.pasteboard.changeCount(); '
    + 'local api=setmetatable({task={new=function(_,callback) '
    + 'return {setInput=function() end,terminate=function() end,start=function() '
    + 'hs.timer.doAfter(0.08,function() callback(0,hs.json.encode({{{"Machine learning"}}}).."\\n200") end); return true end} end}}, {__index=hs}); '
    + `_previewNativeTest=dofile(${lua(source)}).new({},api); _previewNativeTest.running=true`);
  async function web(script) {
    call('_previewNativeWebResult=nil; _previewNativeWebError=nil; '
      + `_previewNativeTest.previewView:evaluateJavaScript(${lua(script)},function(r,e) _previewNativeWebResult=r; if e and e.code~=0 then _previewNativeWebError=e end end)`);
    for (let i=0;i<25;i++) {
      await page.waitForTimeout(80);
      if (/true$/.test(call('return _previewNativeWebResult~=nil or _previewNativeWebError~=nil'))) break;
    }
    const result = call('assert(not _previewNativeWebError,hs.inspect(_previewNativeWebError)); return hs.json.encode({value=_previewNativeWebResult})');
    return JSON.parse(result.split("\n").at(-1)).value;
  }
  async function readyView() {
    let state;
    for (let i=0;i<20;i++) {
      state=await web('({ready:!!document.getElementById("translation"),state:document.readyState})');
      if (state.ready) return;
      await page.waitForTimeout(100);
    }
    assert.fail(JSON.stringify(state));
  }
  for (const id of ["text", "readonly"]) {
    await page.locator(`#${id}`).click();
    await page.locator(`#${id}`).evaluate(el => {
      if (el.tagName === "TEXTAREA") { el.focus(); el.setSelectionRange(3, 7); }
      else { const r=document.createRange(); r.setStart(el.firstChild,3); r.setEnd(el.firstChild,7);
        const s=window.getSelection(); s.removeAllRanges(); s.addRange(r); }
    });
    await page.bringToFront();
    call('for _,a in ipairs(hs.application.runningApplications()) do for _,w in ipairs(a:allWindows()) do '
      + 'if w:title():find("Keyword translator readonly regression",1,true) then a:activate(); w:focus() end end end');
    await page.waitForTimeout(180);
    call('local s=assert(_previewNativeTest:capture()); assert(s.preview and s.original=="机器学习"); '
      + '_previewNativeBeforeCopy=hs.pasteboard.changeCount(); _previewNativeTest:translate()');
    await page.waitForTimeout(400);
    assert.match(call('assert(_previewNativeTest.previewView,_previewNativeTest.status); '
      + 'assert(hs.pasteboard.changeCount()==_previewNativeBeforeCopy); return true'), /true$/);
    await readyView();
    assert.deepEqual(await web('({value:document.getElementById("translation").value,editable:!document.getElementById("translation").readOnly})'),
      {value:"Machine learning",editable:true});
    // Use native keyboard input, only after verifying the exact owned textbox.
    assert.equal(await web('document.activeElement.id'), "translation");
    call('assert(hs.application.frontmostApplication():bundleID()=="org.hammerspoon.Hammerspoon"); '
      + 'assert(_previewNativeTest.previewFocused,"preview lost focus"); '
      + 'hs.eventtap.event.newKeyEvent({"cmd"},"a",true):post(); hs.eventtap.event.newKeyEvent({},"a",false):post(); '
      + 'hs.timer.doAfter(0.06,function() if _previewNativeTest.previewFocused and hs.application.frontmostApplication():bundleID()=="org.hammerspoon.Hammerspoon" then hs.eventtap.keyStrokes("Edited translation") end end)');
    await page.waitForTimeout(180);
    assert.equal(await web('document.getElementById("translation").value'), "Edited translation");
    call('assert(_previewNativeTest.previewFocused); '
      + 'hs.eventtap.event.newKeyEvent({"cmd"},"a",true):post(); hs.eventtap.event.newKeyEvent({},"a",false):post(); '
      + 'hs.eventtap.event.newKeyEvent({"cmd"},"c",true):post(); hs.eventtap.event.newKeyEvent({},"c",false):post(); '
      + 'hs.timer.doAfter(0.08,function() if hs.pasteboard.getContents()=="Edited translation" then _previewNativeWrittenCount=hs.pasteboard.changeCount() end end)');
    await page.waitForTimeout(180);
    assert.match(call('assert(hs.pasteboard.getContents()=="Edited translation"); return true'), /true$/);
    call('assert(_previewNativeTest.previewFocused); hs.eventtap.keyStrokes("Final translation")');
    await page.waitForTimeout(100);
    assert.equal(await web('document.getElementById("translation").value'), "Final translation");
    await web('document.getElementById("copy").click(); true');
    assert.match(call('assert(hs.pasteboard.getContents()=="Final translation"); '
      + '_previewNativeWrittenCount=hs.pasteboard.changeCount(); return true'), /true$/);
    assert.equal(await web('document.getElementById("status").textContent'), "已复制");
    assert.equal(await web('document.getElementById("copy-original").disabled'), false);
    await web('document.getElementById("copy-original").click(); true');
    assert.match(call('assert(hs.pasteboard.getContents()=="机器学习"); '
      + '_previewNativeWrittenCount=hs.pasteboard.changeCount(); return true'), /true$/);
    assert.equal(await web('document.getElementById("status").textContent'), "原文已复制");
    assert.equal(await web('document.getElementById("translation").value'), "Final translation");
    assert.equal(await page.evaluate(() => window.blockedCopyEvents), 0);
    const layout=await web('(()=>{const a=document.getElementById("copy-original").getBoundingClientRect();const b=document.getElementById("copy").getBoundingClientRect();return {fits:a.left>=0&&b.right<=innerWidth&&b.bottom<=innerHeight,overlap:a.right>b.left&&a.bottom>b.top}})()');
    assert.deepEqual(layout,{fits:true,overlap:false});
    assert.equal(await page.locator(`#${id}`).evaluate(el => el.value ?? el.textContent), "前面 机器学习 后面");
    call('_previewNativeTest.previewView:evaluateJavaScript(\'document.getElementById("close").click()\')');
    await page.waitForTimeout(100);
    assert.match(call('return _previewNativeTest.previewView==nil'), /true$/);
    console.log(`PASS ${id}: readonly AX selection, native editing, Cmd+C, translation/original buttons, copy-blocking page bypass, button layout and close`);
  }
  call('_previewNativeTest:preview("</textarea><img src=x onerror=\\\"window.injected=true\\\"> & 🙂")');
  await readyView();
  assert.equal(await web('document.querySelectorAll("img").length'), 0);
  assert.equal(await web('window.injected === true'), false);
  assert.equal(await web('document.getElementById("copy-original").disabled'), true);
  console.log("PASS preview safely displays literal markup");
  call('_previewNativeTest:preview("\\nFirst line\\n\\nSecond line\\n")');
  await readyView();
  assert.equal(await web('document.getElementById("translation").value'), "\nFirst line\n\nSecond line\n");
  console.log("PASS preview preserves leading, blank and trailing lines");
  const original=" \n中文🙂\r\n第二行\n ";
  // JSON string escapes are accepted for these UTF-8/LF/CR values in Lua literals.
  call(`_previewNativeTest:preview("English",{target={text=${lua(original)}}})`);
  await readyView();
  await web('document.getElementById("copy-original").click(); true');
  assert.match(call(`assert(hs.pasteboard.getContents()==${lua(original)}); _previewNativeWrittenCount=hs.pasteboard.changeCount(); return true`), /true$/);
  console.log("PASS original copy preserves whitespace, CRLF, multiple lines and emoji");
} finally {
  try {
    call('if _previewNativeTest then _previewNativeTest:stop(); _previewNativeTest=nil end; '
      + 'if _previewNativeClipboard and hs.pasteboard.changeCount()==_previewNativeWrittenCount then '
      + 'if next(_previewNativeClipboard)==nil then hs.pasteboard.clearContents() else hs.pasteboard.writeAllData(_previewNativeClipboard) end end; '
      + '_previewNativeClipboard=nil; _previewNativeWrittenCount=nil; _previewNativeBeforeCopy=nil; _previewNativeWebResult=nil; _previewNativeWebError=nil');
  } catch (error) { console.error(error.message); }
  if (context) await context.close();
  fs.rmSync(profile,{recursive:true,force:true});
  try { call('if _previewNativePreviousApp then _previewNativePreviousApp:activate() end; _previewNativePreviousApp=nil'); }
  catch (error) { console.error(error.message); }
}
