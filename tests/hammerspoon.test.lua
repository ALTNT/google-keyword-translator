local module = dofile("hammerspoon/keyword_translator.lua")
local Text = module.text
local count = 0
local function equal(actual, expected)
  assert(actual == expected, string.format("expected %s, got %s", tostring(expected), tostring(actual)))
end
local function test(name, fn)
  local ok, err = pcall(fn)
  if not ok then error(name .. ": " .. tostring(err), 0) end
  count = count + 1
  print("PASS " .. name)
end
local function clone(value)
  if type(value) ~= "table" then return value end
  local result = {}; for key, item in pairs(value) do result[key] = clone(item) end; return result
end
local function byteAt(text, unit)
  local offset = 0
  for pos, cp in utf8.codes(text) do
    if offset == unit then return pos end
    offset = offset + (cp > 65535 and 2 or 1)
  end
  assert(offset == unit, "invalid UTF-16 offset")
  return #text + 1
end

local function fixture(value, location, length, options)
  local s = { now = 0, timers = {}, taps = {}, observers = {}, alerts = {}, requests = {},
    data = { ["public.utf8-plain-text"] = "previous clipboard", ["public.rtf"] = "old rich data" },
    clipCount = 1, items = 1, modifiers = {}, secure = false, permission = true, pastes = 0,
    hotkeys = {}, settings = {}, previews = {}, previewChoice = "关闭" }
  local attrs = { AXValue = value, AXRole = "AXTextArea", AXEnabled = true,
    AXSelectedTextRange = { location = location or 0, length = length or 0 } }
  s.attrs = attrs
  s.app = { pid = function() return 42 end, bundleID = function() return s.bundleID or "org.test.Editor" end,
    name = function() return "Test Editor" end }
  s.front = s.app
  s.element = {
    attributeValue = function(_, name)
      if name == "AXSelectedText" then
        if s.selectedOnly then return s.selectedOnly end
        if type(attrs.AXValue) ~= "string" or not attrs.AXSelectedTextRange then return nil end
        local range = attrs.AXSelectedTextRange
        return attrs.AXValue:sub(byteAt(attrs.AXValue, range.location), byteAt(attrs.AXValue, range.location + range.length) - 1)
      end
      return clone(attrs[name])
    end,
    setAttributeValue = function(self, name, nextValue)
      s.rangeWrites = (s.rangeWrites or 0) + 1
      if s.denyRange then return nil, "unsupported" end
      if s.ignoreRange then return self end
      local function apply()
        attrs[name] = clone(nextValue)
        if s.clamp then attrs[name].location = 0 end
        s.notify("AXSelectedTextChanged")
      end
      if s.rangeDelay then s.api.timer.doAfter(s.rangeDelay, apply) else apply() end
      return self
    end
  }
  s.focus = s.element
  local function timer(delay, fn, interval)
    local resource = { at = s.now + delay, fn = fn, interval = interval, active = true }
    function resource:stop() self.active = false end
    s.timers[#s.timers + 1] = resource
    return resource
  end
  function s.advance(seconds)
    local finish = s.now + seconds
    while true do
      local nextTimer
      for _, item in ipairs(s.timers) do
        if item.active and item.at <= finish and (not nextTimer or item.at < nextTimer.at) then nextTimer = item end
      end
      if not nextTimer then break end
      s.now = nextTimer.at
      if nextTimer.interval then nextTimer.at = s.now + nextTimer.interval else nextTimer.active = false end
      nextTimer.fn()
    end
    s.now = finish
  end
  function s.emit(kind, flags, code, own)
    local event = { getType = function() return kind end, getKeyCode = function() return code or 0 end,
      getFlags = function() return flags or {} end, getProperty = function() return own and 19770401 or 0 end }
    local taps = {}; for _, tap in ipairs(s.taps) do taps[#taps + 1] = tap end
    for _, tap in ipairs(taps) do if tap.active then tap.fn(event) end end
  end
  function s.notify(notification)
    for _, observer in ipairs(s.observers) do if observer.active and observer.fn then observer.fn(observer, s.element, notification) end end
  end
  function s.clip(text)
    s.data = { ["public.utf8-plain-text"] = text }; s.clipCount = s.clipCount + 1
  end
  function s.respond(translated, status, exitCode)
    s.responseData = { { { translated } } }
    s.requests[#s.requests].callback(exitCode or 0, 'json\n' .. tostring(status or 200), "")
  end
  local types = { keyDown = 1, leftMouseDown = 2, rightMouseDown = 3,
    otherMouseDown = 4, leftMouseDragged = 5, scrollWheel = 6 }
  local api = {
    accessibilityState = function() return s.permission end,
    settings = { get = function(key) return clone(s.settings[key]) end, set = function(key, data) s.settings[key] = clone(data) end },
    alert = { show = function(message) s.alerts[#s.alerts + 1] = message end },
    timer = { doAfter = function(delay, fn) return timer(delay, fn) end,
      doEvery = function(delay, fn) return timer(delay, fn, delay) end, secondsSinceEpoch = function() return s.now end },
    keycodes = { map = { ["'"] = 39 } },
    application = { frontmostApplication = function() return s.front end },
    axuielement = {
      systemWideElement = function() return { attributeValue = function() return s.focus end } end,
      observer = { new = function()
        local observer = { active = false }
        function observer:callback(fn) self.fn = fn end
        function observer:addWatcher() if s.noObserver then error("unsupported") end; return self end
        function observer:start() self.active = true; return self end
        function observer:stop() self.active = false end
        s.observers[#s.observers + 1] = observer; return observer
      end }
    },
    eventtap = {
      isSecureInputEnabled = function() return s.secure end,
      checkKeyboardModifiers = function() return s.modifiers end,
      new = function(_, fn)
        local tap = { fn = fn }
        function tap:start() self.active = not s.denyTap; return self end
        function tap:isEnabled() return self.active end
        function tap:stop() self.active = false end
        s.taps[#s.taps + 1] = tap; return tap
      end,
      event = { types = types, properties = { eventSourceUserData = "userData" },
        newKeyEvent = function(mods, key, down)
          local event = {}
          function event:setProperty() self.own = true; return self end
          function event:post()
            if not down then equal(#mods, 0) end
            if down then
              s.emit(types.keyDown, { cmd = true }, 9, self.own)
              equal(key, "v"); s.pastes = s.pastes + 1
              if not s.rejectPaste then
                local range = attrs.AXSelectedTextRange
                local start = byteAt(attrs.AXValue, range.location)
                local finish = byteAt(attrs.AXValue, range.location + range.length)
                local replacement = s.data["public.utf8-plain-text"]
                attrs.AXValue = attrs.AXValue:sub(1, start - 1) .. replacement .. attrs.AXValue:sub(finish)
                attrs.AXSelectedTextRange = { location = range.location + Text.length(replacement), length = 0 }
                s.notify()
              end
            end
            return self
          end
          return event
        end }
    },
    pasteboard = {
      changeCount = function() return s.clipCount end,
      allContentTypes = function() local items = {}; for i = 1, s.items do items[i] = { "public.utf8-plain-text", "public.rtf" } end; return items end,
      readAllData = function()
        local data = clone(s.data)
        if s.changeDuringBackup then s.clip("new during backup") end
        if s.incompleteBackup then data["public.rtf"] = nil end
        return data
      end,
      setContents = function(text) if s.denyClipboard then return false end; s.clip(text); return true end,
      getContents = function() return s.data["public.utf8-plain-text"] end,
      clearContents = function() s.data = {}; s.clipCount = s.clipCount + 1; return true end,
      writeAllData = function(data) s.data = clone(data); s.clipCount = s.clipCount + 1; return true end
    },
    task = { new = function(executable, callback, args)
      equal(executable, "/usr/bin/curl"); equal(type(args), "table")
      local task = { callback = callback, args = args }
      function task:setInput(input) self.input = input; return self end
      function task:start() s.requests[#s.requests + 1] = self; return not s.taskStartFails end
      function task:terminate() self.terminated = true end
      return task
    end },
    json = { decode = function() if s.invalidJson then error("bad json") end; return s.responseData end },
    dialog = { blockAlert = function(_, text) s.previews[#s.previews + 1] = text; return s.previewChoice end },
    hotkey = { bind = function(mods, key, pressed, released)
      equal(pressed, nil)
      local keybind = { mods = mods, key = key, released = released }
      function keybind:delete() self.deleted = true end
      s.hotkeys[#s.hotkeys + 1] = keybind
      return keybind
    end },
    menubar = { new = function()
      local menu = {}
      function menu:setTitle(title) self.title = title end
      function menu:setTooltip(tooltip) self.tooltip = tooltip end
      function menu:setMenu(fn) self.fn = fn end
      function menu:delete() self.deleted = true end
      s.menu = menu; return menu
    end }
  }
  s.api = api
  s.controller = module.new(options, api):start()
  return s
end

test("UTF-16 selections handle Chinese, emoji and supplementary Han", function()
  equal(Text.length("🙂机器学习𠀀"), 8)
  local target = assert(Text.target("🙂机器学习𠀀", { location = 2, length = 4 }))
  equal(target.text, "机器学习"); equal(target.startByte, 5)
  assert(not Text.target("🙂中文", { location = 1, length = 1 }))
  assert(Text.containsChinese("𠀀"))
end)

test("current logical line handles LF, CRLF, CR, blank lines and end-of-field", function()
  local function line(value, caret) return assert(Text.target(value, { location = caret, length = 0 })).text end
  equal(line("第一行\n机器学习\n尾行", 4), "机器学习")
  equal(line("前行\r\n机器学习\r\n", 3), "前行")
  equal(line("前行\r\n机器学习\r\n", 4), "机器学习")
  equal(line("前行\r机器学习", 3), "机器学习")
  equal(line("\n中文\n", 0), ""); equal(line("\n中文\n", 4), "")
  equal(line("中文", 2), "中文")
end)

test("formatting preserves Unicode whitespace, indentation, blank lines and mixed separators", function()
  equal(assert(Text.format("　机器学习\r\n \r\n\t人工智能　\n", "Machine learning\n\nAI")), "　Machine learning\r\n \r\n\tAI　\n")
  assert(not Text.format("机器学习\n人工智能", "Machine learning AI"))
  assert(not Text.format("中文\n中文\n中文", "Chinese\n\nChinese"))
  assert(not Text.format("中文\n\n中文", "Chinese\nadded\nChinese"))
end)

test("partial selection preserves surrounding search syntax and clipboard formats", function()
  local s = fixture("site:example.com 机器学习 AND AI", 17, 4)
  s.controller:translate(); s.respond("Machine learning"); s.advance(0.4)
  equal(s.attrs.AXValue, "site:example.com Machine learning AND AI")
  equal(s.data["public.utf8-plain-text"], "previous clipboard"); equal(s.data["public.rtf"], "old rich data")
end)

test("current line replacement preserves other lines and indentation", function()
  local original = "Keep\n  机器学习  \nKeep too"
  local s = fixture(original, 8, 0)
  s.controller:translate(); s.respond("Machine learning"); s.advance(0.4)
  equal(s.attrs.AXValue, "Keep\n  Machine learning  \nKeep too")
end)

test("multi-line selected text preserves blank lines and Unicode surrounding content", function()
  local s = fixture("🙂机器学习\n\n人工智能尾", 2, 10)
  s.controller:translate(); s.respond("Machine learning\n\nAI"); s.advance(0.4)
  equal(s.attrs.AXValue, "🙂Machine learning\n\nAI尾")
end)

test("empty and English lines do not fall back to the entire field", function()
  for _, input in ipairs({ { "中文\n\n中文", 3 }, { "中文\nEnglish\n中文", 4 }, { "中文\n", 3 } }) do
    local s = fixture(input[1], input[2], 0)
    s.controller:translate(); equal(#s.requests, 0); equal(s.pastes, 0)
  end
end)

test("the limit applies to the target, allowing a short selection inside a large field", function()
  local s = fixture(string.rep("a", 3000) .. "中文", 3000, 2)
  s.controller:translate(); s.respond("Chinese"); s.advance(0.4)
  equal(s.attrs.AXValue, string.rep("a", 3000) .. "Chinese")
  local large = fixture(string.rep("中", 2001)); large.controller:translate(); equal(#large.requests, 0)
end)

test("the request has a deadline and sends encoded text through stdin, without shell or redirects", function()
  local s = fixture('中文 & # " $(test)')
  s.controller:translate()
  local task = s.requests[1]
  equal(task.args[1], "--disable")
  assert(task.input:find("%%26") and task.input:find("%%23") and task.input:find("%%22"))
  for _, arg in ipairs(task.args) do assert(not arg:find("中文", 1, true)); assert(arg ~= "--location") end
  s.advance(13); assert(task.terminated); equal(s.pastes, 0)
  task.callback(0, "json\n200"); equal(s.pastes, 0)
end)

test("HTTP, network and malformed response errors keep text and allow retry", function()
  for _, mode in ipairs({ "429", "503", "302", "network", "invalid", "unchanged", "partial", "lines" }) do
    local s = fixture("机器学习\n人工智能", 0, 9)
    s.controller:translate()
    if mode == "invalid" then s.invalidJson = true end
    s.respond(mode == "unchanged" and "机器学习\n人工智能" or mode == "partial" and "Machine 学习\nAI" or "Machine learning AI",
      tonumber(mode) or 200, mode == "network" and 7 or 0)
    equal(s.pastes, 0); equal(s.attrs.AXValue, "机器学习\n人工智能")
    s.invalidJson = false; s.controller:translate(); equal(#s.requests, 2)
  end
end)

test("typing cancels a pending response even if text is changed back", function()
  local s = fixture("中文")
  s.controller:translate()
  s.emit(1); s.attrs.AXValue = "modified"; s.attrs.AXValue = "中文"
  s.respond("Chinese"); s.advance(0.4); equal(s.pastes, 0)
end)

test("AX notifications detect programmatic edits that are reverted between polls", function()
  local s = fixture("中文")
  s.controller:translate(); s.notify(); s.respond("Chinese"); equal(s.pastes, 0)
end)

test("selection, focus and application changes cancel automatic replacement", function()
  for _, change in ipairs({ "selection", "focus", "app" }) do
    local s = fixture("中文")
    s.controller:translate()
    if change == "selection" then s.attrs.AXSelectedTextRange.location = 1 end
    if change == "focus" then s.focus = {} end
    if change == "app" then s.front = { pid = function() return 99 end } end
    s.respond("Chinese"); equal(s.pastes, 0)
  end
end)

test("mouse activity cancels a request and duplicate shortcuts never duplicate requests", function()
  local s = fixture("中文")
  s.controller:translate(); s.controller:translate(); equal(#s.requests, 1)
  s.emit(2); s.respond("Chinese"); equal(s.pastes, 0)
end)

test("paste waits for modifiers to be released and rechecks text before dispatch", function()
  local s = fixture("中文")
  s.modifiers.ctrl = true; s.controller:translate(); s.respond("Chinese"); equal(s.pastes, 0)
  s.modifiers = {}; s.advance(0.5); equal(s.attrs.AXValue, "Chinese")
  local changed = fixture("中文")
  changed.modifiers.alt = true; changed.controller:translate(); changed.respond("Chinese")
  changed.attrs.AXValue = "later"; changed.modifiers = {}; changed.advance(0.5); equal(changed.pastes, 0)
end)

test("clipboard restoration preserves a newer copy made after paste", function()
  local s = fixture("中文")
  s.controller:translate(); s.respond("Chinese"); s.clip("new user clipboard"); s.advance(0.4)
  equal(s.data["public.utf8-plain-text"], "new user clipboard")
end)

test("empty clipboard is restored and multi-item clipboard is left untouched", function()
  local s = fixture("中文"); s.data = {}; s.items = 0
  s.controller:translate(); s.respond("Chinese"); s.advance(0.4); equal(next(s.data), nil)
  local multi = fixture("中文"); multi.items = 2
  multi.controller:translate(); multi.respond("Chinese"); equal(multi.pastes, 0)
  equal(multi.data["public.rtf"], "old rich data"); equal(multi.attrs.AXValue, "中文")
end)

test("a manually selected range does not require writable AX selection", function()
  local s = fixture("前中文后", 1, 2); s.denyRange = true
  s.controller:translate(); s.respond("Chinese"); s.advance(0.4)
  equal(s.attrs.AXValue, "前Chinese后"); equal(s.rangeWrites, nil)
end)

test("asynchronous AX range writes are verified before pasting", function()
  local s = fixture("Keep\n  机器学习  \nKeep too", 8, 0); s.rangeDelay = 0.1
  s.controller:translate(); s.respond("Machine learning")
  equal(s.pastes, 0); equal(s.data["public.utf8-plain-text"], "previous clipboard")
  s.advance(0.5); equal(s.pastes, 1)
  equal(s.attrs.AXValue, "Keep\n  Machine learning  \nKeep too")
  equal(s.data["public.rtf"], "old rich data")
end)

test("rejected, clamped and ignored range writes do not paste", function()
  for _, flag in ipairs({ "denyRange", "clamp", "ignoreRange", "denyClipboard" }) do
    local s = fixture("Keep\n中文\nTail", 6, 0); s[flag] = true
    s.controller:translate(); s.respond("Chinese"); s.advance(1)
    equal(s.pastes, 0); equal(s.attrs.AXValue, "Keep\n中文\nTail")
    equal(s.data["public.utf8-plain-text"], "previous clipboard")
    equal(s.controller.job, nil)
  end
end)

test("input, focus, text, clipboard and modifier changes during selection wait prevent paste", function()
  for _, mode in ipairs({ "input", "focus", "text", "clipboard", "modifier", "stop", "selection", "reverted" }) do
    local s = fixture("中文", 1, 0); s.rangeDelay = 0.1
    s.controller:translate(); s.respond("Chinese")
    if mode == "input" then s.emit(1) end
    if mode == "focus" then s.focus = {} end
    if mode == "text" then s.attrs.AXValue = "Later" end
    if mode == "clipboard" then s.clip("New clipboard") end
    if mode == "modifier" then s.modifiers.ctrl = true end
    if mode == "stop" then s.controller:stop() end
    if mode == "selection" then s.attrs.AXSelectedTextRange = {location=0,length=0}; s.notify("AXSelectedTextChanged") end
    if mode == "reverted" then s.attrs.AXValue="Later"; s.notify("AXValueChanged"); s.attrs.AXValue="中文" end
    s.advance(1); equal(s.pastes, 0)
    equal(s.data["public.utf8-plain-text"], mode == "clipboard" and "New clipboard" or "previous clipboard")
  end
end)

test("a concurrent clipboard change or incomplete backup aborts before changing the selection", function()
  for _, flag in ipairs({ "changeDuringBackup", "incompleteBackup" }) do
    local s = fixture("前中文后", 1, 2); s[flag] = true
    s.controller:translate(); s.respond("Chinese")
    equal(s.pastes, 0); equal(s.attrs.AXValue, "前中文后")
    equal(s.attrs.AXSelectedTextRange.location, 1); equal(s.attrs.AXSelectedTextRange.length, 2)
    if flag == "changeDuringBackup" then equal(s.data["public.utf8-plain-text"], "new during backup") end
  end
end)

test("an unaccepted paste is not retried and restores the clipboard", function()
  local s = fixture("中文"); s.rejectPaste = true
  s.controller:translate(); s.respond("Chinese"); s.advance(1)
  equal(s.pastes, 1)
  equal(s.data["public.utf8-plain-text"], "previous clipboard")
end)

test("only the translation hotkey is registered; application undo remains available", function()
  local s = fixture("中文")
  equal(#s.hotkeys, 1)
  equal(s.hotkeys[1].key, "'")
  equal(s.hotkeys[1].mods[1], "ctrl"); equal(s.hotkeys[1].mods[2], "alt")
  equal(s.controller.undo, nil)
end)

test("secure input, protected fields, read-only controls and terminal applications do not send requests", function()
  for _, mode in ipairs({ "secure", "protected", "readonly", "terminal", "permission", "role" }) do
    local s = fixture("中文")
    if mode == "secure" then s.secure = true end
    if mode == "protected" then s.attrs.AXSubrole = "AXSecureTextField" end
    if mode == "readonly" then s.attrs.AXEditable = false end
    if mode == "terminal" then s.bundleID = "com.apple.Terminal" end
    if mode == "permission" then s.permission = false end
    if mode == "role" then s.attrs.AXRole = "AXButton" end
    s.controller:translate(); equal(#s.requests, 0)
  end
end)

test("unverifiable selected text produces a preview and never writes into the document", function()
  local s = fixture("ignored"); s.attrs.AXValue = nil; s.attrs.AXSelectedTextRange = nil; s.selectedOnly = "中文"
  s.controller:translate(); s.respond("Chinese")
  equal(s.pastes, 0); equal(s.previews[1], "Chinese"); equal(s.data["public.utf8-plain-text"], "previous clipboard")
end)

test("manual clipboard translation previews and copies only on explicit selection", function()
  local s = fixture("unused"); s.clip("中文"); s.previewChoice = "复制译文"
  s.controller:translateClipboard(); s.respond("Chinese")
  equal(s.previews[1], "Chinese"); equal(s.pastes, 0); equal(s.data["public.utf8-plain-text"], "Chinese")
  local changed = fixture("unused"); changed.clip("中文"); changed.controller:translateClipboard()
  changed.clip("new copy"); changed.respond("Chinese"); equal(#changed.previews, 0)
end)

test("disabling and re-enabling an application invalidates its outstanding request and persists only identifiers", function()
  local s = fixture("中文"); s.controller:translate()
  local pending = s.requests[1]
  s.controller:toggleApplication(); s.controller:translate(); equal(#s.requests, 1)
  equal(s.settings['keywordTranslator.disabledApps']['org.test.Editor'], true)
  s.controller:toggleApplication(); pending.callback(0, "json\n200"); equal(s.pastes, 0)
  equal(next(s.settings['keywordTranslator.disabledApps']), nil)
end)

test("stopping cancels requests, releases hotkeys, and finishes clipboard cleanup for an already posted paste", function()
  local s = fixture("中文"); s.controller:translate(); local pending = s.requests[1]
  s.controller:stop(); assert(pending.terminated); assert(s.hotkeys[1].deleted); assert(s.menu.deleted)
  pending.callback(0, "json\n200"); equal(s.pastes, 0)
  local pasted = fixture("中文"); pasted.controller:translate(); pasted.respond("Chinese")
  pasted.controller:stop(); pasted.advance(0.4)
  equal(pasted.data["public.utf8-plain-text"], "previous clipboard")
end)

test("unsupported input monitoring prevents translation requests instead of weakening guards", function()
  local s = fixture("中文"); s.denyTap = true; s.controller:translate(); equal(#s.requests, 0)
end)

print(count .. " Hammerspoon checks passed (mocked macOS/Hammerspoon APIs; " .. _VERSION .. ").")
