-- Translate selected text or the current line in macOS. No configuration is
-- changed on require(); call new(options):start() explicitly.
local M = { version = "1.2.1" }
local Text = {}
M.text = Text

local function whitespace(cp)
  return (cp >= 9 and cp <= 13) or cp == 32 or cp == 133 or cp == 160 or cp == 5760
    or (cp >= 8192 and cp <= 8202) or cp == 8232 or cp == 8233 or cp == 8239
    or cp == 8287 or cp == 12288 or cp == 65279
end

function Text.trimParts(value)
  local first, last
  for pos, cp in utf8.codes(value) do
    if not whitespace(cp) then first = first or pos; last = pos + #utf8.char(cp) - 1 end
  end
  if not first then return value, "", "" end
  return value:sub(1, first - 1), value:sub(first, last), value:sub(last + 1)
end

function Text.containsChinese(value)
  for _, cp in utf8.codes(value) do
    if (cp >= 0x3400 and cp <= 0x9FFF) or (cp >= 0xF900 and cp <= 0xFAFF)
      or (cp >= 0x20000 and cp <= 0x323AF) or (cp >= 0x2F800 and cp <= 0x2FA1F)
      or cp == 0x3005 or cp == 0x3007 or cp == 0x303B then return true end
  end
  return false
end

