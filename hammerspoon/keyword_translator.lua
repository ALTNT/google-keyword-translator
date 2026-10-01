-- Chinese -> English in the focused macOS text control. No configuration is
-- changed on require(); call new(options):start() explicitly.
local M = { version = "1.1.1" }
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
  local _, source = Text.trimParts(original)
  if translation == "" or translation == source or Text.containsChinese(translation) then
    return nil, "未获得完整的英文译文，请调整文本后重试。"
  end
  return Text.format(original, translation)
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
<title>英文译文</title><style>
:root{color-scheme:light dark;font-family:-apple-system,BlinkMacSystemFont,sans-serif;font-size:13px}
*{box-sizing:border-box}body{margin:0;padding:16px;height:100vh;display:flex;flex-direction:column;gap:10px;background:#f7f8fa;color:#20242a}
label{font-size:15px;font-weight:600}p{margin:0;color:#636b76;font-size:12px}
textarea{flex:1;min-height:70px;width:100%;resize:none;border:1px solid #cdd3dc;border-radius:8px;padding:12px;font:14px/1.55 -apple-system,BlinkMacSystemFont,sans-serif;background:#fff;color:#20242a}
textarea:focus{outline:2px solid #4979db;outline-offset:1px}footer{display:flex;align-items:center;gap:8px;flex-wrap:wrap}#status{flex:1;min-width:0;color:#636b76;font-size:12px}
button{flex-shrink:0;border:1px solid #cdd3dc;border-radius:7px;padding:7px 12px;background:#fff;color:inherit;font:inherit;cursor:pointer}button:disabled{opacity:.5;cursor:default}#copy{background:#3268cb;color:#fff;border-color:#3268cb}
@media(prefers-color-scheme:dark){body{background:#202328;color:#eceff3}p,#status{color:#aeb5c0}textarea,button{background:#2b3037;color:#eceff3;border-color:#505866}}
</style></head><body><label for="translation">译文</label><p>可直接修改；选中文字后按 Command + C 复制。</p>
<textarea id="translation" aria-label="英文译文" spellcheck="false">
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
    disabledApps = {}, epoch = 0
  }, Controller)
  assert(self.hs, "This module requires Hammerspoon")
  local saved = self.hs.settings.get(settingKey)
  if type(saved) == "table" then
    for id, value in pairs(saved) do if type(id) == "string" and value == true then self.disabledApps[id] = true end end
  end
  return self
end

function Controller:notice(message)
  self.status = message
  if self.menu then self.menu:setTooltip("中文英译：" .. message) end
  self.hs.alert.show(message, 3)
end

function Controller:allowed(app)
  local id = app and app:bundleID()
  local terminal = id == "com.apple.Terminal" or id == "com.googlecode.iterm2"
  return self.running and self.enabled and app and not terminal and not self.disabledApps[id or ""]
end

function Controller:capture()
  local api = self.hs
  if not api.accessibilityState() then return nil, "请先为 Hammerspoon 授予辅助功能权限。" end
  if api.eventtap.isSecureInputEnabled() then return nil, "安全输入已开启，未读取或替换文本。" end
  local app = api.application.frontmostApplication()
  if not self:allowed(app) then return nil, "中文英译已暂停，或当前应用已禁用。" end
  local element = read(api.axuielement.systemWideElement(), "AXFocusedUIElement")
  if not element then return nil, "无法读取选区。请先选中文字，或通过菜单翻译剪贴板。" end
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
  local editable = (role == "AXTextField" or role == "AXTextArea" or role == "AXComboBox")
    and read(element, "AXEnabled") ~= false and read(element, "AXEditable") ~= false
  if editable and element.isAttributeSettable then
    local ok, writable = pcall(element.isAttributeSettable, element, "AXValue")
    if ok and writable == false then editable = false end
  end
  if not editable or type(value) ~= "string" or not validRange(selection) then
    for _, owner in ipairs(ancestors) do
      local selected = selectedText(owner)
      if type(selected) == "string" and selected ~= "" then
        local range = read(owner, "AXSelectedTextRange")
        return { app = app, element = owner, focused = element, preview = true, original = selected,
          selection = range, anchor = selectionAnchor(api, owner, range),
          target = { text = selected, scope = "选中文字" }, epoch = self.epoch }
      end
    end
    return nil, "未找到选中文字或可编辑文本框。请先选中文字，或通过菜单翻译剪贴板。"
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
  end
  -- A paste already dispatched must retain its clipboard until its verification
  -- timer fires; that timer also restores the clipboard after stop()/pause().
end

local function validateTarget(value)
  local _, body = Text.trimParts(value)
  if body == "" then return "目标为空，请输入或选中中文。" end
  if not Text.containsChinese(body) then return "目标中没有中文，未修改内容。" end
  if Text.length(value) > 2000 then return "待翻译文本超过 2000 个字符，请缩小选区。" end
end

function Controller:finish(job, message)
  if self.job ~= job then return end
  self.job = nil
  self:clearWatch(job.snapshot)
  stop(job.timeout); stop(job.waitTimer)
  if job.task then pcall(job.task.terminate, job.task) end
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
  view:windowStyle({ "titled", "closable", "resizable" }):windowTitle("英文译文")
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
  local job = { snapshot = snapshot }
  self.job = job
  if not self:watch(snapshot) then self:finish(job, "无法启动输入监听，未请求翻译。请查看 Hammerspoon Console 中的错误。"); return end
  self:notice("正在翻译" .. snapshot.target.scope .. "…")
  local _, source = Text.trimParts(snapshot.target.text)
  local encoded = source:gsub("([^%w%-_%.~])", function(c) return string.format("%%%02X", string.byte(c)) end)
  local url = "https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=en&dt=t&q=" .. encoded
  -- macOS's bundled curl: disable curlrc, no cookies, no redirects, bounded
  -- request. URL/text travel through stdin, never a shell or process arguments.
  job.task = api.task.new("/usr/bin/curl", function(exitCode, stdout)
    if self.job ~= job then return end
    stop(job.timeout)
    if exitCode == 28 then self:finish(job, "翻译超时，请检查网络后重试。"); return end
    if exitCode ~= 0 then self:finish(job, "无法连接 Google 翻译，请检查网络后重试。"); return end
    local body, status = stdout:match("^(.*)\n(%d%d%d)$")
    status = tonumber(status)
    if status == 429 then self:finish(job, "Google 翻译限流，请稍后重试。"); return end
    if not status or status < 200 or status >= 300 then
      self:finish(job, "翻译服务暂时不可用（HTTP " .. tostring(status or "未知") .. "）。"); return
    end
    local ok, data = pcall(api.json.decode, body)
    local parsed, translated, formatError = false, nil, nil
    if ok then parsed, translated, formatError = pcall(Text.translation, data, snapshot.target.text) end
    if not parsed or not translated then
      self:finish(job, formatError or "翻译服务返回了无法识别的数据。"); return
    end
    if not self:unchanged(snapshot) then
      self:finish(job, "文本、选区或焦点已改变，未替换。请重新按快捷键。"); return
    end
    if snapshot.preview or snapshot.clipboard then
      self:finish(job)
      self:preview(translated, snapshot)
    else
      self:replace(job, translated)
    end
  end, { "--disable", "--silent", "--show-error", "--max-time", "12", "--connect-timeout", "5",
    "--proto", "=https", "--write-out", "\n%{http_code}", "--config", "-" })
  if not job.task then self:finish(job, "无法启动系统翻译请求。"); return end
  job.task:setInput('url = "' .. url .. '"\n')
  job.timeout = api.timer.doAfter(12.5, function() self:finish(job, "翻译超时，请重试。") end)
  if not job.task:start() then self:finish(job, "无法启动系统翻译请求。") end
end

function Controller:translate()
  if self.job or self.pasting then self:notice("正在处理上一次操作，请稍候。"); return end
  local ok, snapshot, err = pcall(self.capture, self)
  if not ok then self:notice("无法读取此输入框，请重新聚焦后再试。"); return end
  if not snapshot then self:notice(err); return end
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
        self:notice("已翻译为英文，可用 Command + Z 撤销。")
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

function Controller:start()
  if self.running then return self end
  self.running = true
  self.translateHotkey = self.hs.hotkey.bind(self.translateModifiers, self.translateKey, nil, function() self:translate() end)
  if not self.translateHotkey then
    self:stop(); self:notice("无法注册快捷键，请修改配置或检查快捷键冲突。"); return self
  end
  self.menu = self.hs.menubar.new()
  if self.menu then
    self.menu:setTitle("中→EN")
    self.menu:setMenu(function()
      local app = self.hs.application.frontmostApplication()
      local id = app and app:bundleID()
      return {
        { title = "中文英译", disabled = true },
        { title = self.status or "就绪", disabled = true },
        { title = "-" },
        { title = "翻译剪贴板（仅预览）", fn = function() self:translateClipboard() end },
        { title = self.enabled and "暂停翻译" or "继续翻译", fn = function()
          self.enabled = not self.enabled; self:cancel(); self:notice(self.enabled and "翻译已启用。" or "翻译已暂停。")
        end },
        { title = (self.disabledApps[id or ""] and "启用：" or "禁用：") .. (app and app:name() or "当前应用"),
          disabled = not id, fn = function() self:toggleApplication(app) end }
      }
    end)
  end
  return self
end

function Controller:stop()
  self:cancel()
  self.running = false
  if self.translateHotkey then self.translateHotkey:delete() end
  if self.menu then self.menu:delete() end
  self.translateHotkey, self.menu = nil, nil
  return self
end

return M
