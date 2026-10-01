-- Chinese -> English in the focused macOS text control. No configuration is
-- changed on require(); call new(options):start() explicitly.
local M = { version = "1.0.0" }
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
    undoModifiers = options.undoModifiers or { "ctrl", "alt", "shift" },
    undoKey = options.undoKey or "'",
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
  local role = read(element, "AXRole")
  if read(element, "AXSubrole") == "AXSecureTextField" or read(element, "AXProtectedContent") == true then
    return nil, "此文本框是受保护的输入框，未读取内容。"
  end
  if not element or (role ~= "AXTextField" and role ~= "AXTextArea" and role ~= "AXComboBox")
    or read(element, "AXEnabled") == false or read(element, "AXEditable") == false then
    return nil, "未找到可编辑文本框。可手动复制文字，再通过菜单翻译剪贴板。"
  end
  local value, selection = read(element, "AXValue"), read(element, "AXSelectedTextRange")
  if type(value) ~= "string" or not validRange(selection) then
    local selected = read(element, "AXSelectedText")
    if type(selected) == "string" and selected ~= "" then
      return { app = app, element = element, preview = true, original = selected,
        selection = selection, target = { text = selected, scope = "选中文字" }, epoch = self.epoch }
    end
    return nil, "无法准确读取文本和光标。请选中文字，或手动复制后通过菜单翻译剪贴板。"
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
  if read(api.axuielement.systemWideElement(), "AXFocusedUIElement") ~= snapshot.element then return false end
  if snapshot.preview then
    return read(snapshot.element, "AXSelectedText") == snapshot.original
      and ((snapshot.selection == nil and read(snapshot.element, "AXSelectedTextRange") == nil)
        or sameRange(read(snapshot.element, "AXSelectedTextRange"), snapshot.selection))
  end
  return read(snapshot.element, "AXValue") == snapshot.original
    and sameRange(read(snapshot.element, "AXSelectedTextRange"), snapshot.selection)
end

function Controller:clearWatch(snapshot)
  if not snapshot then return end
  stop(snapshot.poll); stop(snapshot.tap); stop(snapshot.observer)
  snapshot.poll, snapshot.tap, snapshot.observer = nil, nil, nil
end

function Controller:isUndoEvent(event)
  if event:getKeyCode() ~= self.hs.keycodes.map[self.undoKey] then return false end
  local flags, expected = event:getFlags(), {}
  for _, mod in ipairs(self.undoModifiers) do expected[mod] = true end
  for _, mod in ipairs({ "ctrl", "alt", "cmd", "shift" }) do
    if not not flags[mod] ~= not not expected[mod] then return false end
  end
  return true
end

function Controller:watch(snapshot, undo)
  local api = self.hs
  local types, props = api.eventtap.event.types, api.eventtap.event.properties
  local function invalidate()
    snapshot.dirty = true
    if undo then self:clearUndo() end
  end
  snapshot.tap = api.eventtap.new({ types.keyDown, types.leftMouseDown, types.rightMouseDown,
    types.otherMouseDown, types.leftMouseDragged, types.scrollWheel }, function(event)
    if event:getProperty(props.eventSourceUserData) == marker then return false end
    if undo and event:getType() == types.keyDown and self:isUndoEvent(event) then return false end
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
      observer:callback(function() invalidate() end)
      local registered = false
      for _, name in ipairs({ "AXValueChanged", "AXSelectedTextChanged" }) do
        if pcall(observer.addWatcher, observer, snapshot.element, name) then registered = true end
      end
      if registered then observer:start() end
    end
  end
  return true
end

function Controller:clearUndo()
  if self.undoRecord then
    self:clearWatch(self.undoRecord)
    stop(self.undoRecord.expiry)
  end
  self.undoRecord = nil
end

function Controller:cancel()
  self.epoch = self.epoch + 1
  local job = self.job
  self.job = nil
  if job then
    self:clearWatch(job.snapshot)
    stop(job.timeout); stop(job.waitTimer)
    if job.task then pcall(job.task.terminate, job.task) end
  end
  self:clearUndo()
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

function Controller:preview(text)
  local choice = self.hs.dialog.blockAlert("英文译文（未替换原文）", text, "复制译文", "关闭")
  if choice == "复制译文" then
    if self.hs.pasteboard.setContents(text) then self:notice("译文已复制，请自行粘贴。")
    else self:notice("无法写入剪贴板。") end
  end
end

function Controller:request(snapshot)
  local api = self.hs
  local err = validateTarget(snapshot.target.text)
  if err then self:notice(err); return end
  self:clearUndo()
  local job = { snapshot = snapshot }
  self.job = job
  if not self:watch(snapshot) then self:finish(job, "无法监听输入变化，请检查辅助功能权限。"); return end
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
      self:preview(translated)
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

function Controller:replace(job, translated, undo)
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
    self:clearWatch(snapshot)
    if not setRange(snapshot.element, { location = target.location, length = target.length }) then
      setRange(snapshot.element, snapshot.selection)
      self:finish(job, "此应用不支持准确设置选区，未替换。"); return
    end
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
    local current = api.application.frontmostApplication()
    if not current or current:pid() ~= snapshot.app:pid()
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
        api.eventtap.event.newKeyEvent({ "cmd" }, "v", down)
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
      local originalSelection = undo and undo.selection or nil
      if originalSelection then setRange(snapshot.element, originalSelection) end
      local selected = read(snapshot.element, "AXSelectedTextRange")
      self:finish(job)
      if undo then self:notice("已恢复原文。"); return end
      local record = { app = snapshot.app, element = snapshot.element, original = newValue,
        selection = selected, epoch = self.epoch,
        restoreSelection = snapshot.selection, restoreText = target.text,
        target = { location = target.location, length = Text.length(translated),
          startByte = target.startByte, endByte = target.startByte + #translated, text = translated } }
      if validRange(selected) and self:watch(record, true) then
        self.undoRecord = record
        record.expiry = api.timer.doAfter(12, function() if self.undoRecord == record then self:clearUndo() end end)
        self:notice("已翻译为英文，12 秒内可按恢复快捷键撤回。")
      else self:notice("已翻译为英文。此应用未提供可验证的恢复状态。") end
    end)
  end)
end

function Controller:undo()
  if self.job or self.pasting then self:notice("正在处理，请稍候。"); return end
  local record = self.undoRecord
  if not record or not self:unchanged(record) then
    self:clearUndo(); self:notice("没有可恢复的原文，或输入状态已经改变。"); return
  end
  self:clearWatch(record); stop(record.expiry); self.undoRecord = nil
  local job = { snapshot = record }
  self.job = job
  -- Restore only the region that was replaced, through the application's paste
  -- operation; never assign AXValue to rewrite an entire document.
  if not self:watch(record) then self:finish(job, "无法监听输入变化，未恢复。"); return end
  self:replace(job, record.restoreText, { selection = record.restoreSelection })
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
  self.undoHotkey = self.hs.hotkey.bind(self.undoModifiers, self.undoKey, nil, function() self:undo() end)
  if not self.translateHotkey or not self.undoHotkey then
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
  if self.undoHotkey then self.undoHotkey:delete() end
  if self.menu then self.menu:delete() end
  self.translateHotkey, self.undoHotkey, self.menu = nil, nil, nil
  return self
end

return M