-- macOS AX ranges count UTF-16 code units; Lua strings count UTF-8 bytes.
-- Offsets inside a surrogate pair intentionally have no map entry.
function Text.offsets(value)
  local bytes, units, length = {}, {}, 0
  for pos, cp in utf8.codes(value) do
    bytes[length], units[pos] = pos, length
    length = length + (cp > 0xFFFF and 2 or 1)
  end
  bytes[length], units[#value + 1] = #value + 1, length
  return bytes, units, length
end

function Text.length(value)
  local _, _, length = Text.offsets(value)
  return length
end

local function validRange(range)
  return type(range) == "table" and math.type(range.location) == "integer"
    and math.type(range.length) == "integer" and range.location >= 0 and range.length >= 0
end

local function sameRange(a, b)
  return validRange(a) and validRange(b) and a.location == b.location and a.length == b.length
end

function Text.target(value, selection)
  if not validRange(selection) then return nil, "无法读取光标或选区，请先选中文字。" end
  local bytes, units = Text.offsets(value)
  local start, finish = bytes[selection.location], bytes[selection.location + selection.length]
  if not start or not finish then return nil, "文本与选区位置不一致，未修改内容。" end
  local scope = "选中文字"
  if selection.length == 0 then
    scope = "当前行"
    local caret, lineStart, cursor = start, 1, 1
    while true do
      local separator = value:find("[\r\n]", cursor)
      if not separator then start, finish = lineStart, #value + 1; break end
      local after = separator + (value:sub(separator, separator + 1) == "\r\n" and 2 or 1)
      if caret < after then start, finish = lineStart, separator; break end
      lineStart, cursor = after, after
    end
  end
  return {
    location = units[start], length = units[finish] - units[start],
    startByte = start, endByte = finish, text = value:sub(start, finish - 1), scope = scope
  }
end

local function lines(value)
  local result, breaks, cursor = {}, {}, 1
  while true do
    local pos = value:find("[\r\n]", cursor)
    if not pos then result[#result + 1] = value:sub(cursor); break end
    result[#result + 1] = value:sub(cursor, pos - 1)
    local separator = value:sub(pos, pos + 1) == "\r\n" and "\r\n" or value:sub(pos, pos)
    breaks[#breaks + 1], cursor = separator, pos + #separator
  end
  return result, breaks
end

function Text.format(original, translated)
  local leading, body, trailing = Text.trimParts(original)
  local _, translation = Text.trimParts(translated)
  local originals, separators = lines(body)
  local translations = lines(translation)
  if #originals ~= #translations then return nil, "译文换行与原文不一致，请缩小选区后重试。" end
  local output = {}
  for i, line in ipairs(originals) do
    local left, content, right = Text.trimParts(line)
    local _, replacement = Text.trimParts(translations[i])
    if content == "" then
      if replacement ~= "" then return nil, "译文空行与原文不一致，未替换。" end
      output[#output + 1] = line
    else
      if replacement == "" then return nil, "译文遗漏了原文中的行，未替换。" end
      output[#output + 1] = left .. replacement .. right
    end
    if separators[i] then output[#output + 1] = separators[i] end
  end
  return leading .. table.concat(output) .. trailing
end

function Text.translation(data, original)
  if type(data) ~= "table" or type(data[1]) ~= "table" or #data[1] == 0 then
    return nil, "翻译服务返回了无法识别的数据。"
  end
  local parts = {}
  for _, segment in ipairs(data[1]) do
    if type(segment) ~= "table" or type(segment[1]) ~= "string" then
      return nil, "翻译服务返回了不完整的数据。"
    end
    parts[#parts + 1] = segment[1]
  end
  local _, translation = Text.trimParts(table.concat(parts))
  if translation == "" then
    return nil, "翻译服务返回了空译文。"
  end
  return Text.format(original, translation)
end

local Services = {}
M.services = Services
Services.names = { google = "Google（免 Key）", deepl = "DeepL", libre = "LibreTranslate" }
Services.languages = {
  {code="zh",name="中文"}, {code="en",name="英文"}, {code="ja",name="日语"},
  {code="ko",name="韩语"}, {code="fr",name="法语"}, {code="de",name="德语"},
  {code="es",name="西班牙语"}, {code="ru",name="俄语"}, {code="it",name="意大利语"},
  {code="pt",name="葡萄牙语"}
}
local languageNames = { auto="自动检测" }
for _, lang in ipairs(Services.languages) do languageNames[lang.code]=lang.name end
local configKey = "keywordTranslator.translation"
local copyKey = "keywordTranslator.copyFallback"
local function isTerminal(app)
  local id=app and app:bundleID()
  return id=="com.apple.Terminal" or id=="com.googlecode.iterm2" or id=="com.mitchellh.ghostty"
    or id=="net.kovidgoyal.kitty" or id=="org.alacritty" or id=="dev.warp.Warp-Stable"
end
local function isTelegram(app)
  local id=app and app:bundleID()
  return id=="ru.keepcoder.Telegram" or id=="org.telegram.desktop" or id=="com.tdesktop.Telegram"
end
function Services.languageName(code) return languageNames[code] or code end
function Services.libreBase(url)
  if type(url)~="string" or #url>2048 or url:find('[%s%c"\\?#]') then return nil end
  local scheme,authority,path=url:match('^(https?)://([^/]+)(.*)$')
  if not scheme or authority:find('@',1,true) then return nil end
  local localHost=authority=='localhost' or authority:match('^localhost:%d+$')
    or authority=='127.0.0.1' or authority:match('^127%.0%.0%.1:%d+$')
    or authority=='[::1]' or authority:match('^%[::1%]:%d+$')
  if scheme=="http" and not localHost then return nil end
  if not authority:match('^[%w%.%-%[%]:]+$') then return nil end
  return scheme.."://"..authority..path:gsub('/+$','')
end
function Services.config(saved)
  saved=type(saved)=="table" and saved or {}
  return {provider=Services.names[saved.provider] and saved.provider or "google",
    source=type(saved.source)=="string" and (saved.source=="auto" or saved.source:match("^[a-z][a-z%-]*$")) and saved.source or "auto",
    target=type(saved.target)=="string" and saved.target~="auto" and saved.target:match("^[a-z][a-z%-]*$") and saved.target or "en",
    deeplPlan=saved.deeplPlan=="pro" and "pro" or "free",
    libreURL=Services.libreBase(saved.libreURL) or ""}
end
local function encode(value)
  return value:gsub("([^%w%-_%.~])",function(c) return string.format("%%%02X",string.byte(c)) end)
end
local function curlQuote(value)
  return '"'..value:gsub('\\','\\\\'):gsub('"','\\"'):gsub('\r','\\r'):gsub('\n','\\n')..'"'
end
function Services.build(config,text,key,jsonEncode)
  local _,source=Text.trimParts(text)
  local provider=config.provider
  if config.source==config.target then return nil,"源语言和目标语言相同，请修改设置。" end
  if provider=="google" then
    local url="https://translate.googleapis.com/translate_a/single?client=gtx&sl="..encode(config.source)
      .."&tl="..encode(config.target).."&dt=t&q="..encode(source)
    return {input="url = "..curlQuote(url).."\n",protocol="=https"}
  end
  if provider=="deepl" then
    if type(key)~="string" or key=="" then return nil,"请在服务设置中填写 DeepL API 密钥。" end
    if key:find('[%c]') then return nil,"API 密钥包含无效字符，请重新设置。" end
    local payload={text={source},target_lang=config.target=="zh" and "ZH-HANS" or config.target:upper(),preserve_formatting=true}
    if config.source~="auto" then payload.source_lang=config.source:upper() end
    local url=config.deeplPlan=="pro" and "https://api.deepl.com/v2/translate" or "https://api-free.deepl.com/v2/translate"
    return {input="url = "..curlQuote(url)..'\nrequest = "POST"\nheader = "Content-Type: application/json"\n'
      .."header = "..curlQuote("Authorization: DeepL-Auth-Key "..key).."\ndata = "..curlQuote(jsonEncode(payload)).."\n",protocol="=https"}
  end
  local base=Services.libreBase(config.libreURL)
  if not base then return nil,"请在服务设置中填写 LibreTranslate 服务地址。" end
  local body="q="..encode(source).."&source="..encode(config.source).."&target="..encode(config.target).."&format=text"
  if type(key)=="string" and key~="" then body=body.."&api_key="..encode(key) end
  return {input="url = "..curlQuote(base.."/translate")..'\nrequest = "POST"\nheader = "Content-Type: application/x-www-form-urlencoded"\ndata = '..curlQuote(body).."\n",
    protocol=base:sub(1,7)=="http://" and "=http" or "=https"}
end
function Services.result(provider,data,original)
  if provider=="google" then return Text.translation(data,original) end
  local translated
  if type(data)=="table" then
    if provider=="deepl" then
      local first=type(data.translations)=="table" and data.translations[1]
      translated=type(first)=="table" and first.text
    else translated=data.translatedText end
  end
  if type(translated)~="string" then return nil,"翻译服务返回了无法识别的数据。" end
  local _,body=Text.trimParts(translated)
  if body=="" then return nil,"翻译服务返回了空译文。" end
  return Text.format(original,translated)
end
function Services.credentialID(config)
  return config.provider=="libre" and "libre."..encode(config.libreURL) or config.provider
end
local function keyService(provider) return "keywordTranslator.api."..provider end
function Services.readKey(api,provider,callback)
  local task=api.task.new("/usr/bin/security",function(code,out)
    if code==0 then local key=out:gsub('[\r\n]+$',''); callback(key)
    elseif code==44 then callback("") else callback(nil,"无法读取钥匙串，请检查系统授权后重试。") end
  end,{"find-generic-password","-a","keyword-translator","-s",keyService(provider),"-w"})
  if not task or not task:start() then callback(nil,"无法读取钥匙串。"); return nil end
  return task
end
function Services.writeKey(api,provider,key,clear,callback)
  if clear then
    local task=api.task.new("/usr/bin/security",function(code) callback(code==0 or code==44) end,
      {"delete-generic-password","-a","keyword-translator","-s",keyService(provider)})
    if not task or not task:start() then callback(false); return nil end
    return task
  end
  -- Hex is sent through stdin to security's interactive parser, never argv or a shell.
  if type(key)~="string" or key=="" or key:find('[%c]') or #key>1024 then callback(false); return nil end
  local hex=key:gsub('.',function(c) return string.format('%02x',c:byte()) end)
  local task=api.task.new("/usr/bin/security",function(code,_,err)
    callback(code==0 and not (err or ""):find('SecKeychain'))
  end,{"-i"})
  if not task then callback(false); return nil end
  task:setInput('add-generic-password -U -a keyword-translator -s '..keyService(provider)..' -X '..hex..'\n')
  if not task:start() then callback(false); return nil end
  return task
end

local Controller = {}
Controller.__index = Controller
local marker = 19770401
local settingKey = "keywordTranslator.disabledApps"

local function read(element, name)
  if not element then return nil end
  local ok, value = pcall(element.attributeValue, element, name)
  if ok then return value end
end

local function parameter(element, name, argument)
  if not element or argument == nil then return nil end
  local ok, value = pcall(element.parameterizedAttributeValue, element, name, argument)
  if ok then return value end
end

local function selectedText(element)
  local selected = read(element, "AXSelectedText")
  if type(selected) == "string" and selected ~= "" then return selected end
  return parameter(element, "AXStringForTextMarkerRange", read(element, "AXSelectedTextMarkerRange"))
end

local function protected(element)
  return read(element, "AXSubrole") == "AXSecureTextField" or read(element, "AXProtectedContent") == true
end

local function selectionAnchor(api, element, range)
  local rect = parameter(element, "AXBoundsForTextMarkerRange", read(element, "AXSelectedTextMarkerRange"))
    or parameter(element, "AXBoundsForRange", range)
  if type(rect) == "table" and type(rect.x) == "number" and type(rect.y) == "number"
    and type(rect.w) == "number" and type(rect.h) == "number" then
    return { x = rect.x, y = rect.y, w = rect.w, h = rect.h }
  end
  local point = api.mouse.absolutePosition()
  return { x = point.x, y = point.y, w = 0, h = 0 }
end

function Text.previewFrame(anchor, screens)
  local screen = screens[1]
  local px, py = anchor.x + (anchor.w or 0) / 2, anchor.y + (anchor.h or 0) / 2
  for _, frame in ipairs(screens) do
    if px >= frame.x and px <= frame.x + frame.w and py >= frame.y and py <= frame.y + frame.h then
      screen = frame; break
    end
  end
  local width, height = math.min(480, screen.w - 24), math.min(300, screen.h - 24)
  local x, y = anchor.x, anchor.y + (anchor.h or 0) + 10
  if y + height > screen.y + screen.h - 12 then y = anchor.y - height - 10 end
  return { x = math.max(screen.x + 12, math.min(x, screen.x + screen.w - width - 12)),
    y = math.max(screen.y + 12, math.min(y, screen.y + screen.h - height - 12)), w = width, h = height }
end

function Text.previewHTML(text, hasOriginal)
  local escaped = text:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
  return [[<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
<title>译文</title><style>
:root{color-scheme:light dark;font-family:-apple-system,BlinkMacSystemFont,sans-serif;font-size:13px}
*{box-sizing:border-box}body{margin:0;padding:16px;height:100vh;display:flex;flex-direction:column;gap:10px;background:#f7f8fa;color:#20242a}
label{font-size:15px;font-weight:600}p{margin:0;color:#636b76;font-size:12px}
textarea{flex:1;min-height:70px;width:100%;resize:none;border:1px solid #cdd3dc;border-radius:8px;padding:12px;font:14px/1.55 -apple-system,BlinkMacSystemFont,sans-serif;background:#fff;color:#20242a}
textarea:focus{outline:2px solid #4979db;outline-offset:1px}footer{display:flex;align-items:center;gap:8px;flex-wrap:wrap}#status{flex:1;min-width:0;color:#636b76;font-size:12px}
button{flex-shrink:0;border:1px solid #cdd3dc;border-radius:7px;padding:7px 12px;background:#fff;color:inherit;font:inherit;cursor:pointer}button:disabled{opacity:.5;cursor:default}#copy{background:#3268cb;color:#fff;border-color:#3268cb}
@media(prefers-color-scheme:dark){body{background:#202328;color:#eceff3}p,#status{color:#aeb5c0}textarea,button{background:#2b3037;color:#eceff3;border-color:#505866}}
</style></head><body><label for="translation">译文</label><p>可直接修改；选中文字后按 Command + C 复制。</p>
<textarea id="translation" aria-label="译文" spellcheck="false">
]] .. escaped .. [[</textarea>
<footer><span id="status" role="status"></span><button id="close" type="button">关闭</button><button id="copy-original" type="button" ]] .. (hasOriginal and "" or "disabled") .. [[>复制原文</button><button id="copy" type="button">复制译文</button></footer>
<script>
const editor=document.getElementById('translation');
const send=(action)=>webkit.messageHandlers.keywordTranslatorPreview.postMessage({action,text:editor.value});
document.getElementById('copy').addEventListener('click',()=>send('copy'));
document.getElementById('copy-original').addEventListener('click',()=>send('copy-original'));
document.getElementById('close').addEventListener('click',()=>send('close'));
document.addEventListener('keydown',e=>{if(e.key==='Escape'){e.preventDefault();send('close')}});
editor.focus(); editor.setSelectionRange(0,0);
</script></body></html>]]
end

local function setRange(element, range)
  local ok, result = pcall(element.setAttributeValue, element, "AXSelectedTextRange", range)
  return ok and result ~= nil and sameRange(read(element, "AXSelectedTextRange"), range)
end

local function stop(resource)
  if resource then pcall(resource.stop, resource) end
end

function M.new(options, api)
  options = options or {}
  local self = setmetatable({
    hs = api or hs, options = options, enabled = true, running = false,
    translateModifiers = options.translateModifiers or { "ctrl", "alt" },
    translateKey = options.translateKey or "'",
    disabledApps = {}, copyFallback = {}, epoch = 0
  }, Controller)
  assert(self.hs, "This module requires Hammerspoon")
  local saved = self.hs.settings.get(settingKey)
  if type(saved) == "table" then
    for id, value in pairs(saved) do if type(id) == "string" and value == true then self.disabledApps[id] = true end end
  end
  self.config = Services.config(self.hs.settings.get(configKey))
  local copies = self.hs.settings.get(copyKey)
  if type(copies)=="table" then for id,value in pairs(copies) do
    if type(id)=="string" and type(value)=="boolean" then self.copyFallback[id]=value end
  end end
  return self
end

function Controller:notice(message)
  self.status = message
  if self.menu then self.menu:setTooltip("翻译：" .. message) end
  self.hs.alert.show(message, 3)
end

function Controller:allowed(app)
  local id = app and app:bundleID()
  return self.running and self.enabled and app and not self.disabledApps[id or ""]
end

-- Search only selected-text attributes, never entire message/document values.
local function findDocumentSelection(api,app)
  if not api.axuielement.applicationElement then return nil end
  local ok,root=pcall(api.axuielement.applicationElement,app)
  if not ok or not root then return nil end
  local function safe(element)
    local current=element
    for _=1,16 do
      if not current then return true end
      if protected(current) then return false end
      current=read(current,"AXParent")
    end
    return false
  end
  local point=api.mouse.absolutePosition()
  local hitOK,hit=pcall(root.elementAtPosition,root,point)
  if hitOK then
    for _=1,8 do
      if not hit then break end
      if safe(hit) then
        local text=selectedText(hit)
        if type(text)=="string" and text~="" then return hit,text end
      end
      hit=read(hit,"AXParent")
    end
  end
  local window=read(root,"AXFocusedWindow")
  local queue=window and {{window,0}} or {}
  local seen,index={},1
  local deadline=api.timer.secondsSinceEpoch()+0.2
  while index<=#queue and index<=160 and api.timer.secondsSinceEpoch()<=deadline do
    local node=queue[index]; index=index+1
    local element,depth=node[1],node[2]
    if not seen[element] then
      seen[element]=true
      if not protected(element) and safe(element) then
        local text=selectedText(element)
        if type(text)=="string" and text~="" then return element,text end
        if depth<7 then
          for _,child in ipairs(read(element,"AXChildren") or {}) do
            if #queue>=160 then break end
            queue[#queue+1]={child,depth+1}
          end
        end
      end
    end
  end
end

function Controller:copyAllowed(app)
  local configured=self.copyFallback[app:bundleID() or ""]
  if configured~=nil then return configured end
  return isTerminal(app) or isTelegram(app)
end

function Controller:copySelection(app)
  if self.job or self.pasting then self:notice("正在处理上一次操作，请稍候。"); return end
  local api=self.hs
  local front=api.application.frontmostApplication()
  if not app or not front or front:pid()~=app:pid() or not self:allowed(app) then self:notice("当前应用已改变、已禁用或翻译已暂停。"); return end
  if not api.accessibilityState() or api.eventtap.isSecureInputEnabled() then self:notice("无法读取受保护的输入状态。"); return end
  local focused=read(api.axuielement.systemWideElement(),"AXFocusedUIElement")
  local current=focused
  for _=1,16 do
    if not current then break end
    if protected(current) then self:notice("此控件受保护，未执行复制。"); return end
    current=read(current,"AXParent")
  end
  if current then self:notice("无法确认控件状态，未执行复制。"); return end
  local snapshot={app=app,focused=focused,copying=true,epoch=self.epoch}
  local job={snapshot=snapshot}; self.job=job
  if not self:watch(snapshot) then self:finish(job,"无法启动输入监听，未执行复制。"); return end
  self:notice("正在读取选中文字…")
  self:waitForModifiers(job,function()
    local items=api.pasteboard.allContentTypes()
    if #items>1 then self:finish(job,"剪贴板含多个项目，未执行复制读取。"); return end
    local count=api.pasteboard.changeCount()
    local saved=api.pasteboard.readAllData()
    if type(saved)~="table" or api.pasteboard.changeCount()~=count then self:finish(job,"无法备份剪贴板，未执行复制。"); return end
    for _,uti in ipairs(items[1] or {}) do
      if saved[uti]==nil then self:finish(job,"无法完整备份剪贴板，未执行复制。"); return end
    end
    local ownedCount
    job.cleanup=function()
      if ownedCount and api.pasteboard.changeCount()==ownedCount then
        if next(saved)==nil then
          -- clearContents() has no return value; verify the empty state instead.
          api.pasteboard.clearContents()
          return #api.pasteboard.allContentTypes()==0
        end
        return api.pasteboard.writeAllData(saved)
      end
      return false
    end
    if not self:unchanged(snapshot) then self:finish(job,"焦点已改变，未执行复制。"); return end
    local flags=api.eventtap.checkKeyboardModifiers()
    if flags.ctrl or flags.alt or flags.cmd or flags.shift then self:finish(job,"请松开修饰键后重试。"); return end
    local posted=pcall(function()
      for _,down in ipairs({true,false}) do
        api.eventtap.event.newKeyEvent(down and {"cmd"} or {},"c",down)
          :setProperty(api.eventtap.event.properties.eventSourceUserData,marker):post()
      end
    end)
    if not posted then self:finish(job,"此应用未接受复制，未读取旧剪贴板。"); return end
    local deadline=api.timer.secondsSinceEpoch()+0.7
    local function check()
      if self.job~=job then return end
      if not self:unchanged(snapshot) then self:finish(job,"读取期间输入或焦点已改变，已停止。"); return end
      local copiedCount=api.pasteboard.changeCount()
      if copiedCount~=count then
        ownedCount=copiedCount
        local text=api.pasteboard.getContents()
        if api.pasteboard.changeCount()~=ownedCount then self:finish(job,"剪贴板已改变，已停止。"); return end
        if type(text)~="string" or text=="" then self:finish(job,"未复制到文字，未读取旧剪贴板。"); return end
        local restored=job.cleanup(); job.cleanup=nil
        if not restored then self:finish(job,"无法恢复原剪贴板，未请求翻译。"); return end
        local restoredCount=api.pasteboard.changeCount()
        local anchor=selectionAnchor(api,nil,nil)
        self:finish(job)
        self:request({app=app,focused=focused,preview=true,copiedSelection=true,
          clipboardCount=restoredCount,epoch=self.epoch,anchor=anchor,original=text,
          target={text=text,scope="选中文字"}})
        return
      end
      if api.timer.secondsSinceEpoch()>=deadline then self:finish(job,"未复制到选中文字；此应用可能不支持复制。未读取旧剪贴板。"); return end
      job.waitTimer=api.timer.doAfter(0.03,check)
    end
    job.waitTimer=api.timer.doAfter(0.03,check)
  end)
end

function Controller:capture()
  local api = self.hs
  if not api.accessibilityState() then return nil, "请先为 Hammerspoon 授予辅助功能权限。" end
  if api.eventtap.isSecureInputEnabled() then return nil, "安全输入已开启，未读取或替换文本。" end
  local app = api.application.frontmostApplication()
  if not self:allowed(app) then return nil, "翻译已暂停，或当前应用已禁用。" end
  local element = read(api.axuielement.systemWideElement(), "AXFocusedUIElement")
  if not element then return nil, "无法读取选区。请先选中文字，或通过菜单翻译剪贴板。", "selection-unavailable" end
  -- Check ancestors before reading a selection from an outer document.
  local current, ancestors = element, {}
  for _ = 1, 8 do
    if not current then break end
    if protected(current) then return nil, "此文本框是受保护的输入框，未读取内容。" end
    ancestors[#ancestors + 1] = current
    current = read(current, "AXParent")
  end
  local role = read(element, "AXRole")
  local value, selection = read(element, "AXValue"), read(element, "AXSelectedTextRange")
  local editable = not isTerminal(app) and (role == "AXTextField" or role == "AXTextArea" or role == "AXComboBox")
    and read(element, "AXEnabled") ~= false and read(element, "AXEditable") ~= false
  if editable and element.isAttributeSettable then
    local ok, writable = pcall(element.isAttributeSettable, element, "AXValue")
    if ok and writable == false then editable = false end
  end
  if not editable or type(value) ~= "string" or not validRange(selection) or (isTelegram(app) and selection.length==0) then
    for _, owner in ipairs(ancestors) do
      local selected = selectedText(owner)
      if type(selected) == "string" and selected ~= "" then
        local range = read(owner, "AXSelectedTextRange")
        return { app = app, element = owner, focused = element, preview = true, original = selected,
          selection = range, anchor = selectionAnchor(api, owner, range),
          target = { text = selected, scope = "选中文字" }, epoch = self.epoch }
      end
    end
    local owner,selected=findDocumentSelection(api,app)
    if owner then
      local range=read(owner,"AXSelectedTextRange")
      return {app=app,element=owner,focused=element,preview=true,original=selected,
        selection=range,anchor=selectionAnchor(api,owner,range),target={text=selected,scope="选中文字"},epoch=self.epoch}
    end
    if not editable or type(value)~="string" or not validRange(selection) then
      return nil, "未找到选中文字或可编辑文本框。请先选中文字，或通过菜单翻译剪贴板。", "selection-unavailable"
    end
  end
  local target, err = Text.target(value, selection)
  if not target then return nil, err end
  return { app = app, element = element, original = value,
    selection = { location = selection.location, length = selection.length }, target = target, epoch = self.epoch }
end

function Controller:unchanged(snapshot)
  local api = self.hs
  if snapshot.dirty or snapshot.epoch ~= self.epoch or not self:allowed(snapshot.app)
    or not api.accessibilityState() or api.eventtap.isSecureInputEnabled() then return false end
  if snapshot.clipboard then return api.pasteboard.changeCount() == snapshot.clipboardCount end
  if snapshot.copying or snapshot.copiedSelection then
    local front=api.application.frontmostApplication()
    return front and front:pid()==snapshot.app:pid()
      and read(api.axuielement.systemWideElement(),"AXFocusedUIElement")==snapshot.focused
      and (snapshot.copying or api.pasteboard.changeCount()==snapshot.clipboardCount)
  end
  local app = api.application.frontmostApplication()
  if not app or app:pid() ~= snapshot.app:pid() then return false end
  if read(api.axuielement.systemWideElement(), "AXFocusedUIElement") ~= (snapshot.focused or snapshot.element) then return false end
  if snapshot.preview then
    return selectedText(snapshot.element) == snapshot.original
      and ((snapshot.selection == nil and read(snapshot.element, "AXSelectedTextRange") == nil)
        or sameRange(read(snapshot.element, "AXSelectedTextRange"), snapshot.selection))
  end
  local selection = read(snapshot.element, "AXSelectedTextRange")
  return read(snapshot.element, "AXValue") == snapshot.original
    and (sameRange(selection, snapshot.selection)
      or (snapshot.selecting and sameRange(selection, snapshot.target)))
end

function Controller:clearWatch(snapshot)
  if not snapshot then return end
  stop(snapshot.poll); stop(snapshot.tap); stop(snapshot.observer)
  snapshot.poll, snapshot.tap, snapshot.observer = nil, nil, nil
end

function Controller:watch(snapshot)
  local api = self.hs
  local types, props = api.eventtap.event.types, api.eventtap.event.properties
  local function invalidate()
    snapshot.dirty = true
  end
  snapshot.tap = api.eventtap.new({ types.keyDown, types.leftMouseDown, types.rightMouseDown,
    types.otherMouseDown, types.leftMouseDragged, types.scrollWheel }, function(event)
    if event:getProperty(props.eventSourceUserData) == marker then return false end
    invalidate()
    return false
  end):start()
  if not snapshot.tap:isEnabled() then
    self:clearWatch(snapshot)
    return false
  end
  snapshot.poll = api.timer.doEvery(0.1, function()
    if not self:unchanged(snapshot) then invalidate() end
  end)
  if snapshot.element and api.axuielement.observer then
    local ok, observer = pcall(api.axuielement.observer.new, snapshot.app:pid())
    if ok then
      snapshot.observer = observer
      observer:callback(function(_, _, notification)
        if snapshot.selecting and notification == "AXSelectedTextChanged" and self:unchanged(snapshot) then return end
        invalidate()
      end)
      local registered = false
      for _, name in ipairs({ "AXValueChanged", "AXSelectedTextChanged" }) do
        if pcall(observer.addWatcher, observer, snapshot.element, name) then registered = true end
      end
      if registered then observer:start() end
    end
  end
  return true
end

function Controller:cancel()
  self:closePreview()
  self.epoch = self.epoch + 1
  local job = self.job
  self.job = nil
  if job then
    self:clearWatch(job.snapshot)
    stop(job.timeout); stop(job.waitTimer)
    if job.task then pcall(job.task.terminate, job.task) end
    if job.cleanup then job.cleanup(); job.cleanup=nil end
  end
  -- A paste already dispatched must retain its clipboard until its verification
  -- timer fires; that timer also restores the clipboard after stop()/pause().
end

local function validateTarget(value)
  local _, body = Text.trimParts(value)
  if body == "" then return "目标为空，请输入或选中文字。" end
  if Text.length(value) > 2000 then return "待翻译文本超过 2000 个字符，请缩小选区。" end
end

function Controller:finish(job, message)
  if self.job ~= job then return end
  self.job = nil
  self:clearWatch(job.snapshot)
  stop(job.timeout); stop(job.waitTimer)
  if job.task then pcall(job.task.terminate, job.task) end
  if job.cleanup then job.cleanup(); job.cleanup=nil end
  if message then self:notice(message) end
end

function Controller:closePreview()
  local view, bridge = self.previewView, self.previewBridge
  self.previewView, self.previewBridge, self.previewFocused = nil, nil, false
  if bridge then bridge:setCallback(nil) end
  if view then view:windowCallback(nil); view:delete() end
end

function Controller:preview(text, snapshot)
  self:closePreview()
  local api = self.hs
  -- Keep the captured source in Lua, independent of later edits or clipboard changes.
  local original = snapshot and snapshot.target and snapshot.target.text
  local hasOriginal = type(original) == "string" and original ~= ""
  local anchor = snapshot and snapshot.anchor or selectionAnchor(api, nil, nil)
  local screens = {}
  for _, screen in ipairs(api.screen.allScreens()) do screens[#screens + 1] = screen:frame() end
  if #screens == 0 then self:notice("无法定位译文窗口。"); return end
  local bridge = api.webview.usercontent.new("keywordTranslatorPreview")
  local view = api.webview.new(Text.previewFrame(anchor, screens),
    { privateBrowsing = true, javaScriptCanOpenWindowsAutomatically = false }, bridge)
  if not view then bridge:setCallback(nil); self:notice("无法创建译文窗口。"); return end
  self.previewBridge, self.previewView = bridge, view
  bridge:setCallback(function(message)
    if self.previewView ~= view then return end
    local body = type(message) == "table" and message.body
    if type(body) ~= "table" then return end
    if body.action == "close" then self:closePreview(); return end
    if body.action == "copy-original" and hasOriginal then
      local copied = api.pasteboard.setContents(original)
      view:evaluateJavaScript("document.getElementById('status').textContent="
        .. (copied and "'原文已复制'" or "'原文复制失败，请重试'"))
      return
    end
    if body.action == "copy" and type(body.text) == "string" then
      local copied = api.pasteboard.setContents(body.text)
      view:evaluateJavaScript("document.getElementById('status').textContent="
        .. (copied and "'已复制'" or "'复制失败，请用 Command + C 重试'"))
    end
  end)
  view:windowStyle({ "titled", "closable", "resizable" }):windowTitle(Services.languageName((snapshot and snapshot.config or self.config).target).."译文")
    :allowTextEntry(true):allowNewWindows(false):deleteOnClose(true):closeOnEscape(true)
    :navigationCallback(function(action)
      if action == "didFinishNavigation" and self.previewView == view then
        view:show()
        view:evaluateJavaScript("document.getElementById('translation').focus()")
      end
    end)
    :windowCallback(function(action, _, state)
      if action == "focusChange" and self.previewView == view then self.previewFocused = state end
      if action == "closing" and self.previewView == view then
        self.previewView, self.previewBridge, self.previewFocused = nil, nil, false
        bridge:setCallback(nil)
      end
    end)
    :html(Text.previewHTML(text, hasOriginal))
  -- Activate the host before making this Cocoa window key. AX window focus can
  -- select Hammerspoon's console instead of its WebKit popup.
  local host = api.application.get("org.hammerspoon.Hammerspoon")
  if host then host:activate() end
  view:show():bringToFront()
  self.status = "译文已显示，可编辑并复制。"
  if self.menu then self.menu:setTooltip(self.status) end
end

function Controller:request(snapshot)
  local api = self.hs
  local err = validateTarget(snapshot.target.text)
  if err then self:notice(err); return end
  local config=Services.config(self.config)
  if config.source==config.target then self:notice("源语言和目标语言相同，请修改设置。"); return end
  if config.provider=="libre" and not self:languageSupported(config.source,config.target) then
    self:notice("请先刷新 LibreTranslate 语言列表并选择支持的语言。"); return
  end
  snapshot.config=config
  local job = { snapshot = snapshot, config=config }
  self.job = job
  if not self:watch(snapshot) then self:finish(job, "无法启动输入监听，未请求翻译。请查看 Hammerspoon Console 中的错误。"); return end
  self:notice("正在翻译" .. snapshot.target.scope .. "…")
  job.timeout = api.timer.doAfter(16, function() self:finish(job, "翻译超时，请重试。") end)
  local function submit(key,keyError)
    if self.job~=job then return end
    if keyError then self:finish(job,keyError); return end
    if not self:unchanged(snapshot) then self:finish(job,"文本、选区或焦点已改变，未请求翻译。"); return end
    local request,buildError=Services.build(config,snapshot.target.text,key,api.json.encode)
    if not request then self:finish(job,buildError); return end
    job.task = api.task.new("/usr/bin/curl", function(exitCode, stdout)
      if self.job ~= job then return end
      stop(job.timeout)
      if exitCode == 28 then self:finish(job, "翻译超时，请检查网络后重试。"); return end
      if exitCode ~= 0 then self:finish(job, "无法连接翻译服务，请检查网络后重试。"); return end
      local body, status = stdout:match("^(.*)\n(%d%d%d)$")
      status = tonumber(status)
      if status == 429 then self:finish(job, "翻译服务限流，请稍后重试。"); return end
      if status==401 or status==403 then self:finish(job,"服务认证失败，请检查 API 密钥及套餐。"); return end
      if status==456 then self:finish(job,"翻译服务额度已用完。"); return end
      if not status or status < 200 or status >= 300 then
        self:finish(job, "翻译服务暂时不可用（HTTP " .. tostring(status or "未知") .. "）。"); return
      end
      local ok, data = pcall(api.json.decode, body)
      local parsed, translated, formatError = false, nil, nil
      if ok then parsed, translated, formatError = pcall(Services.result, config.provider, data, snapshot.target.text) end
      if not parsed or not translated then
        self:finish(job, formatError or "翻译服务返回了无法识别的数据。"); return
      end
      if not self:unchanged(snapshot) then
        self:finish(job, "文本、选区或焦点已改变，未替换。请重新按快捷键。"); return
      end
      if not snapshot.preview and not snapshot.clipboard and translated==snapshot.target.text then
        self:finish(job,"译文与原文相同，无需替换。"); return
      end
      if snapshot.preview or snapshot.clipboard then
        self:finish(job)
        self:preview(translated, snapshot)
      else
        self:replace(job, translated)
      end
    end, { "--disable", "--silent", "--show-error", "--max-time", "12", "--connect-timeout", "5",
      "--proto", request.protocol, "--write-out", "\n%{http_code}", "--config", "-" })
    if not job.task then self:finish(job, "无法启动系统翻译请求。"); return end
    job.task:setInput(request.input)
    if not job.task:start() then self:finish(job, "无法启动系统翻译请求。") end
  end
  if config.provider=="google" then submit("")
  else job.task=Services.readKey(api,Services.credentialID(config),submit) end
end

function Controller:translate()
  if self.job or self.pasting then self:notice("正在处理上一次操作，请稍候。"); return end
  local ok, snapshot, err, reason = pcall(self.capture, self)
  if not ok then self:notice("无法读取此输入框，请重新聚焦后再试。"); return end
  if not snapshot then
    local app=self.hs.application.frontmostApplication()
    if reason=="selection-unavailable" and app and self:copyAllowed(app) then self:copySelection(app)
    else self:notice(err) end
    return
  end
  self:request(snapshot)
end

function Controller:translateClipboard()
  if self.job or self.pasting then self:notice("正在处理上一次操作，请稍候。"); return end
  local api, app = self.hs, self.hs.application.frontmostApplication()
  if not self:allowed(app) then self:notice("当前应用已禁用或翻译已暂停。"); return end
  local text = api.pasteboard.getContents()
  if type(text) ~= "string" then self:notice("剪贴板中没有可翻译的文字。"); return end
  self:request({ app = app, clipboard = true, clipboardCount = api.pasteboard.changeCount(),
    epoch = self.epoch, target = { text = text, scope = "剪贴板文字" } })
end

function Controller:waitForModifiers(job, callback)
  local deadline = self.hs.timer.secondsSinceEpoch() + 2
  local function check()
    if self.job ~= job then return end
    if not self:unchanged(job.snapshot) then self:finish(job, "输入状态已改变，未替换。"); return end
    local flags = self.hs.eventtap.checkKeyboardModifiers()
    if not flags.ctrl and not flags.alt and not flags.shift and not flags.cmd then callback(); return end
    if self.hs.timer.secondsSinceEpoch() >= deadline then self:finish(job, "请松开修饰键后重试。"); return end
    job.waitTimer = self.hs.timer.doAfter(0.05, check)
  end
  check()
end

-- Chromium accepts an AX write before its renderer updates the readable range.
-- While waiting, only the original and requested ranges are accepted. Input,
-- value and focus monitors remain active; our own range notification is ignored.
function Controller:selectTarget(job, callback)
  local api, snapshot = self.hs, job.snapshot
  local desired = { location = snapshot.target.location, length = snapshot.target.length }
  if sameRange(read(snapshot.element, "AXSelectedTextRange"), desired) then callback(); return end
  snapshot.selecting = true
  local ok, result = pcall(snapshot.element.setAttributeValue, snapshot.element, "AXSelectedTextRange", desired)
  if not ok or not result then
    self:finish(job, "此应用不支持设置选区，请先选中文字再翻译。"); return
  end
  local deadline = api.timer.secondsSinceEpoch() + 0.6
  local function check()
    if self.job ~= job then return end
    if not self:unchanged(snapshot) then
      self:finish(job, "设置选区期间输入或焦点已改变，未粘贴。"); return
    end
    if sameRange(read(snapshot.element, "AXSelectedTextRange"), desired) then callback(); return end
    if api.timer.secondsSinceEpoch() >= deadline then
      self:finish(job, "无法确认目标选区，请先选中文字再翻译；未粘贴。"); return
    end
    job.waitTimer = api.timer.doAfter(0.02, check)
  end
  check()
end

function Controller:replace(job, translated)
  job.config=job.config or self.config
  if isTerminal(job.snapshot.app) then
    local snapshot=job.snapshot; self:finish(job); self:preview(translated,snapshot); return
  end
  self:waitForModifiers(job, function()
    local api, snapshot = self.hs, job.snapshot
    local target = snapshot.target
    local newValue = snapshot.original:sub(1, target.startByte - 1) .. translated .. snapshot.original:sub(target.endByte)
    local items = api.pasteboard.allContentTypes()
    if #items > 1 then
      self:finish(job, "剪贴板含多个项目，未改动它或原文。请先复制一个普通文本项目再试。"); return
    end
    local count = api.pasteboard.changeCount()
    local saved = api.pasteboard.readAllData()
    if type(saved) ~= "table" then self:finish(job, "无法备份剪贴板，未替换。"); return end
    if api.pasteboard.changeCount() ~= count then
      self:finish(job, "备份期间剪贴板已改变，未替换。"); return
    end
    for _, uti in ipairs(items[1] or {}) do
      if saved[uti] == nil then self:finish(job, "无法完整备份剪贴板，未替换。"); return end
    end
    self:selectTarget(job, function()
      self:clearWatch(snapshot)
      if read(snapshot.element, "AXValue") ~= snapshot.original or api.pasteboard.changeCount() ~= count then
        setRange(snapshot.element, snapshot.selection)
        self:finish(job, "文本或剪贴板已改变，未替换。"); return
      end
      if not api.pasteboard.setContents(translated) then
        setRange(snapshot.element, snapshot.selection)
        self:finish(job, "无法写入剪贴板，未替换。"); return
      end
      local writtenCount = api.pasteboard.changeCount()
      local function restoreClipboard()
        if api.pasteboard.changeCount() == writtenCount then
          if next(saved) == nil then api.pasteboard.clearContents() else api.pasteboard.writeAllData(saved) end
        end
      end
      -- Check focus again after the potentially expensive clipboard backup.
      local flags = api.eventtap.checkKeyboardModifiers()
      local current = api.application.frontmostApplication()
      if flags.ctrl or flags.alt or flags.shift or flags.cmd or snapshot.dirty
        or not current or current:pid() ~= snapshot.app:pid()
        or read(api.axuielement.systemWideElement(), "AXFocusedUIElement") ~= snapshot.element
        or not self:allowed(snapshot.app) or snapshot.epoch ~= self.epoch
        or api.eventtap.isSecureInputEnabled()
        or read(snapshot.element, "AXValue") ~= snapshot.original
        or not sameRange(read(snapshot.element, "AXSelectedTextRange"), target)
        or api.pasteboard.changeCount() ~= writtenCount then
        restoreClipboard(); self:finish(job, "焦点已改变，未粘贴。"); return
      end
      self.pasting = true
      local posted = pcall(function()
        for _, down in ipairs({ true, false }) do
          api.eventtap.event.newKeyEvent(down and { "cmd" } or {}, "v", down)
            :setProperty(api.eventtap.event.properties.eventSourceUserData, marker):post()
        end
      end)
      -- No retry: an application may accept a paste asynchronously.
      job.verifyTimer = api.timer.doAfter(0.35, function()
        restoreClipboard()
        self.pasting = false
        if self.job ~= job then return end
        if not posted or read(snapshot.element, "AXValue") ~= newValue then
          self:finish(job, "无法确认粘贴结果，请检查输入框；未重复粘贴。"); return
        end
        self:finish(job)
        self:notice("已翻译为"..Services.languageName(job.config.target).."，可用 Command + Z 撤销。")
      end)
    end)
  end)
end

function Controller:toggleApplication(app)
  app = app or self.hs.application.frontmostApplication()
  local id = app and app:bundleID()
  if not id then self:notice("当前应用没有可保存的标识。"); return end
  local disabled = not self.disabledApps[id]
  local nextSettings = {}
  for key, value in pairs(self.disabledApps) do nextSettings[key] = value end
  nextSettings[id] = disabled or nil
  local ok = pcall(self.hs.settings.set, settingKey, nextSettings)
  if not ok then self:notice("无法保存应用设置。"); return end
  self.disabledApps = nextSettings
  self:cancel()
  self:notice((disabled and "已禁用：" or "已启用：") .. app:name())
end

local function htmlEscape(text)
  return text:gsub('&','&amp;'):gsub('<','&lt;'):gsub('>','&gt;'):gsub('"','&quot;')
end
function Text.settingsHTML(config)
  return [[<!doctype html><html lang="zh-CN"><meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
<style>:root{color-scheme:light dark;font:14px -apple-system,sans-serif}body{padding:16px;margin:0}label{display:block;margin:12px 0 6px}input,select{box-sizing:border-box;width:100%;padding:8px;font:inherit}input[type=checkbox]{width:auto}p{font-size:12px;color:#737b85}footer{display:flex;gap:10px;justify-content:flex-end;margin-top:20px}button{padding:8px 15px;font:inherit}#status{font-size:12px}</style>
<h3>翻译服务设置</h3><label for="provider">翻译服务</label><select id="provider"><option value="google">Google（免 Key）</option><option value="deepl">DeepL</option><option value="libre">LibreTranslate</option></select>
<section id="deepl"><label for="plan">DeepL API 套餐</label><select id="plan"><option value="free">API Free</option><option value="pro">API Pro</option></select></section>
<section id="libre"><label for="url">LibreTranslate 服务地址</label><input id="url" type="url" value="]]..htmlEscape(config.libreURL)..[[" placeholder="https://你的服务地址"><p>填写服务根地址。仅本机服务允许 http。</p></section>
<section id="credentials"><label for="key">API 密钥</label><input id="key" type="password" autocomplete="off" placeholder="留空保留已保存密钥"><p>密钥保存在 macOS 钥匙串。LibreTranslate 可不填。</p><label><input id="clear" type="checkbox"> 删除当前服务的已保存密钥</label></section>
<p>源语言和目标语言可在菜单栏中选择。</p><p id="status" role="status"></p><footer><button id="close">取消</button><button id="save">保存</button></footer>
<script>
const el=id=>document.getElementById(id),send=body=>webkit.messageHandlers.keywordTranslatorSettings.postMessage(body);
el('provider').value=']]..config.provider..[[';el('plan').value=']]..config.deeplPlan..[[';
// Existing keys are never inserted into this page.
function update(){const p=el('provider').value;el('deepl').hidden=p!=='deepl';el('libre').hidden=p!=='libre';el('credentials').hidden=p==='google';el('key').value='';el('clear').checked=false}
el('provider').addEventListener('change',update);update();
el('save').onclick=()=>{el('save').disabled=true;send({action:'save',provider:el('provider').value,deeplPlan:el('plan').value,libreURL:el('url').value,key:el('key').value,clear:el('clear').checked});el('key').value=''};
el('close').onclick=()=>send({action:'close'});
document.addEventListener('keydown',e=>{if(e.key==='Escape')send({action:'close'})});
</script></html>]]
end

function Controller:updateTitle()
  if self.menu then self.menu:setTitle((self.config.source=="auto" and "译" or self.config.source:upper()).."→"..self.config.target:upper()) end
end
function Controller:saveConfig(config)
  local ok=pcall(self.hs.settings.set,configKey,config)
  if not ok then self:notice("无法保存翻译设置。"); return false end
  self:cancel()
  if self.languageTask then self.languageTask:terminate();self.languageTask=nil end
  stop(self.languageTimer);self.languageTimer=nil;self.languageToken=nil
  self.config=config
  self:updateTitle()
  return true
end
function Controller:languageSupported(source,target)
  if self.config.provider~="libre" then return (source=="auto" or languageNames[source]) and languageNames[target]~=nil end
  local catalog=self.libreLanguages
  if not catalog then return false end
  for _,lang in ipairs(catalog) do
    if source=="auto" or source==lang.code then
      for _,code in ipairs(lang.targets) do if code==target then return true end end
    end
  end
  return false
end
function Controller:refreshLanguages()
  local api=self.hs
  if self.languageTask then self.languageTask:terminate(); self.languageTask=nil end
  stop(self.languageTimer); self.languageTimer=nil
  self.libreLanguages=nil
  local base=Services.libreBase(self.config.libreURL)
  if not base then self:notice("请先设置 LibreTranslate 服务地址。"); return end
  local token={}; self.languageToken=token
  self:notice("正在读取 LibreTranslate 支持的语言…")
  self.languageTask=api.task.new("/usr/bin/curl",function(code,out)
    if self.languageToken~=token or not self.running then return end
    self.languageTask=nil; stop(self.languageTimer); self.languageTimer=nil
    local body,status=out:match('^(.*)\n(%d%d%d)$')
    local ok,data=pcall(api.json.decode,body or "")
    if code~=0 or status~="200" or not ok or type(data)~="table" then self:notice("无法取得语言列表，请检查服务地址后刷新。"); return end
    local catalog={}
    for _,lang in ipairs(data) do
      if type(lang)=="table" and type(lang.code)=="string" and lang.code:match('^[a-z][a-z%-]*$') and type(lang.targets)=="table" then
        local targets={}
        for _,target in ipairs(lang.targets) do
          if type(target)=="string" and target:match('^[a-z][a-z%-]*$') then targets[#targets+1]=target end
        end
        if #targets>0 then catalog[#catalog+1]={code=lang.code,name=Services.languageName(lang.code),targets=targets} end
      end
    end
    if #catalog==0 then self:notice("服务没有返回可用的语言组合。"); return end
    self.libreLanguages=catalog
    local config=Services.config(self.config)
    if not self:languageSupported(config.source,config.target) then
      config.source="auto"
      config.target=self:languageSupported("auto","en") and "en" or catalog[1].targets[1]
      self:saveConfig(config)
    end
    self:notice("LibreTranslate 语言列表已更新。")
  end,{"--disable","--silent","--show-error","--max-time","5","--connect-timeout","3","--proto",base:sub(1,7)=="http://" and "=http" or "=https","--write-out","\n%{http_code}","--config","-"})
  if not self.languageTask then self:notice("无法读取语言列表。"); return end
  self.languageTask:setInput("url = "..curlQuote(base.."/languages").."\n")
  self.languageTimer=api.timer.doAfter(5.5,function()
    if self.languageToken==token then
      if self.languageTask then self.languageTask:terminate(); self.languageTask=nil end
      self.languageToken=nil; self:notice("读取语言列表超时。")
    end
  end)
  if not self.languageTask:start() then stop(self.languageTimer);self.languageTask=nil;self:notice("无法读取语言列表。") end
end
function Controller:selectProvider(provider)
  if not Services.names[provider] then return end
  local config=Services.config(self.config);config.provider=provider
  if provider~="libre" then
    if not languageNames[config.source] then config.source="auto" end
    if not languageNames[config.target] then config.target="en" end
  end
  if self:saveConfig(config) then
    if self.languageTask then self.languageTask:terminate();self.languageTask=nil end
    stop(self.languageTimer);self.languageToken=nil
    if provider=="libre" then self:refreshLanguages() end
  end
end
function Controller:setLanguage(which,code)
  local config=Services.config(self.config)
  config[which]=code
  if which=="source" and self.config.provider=="libre" and not self:languageSupported(code,config.target) then
    for _,lang in ipairs(self.libreLanguages or {}) do if lang.code==code then config.target=lang.targets[1];break end end
  end
  if self:languageSupported(config.source,config.target) then self:saveConfig(config) end
end
function Controller:closeSettings()
  local view,bridge=self.settingsView,self.settingsBridge
  self.settingsView,self.settingsBridge=nil,nil
  if self.settingsTask then self.settingsTask:terminate();self.settingsTask=nil end
  stop(self.settingsTimer);self.settingsTimer=nil
  if bridge then bridge:setCallback(nil) end
  if view then view:windowCallback(nil);view:delete() end
end
function Controller:showSettings()
  self:cancel();self:closeSettings()
  local api=self.hs
  local screens={};for _,screen in ipairs(api.screen.allScreens()) do screens[#screens+1]=screen:frame() end
  if #screens==0 then self:notice("无法定位设置窗口。");return end
  local frame=Text.previewFrame(selectionAnchor(api,nil,nil),screens)
  local screen=screens[1];for _,candidate in ipairs(screens) do
    if frame.x>=candidate.x and frame.x<candidate.x+candidate.w then screen=candidate;break end
  end
  frame.h=math.min(520,screen.h-24);frame.y=math.max(screen.y+12,math.min(frame.y,screen.y+screen.h-frame.h-12))
  local bridge=api.webview.usercontent.new("keywordTranslatorSettings")
  local view=api.webview.new(frame,{privateBrowsing=true,javaScriptCanOpenWindowsAutomatically=false},bridge)
  if not view then bridge:setCallback(nil);self:notice("无法创建设置窗口。");return end
  self.settingsView,self.settingsBridge=view,bridge
  local function status(message)
    if self.settingsView==view then view:evaluateJavaScript("document.getElementById('status').textContent=".."("..api.json.encode({message=message})..").message"..";document.getElementById('save').disabled=false") end
  end
  bridge:setCallback(function(message)
    if self.settingsView~=view then return end
    local body=type(message)=="table" and message.body
    if type(body)~="table" then return end
    if body.action=="close" then self:closeSettings();return end
    if body.action~="save" or self.settingsTask then return end
    if not Services.names[body.provider] then status("请选择支持的服务。");return end
    local config=Services.config(self.config)
    config.provider=body.provider;config.deeplPlan=body.deeplPlan=="pro" and "pro" or "free"
    config.libreURL=Services.libreBase(body.libreURL) or ""
    if config.provider=="libre" and config.libreURL=="" then status("请填写 HTTPS 服务地址，或本机 HTTP 地址。");return end
    local function commit(ok)
      if self.settingsView~=view then return end
      self.settingsTask=nil;stop(self.settingsTimer);self.settingsTimer=nil
      if not ok then status("无法保存密钥，请检查钥匙串后重试。");return end
      if not self:saveConfig(config) then status("无法保存设置。");return end
      self:closeSettings()
      if config.provider=="libre" then self:refreshLanguages() end
      self:notice("翻译服务设置已保存。")
    end
    if config.provider~="google" and (body.clear==true or (type(body.key)=="string" and body.key~="")) then
      self.settingsTimer=api.timer.doAfter(8,function()
        if self.settingsView==view then
          if self.settingsTask then self.settingsTask:terminate();self.settingsTask=nil end
          status("钥匙串操作超时，请重试。")
        end
      end)
      self.settingsTask=Services.writeKey(api,Services.credentialID(config),body.key,body.clear==true,commit)
    else commit(true) end
  end)
  view:windowStyle({"titled","closable"}):windowTitle("翻译服务设置"):allowTextEntry(true):allowNewWindows(false):deleteOnClose(true):closeOnEscape(true)
    :navigationCallback(function(action)
      if action=="didFinishNavigation" and self.settingsView==view then
        view:show():bringToFront();view:evaluateJavaScript("document.getElementById('provider').focus()")
      end
    end):windowCallback(function(action)
      if action=="closing" and self.settingsView==view then self:closeSettings() end
    end):html(Text.settingsHTML(self.config))
  local host=api.application.get("org.hammerspoon.Hammerspoon");if host then host:activate() end
  view:show():bringToFront()
end
function Controller:languageMenu(which)
  local result={}
  if which=="source" then result[#result+1]={title="自动检测",checked=self.config.source=="auto",fn=function() self:setLanguage("source","auto") end} end
  local languages=Services.languages
  if self.config.provider=="libre" then
    if not self.libreLanguages then return {{title="请先刷新服务语言列表",disabled=true}} end
    languages=self.libreLanguages
  end
  local added={}
  local function add(code,name)
    if added[code] then return end;added[code]=true
    result[#result+1]={title=name or Services.languageName(code),checked=self.config[which]==code,
      disabled=which=="target" and not self:languageSupported(self.config.source,code),fn=function() self:setLanguage(which,code) end}
  end
  for _,lang in ipairs(languages) do
    if which=="source" or self.config.provider~="libre" then add(lang.code,lang.name)
    else for _,code in ipairs(lang.targets) do add(code) end end
  end
  return result
end

function Controller:start()
  if self.running then return self end
  self.running = true
  self.translateHotkey = self.hs.hotkey.bind(self.translateModifiers, self.translateKey, nil, function() self:translate() end)
  if not self.translateHotkey then
    self:stop(); self:notice("无法注册快捷键，请修改配置或检查快捷键冲突。"); return self
  end
  self.menu = self.hs.menubar.new()
  if self.menu then
    self:updateTitle()
    self.menu:setMenu(function()
      local app = self.hs.application.frontmostApplication()
      local id = app and app:bundleID()
      return {
        { title = "翻译", disabled = true },
        { title = "源语言："..Services.languageName(self.config.source), menu=self:languageMenu("source") },
        { title = "目标语言："..Services.languageName(self.config.target), menu=self:languageMenu("target") },
        { title = "交换语言", disabled=self.config.source=="auto",fn=function()
          local config=Services.config(self.config);config.source,config.target=config.target,config.source
          if self:languageSupported(config.source,config.target) then self:saveConfig(config) else self:notice("当前服务不支持交换后的语言组合。") end
        end },
        { title = "翻译服务："..Services.names[self.config.provider], menu={
          {title=Services.names.google,checked=self.config.provider=="google",fn=function() self:selectProvider("google") end},
          {title=Services.names.deepl,checked=self.config.provider=="deepl",fn=function() self:selectProvider("deepl") end},
          {title=Services.names.libre,checked=self.config.provider=="libre",fn=function() self:selectProvider("libre") end}
        } },
        { title = "服务设置…", fn=function() self:showSettings() end },
        { title = "刷新 LibreTranslate 语言列表", disabled=self.config.provider~="libre",fn=function() self:refreshLanguages() end },
        { title = self.status or "就绪", disabled = true },
        { title = "-" },
        { title = "翻译剪贴板（仅预览）", fn = function() self:translateClipboard() end },
        { title = "复制选区并翻译（仅预览）", disabled=not app or not self:allowed(app), fn=function() self:copySelection(app) end },
        { title = "允许复制读取选区："..(app and app:name() or "当前应用"), checked=app and self:copyAllowed(app) or false,disabled=not id,fn=function()
          self.copyFallback[id]=not self:copyAllowed(app)
          local ok=pcall(self.hs.settings.set,copyKey,self.copyFallback)
          if not ok then self:notice("无法保存选区设置。") end
          self:cancel()
        end },
        { title = self.enabled and "暂停翻译" or "继续翻译", fn = function()
          self.enabled = not self.enabled; self:cancel(); self:notice(self.enabled and "翻译已启用。" or "翻译已暂停。")
        end },
        { title = (self.disabledApps[id or ""] and "启用：" or "禁用：") .. (app and app:name() or "当前应用"),
          disabled = not id, fn = function() self:toggleApplication(app) end }
      }
    end)
  end
  if self.config.provider=="libre" then self:refreshLanguages() end
  return self
end

function Controller:stop()
  self:cancel()
  self:closeSettings()
  if self.languageTask then self.languageTask:terminate();self.languageTask=nil end
  stop(self.languageTimer);self.languageTimer=nil;self.languageToken=nil
  self.running = false
  if self.translateHotkey then self.translateHotkey:delete() end
  if self.menu then self.menu:delete() end
  self.translateHotkey, self.menu = nil, nil
  return self
end

return M
