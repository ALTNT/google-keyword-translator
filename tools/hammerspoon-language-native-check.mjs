// Opt-in native language/settings/copy-fallback tests. Uses a local LibreTranslate
// fixture, temporary browser profile and in-memory settings; never sends user text.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import {spawnSync} from 'node:child_process';
import {createRequire} from 'node:module';
import {fileURLToPath} from 'node:url';
const require=createRequire(import.meta.url);
const {chromium}=require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const cli=process.env.HAMMERSPOON_CLI || '/Applications/Hammerspoon.app/Contents/Frameworks/hs/hs';
const source=fileURLToPath(new URL('../hammerspoon/keyword_translator.lua',import.meta.url));
const lua=value=>JSON.stringify(value);
function call(code){const result=spawnSync(cli,['-t','4','-c',code],{encoding:'utf8'});assert.equal(result.status,0,result.stderr||result.stdout);assert.ok(!/stack traceback|Error:/.test(result.stdout),result.stdout);return result.stdout.trim();}
assert.match(call('return hs.accessibilityState()'),/true$/);
const requests=[];
const server=http.createServer(async(req,res)=>{
  let body='';for await(const chunk of req) body+=chunk;
  res.setHeader('Content-Type','application/json');
  if(req.url==='/languages')res.end(JSON.stringify([{code:'en',name:'English',targets:['zh','ja']},{code:'zh',name:'Chinese',targets:['en']},{code:'ja',name:'Japanese',targets:['en']}]));
  else if(req.url==='/translate'){
    const form=new URLSearchParams(body);requests.push(Object.fromEntries(form));
    res.end(JSON.stringify({translatedText:form.get('target')==='zh'?'机器学习':'Machine learning'}));
  }else{res.statusCode=404;res.end('{}');}
});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
const endpoint=`http://127.0.0.1:${server.address().port}`;
const profile=fs.mkdtempSync(path.join(os.tmpdir(),'translator-language-native-'));
let context;
try{
  context=await chromium.launchPersistentContext(profile,{executablePath:process.env.BROWSER_EXECUTABLE,headless:false,viewport:{width:1000,height:650},args:['--force-renderer-accessibility']});
  const page=await context.newPage();
  await page.setContent('<title>Translator language native regression</title><meta charset="utf-8"><input id="input" value="Machine learning"><p id="text">Machine learning</p>');
  call('_ktLangPreviousApp=hs.application.frontmostApplication();assert(#hs.pasteboard.allContentTypes()<=1);_ktLangClipboard=hs.pasteboard.readAllData();_ktLangWrittenCount=hs.pasteboard.changeCount();'
    +'_ktLangSettings={};local api=setmetatable({settings={get=function(k)return _ktLangSettings[k] end,set=function(k,v)_ktLangSettings[k]=v;return true end},task={new=function(executable,cb,args) '
    +'if executable=="/usr/bin/security" then return {terminate=function()end,start=function()hs.timer.doAfter(0.02,function() cb(44,"","") end);return true end} end;return hs.task.new(executable,cb,args) end}}, {__index=hs});'
    +`_ktLang=dofile(${lua(source)}).new({},api);_ktLang.running=true;_ktLang:showSettings()`);
  async function web(script,view='settingsView'){
    call(`_ktLangWeb=nil;_ktLangWebError=nil;_ktLang.${view}:evaluateJavaScript(${lua(script)},function(r,e)_ktLangWeb=r;if e and e.code~=0 then _ktLangWebError=e end end)`);
    for(let i=0;i<30;i++){await page.waitForTimeout(60);if(/true$/.test(call('return _ktLangWeb~=nil or _ktLangWebError~=nil')))break;}
    return JSON.parse(call('assert(not _ktLangWebError,hs.inspect(_ktLangWebError));return hs.json.encode({value=_ktLangWeb})').split('\n').at(-1)).value;
  }
  async function ready(view,id){for(let i=0;i<25;i++){if(await web(`!!document.getElementById(${JSON.stringify(id)})`,view))return;await page.waitForTimeout(80);}assert.fail('window not ready');}
  async function until(code){for(let i=0;i<35;i++){await page.waitForTimeout(80);if(/true$/.test(call(`return ${code}`)))return;}assert.fail(call('return _ktLang.status'));}
  await ready('settingsView','save');
  assert.deepEqual(await web('({provider:document.getElementById("provider").value,key:document.getElementById("key").value})'),{provider:'google',key:''});
  await web(`document.getElementById('provider').value='libre';document.getElementById('provider').dispatchEvent(new Event('change'));document.getElementById('url').value='http://example.com';document.getElementById('save').click();true`);
  assert.match(await web('document.getElementById("status").textContent'),/HTTPS/);
  assert.equal(await web('document.getElementById("save").disabled'),false);
  await web(`document.getElementById('url').value=${JSON.stringify(endpoint)};document.getElementById('save').click();true`);
  await until('_ktLang.settingsView==nil and _ktLang.libreLanguages~=nil');
  assert.match(call('assert(_ktLang.config.provider=="libre");_ktLang:setLanguage("source","en");_ktLang:setLanguage("target","zh");assert(_ktLang.config.target=="zh");return true'),/true$/);
  console.log('PASS native settings form, URL validation, saving, real /languages transport and language pairs');
  async function front(){await page.bringToFront();call('for _,a in ipairs(hs.application.runningApplications()) do for _,w in ipairs(a:allWindows()) do if w:title():find("Translator language native regression",1,true) then a:activate();w:focus() end end end');await page.waitForTimeout(140);}
  await page.locator('#input').click();await page.locator('#input').evaluate(el=>el.setSelectionRange(0,el.value.length));await front();
  call('local s=assert(_ktLang:capture());assert(s.target.text=="Machine learning" and not s.preview);_ktLang:translate()');
  await page.waitForFunction(()=>document.getElementById('input').value==='机器学习',{},{timeout:2500});
  await until('_ktLang.job==nil and not _ktLang.pasting');
  assert.equal(requests.at(-1).source,'en');assert.equal(requests.at(-1).target,'zh');assert.equal(requests.at(-1).q,'Machine learning');
  call('local after=hs.pasteboard.readAllData();for k,v in pairs(_ktLangClipboard)do assert(after[k]==v)end;_ktLangWrittenCount=hs.pasteboard.changeCount();hs.eventtap.event.newKeyEvent({"cmd"},"z",true):post();hs.eventtap.event.newKeyEvent({},"z",false):post()');
  await page.waitForFunction(()=>document.getElementById('input').value==='Machine learning',{},{timeout:2500});
  console.log('PASS English→Chinese with native AX, real curl/form transport, clipboard restoration and Cmd+Z');
  await page.locator('#text').click();await page.locator('#text').evaluate(el=>{const r=document.createRange();r.selectNodeContents(el);const s=getSelection();s.removeAllRanges();s.addRange(r)});await front();
  // Model an app which provides no AX selection. Native Cmd+C and clipboard remain real.
  call('_ktLangNativeAX=_ktLang.hs.axuielement;_ktLang.hs.axuielement={systemWideElement=function() return {attributeValue=function()return nil end} end};_ktLang:copySelection(hs.application.frontmostApplication())');
  await until('_ktLang.previewView~=nil');await ready('previewView','translation');
  assert.equal(await web('document.getElementById("translation").value','previewView'),'机器学习');
  call('local after=hs.pasteboard.readAllData();for k,v in pairs(_ktLangClipboard)do assert(after[k]==v,"clipboard not restored")end;_ktLangWrittenCount=hs.pasteboard.changeCount()');
  await web('document.getElementById("copy-original").click();true','previewView');
  assert.match(call('assert(hs.pasteboard.getContents()=="Machine learning");_ktLangWrittenCount=hs.pasteboard.changeCount();return true'),/true$/);
  call('_ktLang:closePreview()');
  assert.equal(await page.locator('#text').textContent(),'Machine learning');
  console.log('PASS native copy fallback, local translation preview, original button and complete clipboard restoration');
  await page.locator('#text').click();await page.locator('#text').evaluate(el=>{const r=document.createRange();r.selectNodeContents(el);const s=getSelection();s.removeAllRanges();s.addRange(r)});await front();
  // clearContents has no return value: an initially empty clipboard must still
  // allow translation after native Cmd+C and restoration to the empty state.
  call('hs.pasteboard.clearContents();assert(#hs.pasteboard.allContentTypes()==0);_ktLangWrittenCount=hs.pasteboard.changeCount();_ktLang:copySelection(hs.application.frontmostApplication())');
  await until('_ktLang.previewView~=nil');await ready('previewView','translation');
  assert.equal(await web('document.getElementById("translation").value','previewView'),'机器学习');
  call('assert(#hs.pasteboard.allContentTypes()==0,"empty clipboard not restored");_ktLangWrittenCount=hs.pasteboard.changeCount();_ktLang:closePreview()');
  assert.equal(requests.at(-1).q,'Machine learning');
  assert.equal(await page.locator('#text').textContent(),'Machine learning');
  console.log('PASS initially empty clipboard restores correctly and native copy translation opens its preview');
  await page.evaluate(()=>document.addEventListener('copy',event=>event.preventDefault()));await page.locator('#text').click();await page.locator('#text').evaluate(el=>{const r=document.createRange();r.selectNodeContents(el);const s=getSelection();s.removeAllRanges();s.addRange(r)});await front();
  const before=requests.length;
  call('_ktLangNoCopyCount=hs.pasteboard.changeCount();_ktLang:copySelection(hs.application.frontmostApplication())');await until('_ktLang.job==nil');
  assert.equal(requests.length,before);
  assert.match(call('assert(_ktLang.previewView==nil);assert(hs.pasteboard.changeCount()==_ktLangNoCopyCount);return _ktLang.status'),/未复制到/);
  console.log('PASS failed copy does not translate stale clipboard or open a popup');
}finally{
  try{call('if _ktLang then _ktLang:stop() end;if _ktLangClipboard and hs.pasteboard.changeCount()==_ktLangWrittenCount then if next(_ktLangClipboard)==nil then hs.pasteboard.clearContents() else hs.pasteboard.writeAllData(_ktLangClipboard)end end;_ktLang=nil;_ktLangClipboard=nil;_ktLangSettings=nil;_ktLangWeb=nil;_ktLangWebError=nil');}catch(error){console.error(error.message);}
  if(context)await context.close();fs.rmSync(profile,{recursive:true,force:true});
  await new Promise(resolve=>server.close(resolve));
  try{call('if _ktLangPreviousApp then _ktLangPreviousApp:activate()end;_ktLangPreviousApp=nil');}catch(error){console.error(error.message);}
}
