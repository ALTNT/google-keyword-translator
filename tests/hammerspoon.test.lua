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
    hotkeys = {}, settings = {}, previews = {}, views = {} }
  local attrs = { AXValue = value, AXRole = "AXTextArea", AXEnabled = true,
    AXSelectedTextRange = { location = location or 0, length = length or 0 } }
  s.attrs = attrs
  s.app = { pid = function() return 42 end, bundleID = function() return s.bundleID or "org.test.Editor" end,
    name = function() return "Test Editor" end }
  s.front = s.app
  s.element = {
    isAttributeSettable = function(_, name) if name == "AXValue" then return not s.readonly end; return not s.denyRange end,
    parameterizedAttributeValue = function(_, name)
      if name == "AXStringForTextMarkerRange" then return s.markerSelected end
      if name == "AXBoundsForRange" or name == "AXBoundsForTextMarkerRange" then return clone(s.bounds) end
    end,
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
    application = { frontmostApplication = function() return s.front end, get = function() return {activate=function() s.hostActivated=true end} end },
    axuielement = {
      applicationElement = function() return s.root end,
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
              if key=="c" then
                s.copies=(s.copies or 0)+1
                if s.copyText then s.clip(s.copyText) end
                return self
              end
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
      allContentTypes = function()
        if next(s.data)==nil then return {} end
        local types={};for uti in pairs(s.data) do types[#types+1]=uti end
        local items={};for i=1,s.items do items[i]=types end;return items
      end,
      readAllData = function()
        local data = clone(s.data)
        if s.changeDuringBackup then s.clip("new during backup") end
        if s.incompleteBackup then data["public.rtf"] = nil end
        return data
      end,
      setContents = function(text) if s.denyClipboard then return false end; s.clip(text); return true end,
      getContents = function() return s.data["public.utf8-plain-text"] end,
      clearContents = function()
        if s.denyClear then return end
        s.data = {}; s.clipCount = s.clipCount + 1
        -- Match Hammerspoon's actual no-return-value contract.
      end,
      writeAllData = function(data) s.data = clone(data); s.clipCount = s.clipCount + 1; return true end
    },
    task = { new = function(executable, callback, args)
      assert(executable=="/usr/bin/curl" or executable=="/usr/bin/security"); equal(type(args), "table")
      local task = { callback = callback, args = args }
      function task:setInput(input) self.input = input; return self end
      function task:start()
        if executable=="/usr/bin/security" then
          s.keyTasks=s.keyTasks or {};s.keyTasks[#s.keyTasks+1]=self
          timer(0.01,function() if not self.terminated then self.callback(s.keyExitCode or (s.secret and 0 or 44),s.secret or "","") end end)
        else s.requests[#s.requests + 1] = self end
        return not s.taskStartFails
      end
      function task:terminate() self.terminated = true end
      return task
    end },
    json = { encode = function(value) s.encoded=value; return '{"fixture":true}' end, decode = function() if s.invalidJson then error("bad json") end; return s.responseData end },
    mouse = { absolutePosition = function() return {x=300,y=200} end },
    screen = { allScreens = function() return { { frame = function() return {x=0,y=0,w=1200,h=800} end } } end },
    webview = {
      usercontent = { new = function(name)
        local bridge = {name=name}
        function bridge:setCallback(fn) self.fn=fn; return self end
        return bridge
      end },
      new = function(frame, prefs, bridge)
        local view = {frame=frame,prefs=prefs,bridge=bridge}
        for _, name in ipairs({"windowStyle","windowTitle","allowTextEntry","allowNewWindows","deleteOnClose","closeOnEscape"}) do
          view[name] = function(self, value) self[name .. "Value"] = value; return self end
        end
        function view:navigationCallback(fn) self.navigationFn=fn; return self end
        function view:windowCallback(fn) self.windowFn=fn; return self end
        function view:html(html)
          self.document=html
          local raw=html:match('<textarea[^>]*>\n(.-)</textarea>')
          if not raw then return self end
          local text=raw:gsub('&lt;','<'):gsub('&gt;','>'):gsub('&amp;','&')
          s.previews[#s.previews+1]=text
          return self
        end
        function view:show() self.shown=true; self.focused=true; if self.windowFn then self.windowFn("focusChange",self,true) end; return self end
        function view:bringToFront() self.front=true; return self end
        function view:hswindow() return {focus=function() self.focused=true end} end
        function view:evaluateJavaScript(script) self.script=script; return self end
        function view:delete() self.deleted=true; if self.windowFn then self.windowFn("closing",self) end end
        function view:send(action,text) if self.bridge.fn then self.bridge.fn({body={action=action,text=text}}) end end
        s.views[#s.views+1]=view
        return view
      end
    },
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

test("empty lines do not fall back to the entire field", function()
  for _, input in ipairs({ { "中文\n\n中文", 3 }, { "中文\n", 3 } }) do
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
  s.advance(17); assert(task.terminated); equal(s.pastes, 0)
  task.callback(0, "json\n200"); equal(s.pastes, 0)
end)

test("HTTP, network and malformed response errors keep text and allow retry", function()
  for _, mode in ipairs({ "429", "503", "302", "network", "invalid", "lines" }) do
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

test("secure input, protected fields and unselected read-only controls do not send requests", function()
  for _, mode in ipairs({ "secure", "protected", "readonly", "permission", "role" }) do
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
  local s = fixture("unused"); s.clip("中文")
  s.controller:translateClipboard(); s.respond("Chinese")
  equal(s.previews[1], "Chinese"); equal(s.pastes, 0)
  equal(s.data["public.utf8-plain-text"], "中文")
  s.views[1]:send("copy","Edited English")
  equal(s.data["public.utf8-plain-text"], "Edited English")
  s.views[1]:send("copy-original","spoofed source")
  equal(s.data["public.utf8-plain-text"], "中文")
  local changed = fixture("unused"); changed.clip("中文"); changed.controller:translateClipboard()
  changed.clip("new copy"); changed.respond("Chinese"); equal(#changed.previews, 0)
end)

test("read-only webpage and textarea selections open an editable preview, never paste", function()
  for _, role in ipairs({"AXWebArea","AXStaticText","AXTextArea"}) do
    local s = fixture("前面机器学习后面",2,4); s.attrs.AXRole=role; s.readonly=true
    s.controller:translate(); s.respond("Machine learning")
    equal(s.previews[1],"Machine learning"); equal(s.pastes,0); equal(s.rangeWrites,nil)
    equal(s.attrs.AXValue,"前面机器学习后面")
    equal(s.data["public.utf8-plain-text"],"previous clipboard")
    local view=s.views[1]
    assert(view.shown and view.focused and view.allowTextEntryValue)
    equal(view.allowNewWindowsValue,false); assert(view.prefs.privateBrowsing)
    view:send("copy","Edited translation")
    equal(s.data["public.utf8-plain-text"],"Edited translation")
    view:send("copy-original","Edited translation")
    equal(s.data["public.utf8-plain-text"],"机器学习")
  end
end)

test("read-only selection can come from an ancestor or a native text marker", function()
  for _, mode in ipairs({"ancestor","marker"}) do
    local s=fixture("ignored"); s.attrs.AXRole="AXGroup"; s.attrs.AXSelectedTextRange=nil
    if mode=="ancestor" then
      local parent={attributeValue=function(_,name) if name=="AXSelectedText" then return "机器学习" end end}
      s.attrs.AXParent=parent
    else s.attrs.AXSelectedTextMarkerRange={id=1}; s.markerSelected="机器学习" end
    s.controller:translate(); equal(#s.requests,1); s.respond("Machine learning")
    equal(s.previews[1],"Machine learning"); equal(s.pastes,0)
  end
end)

test("read-only previews still reject changed selections, focus and empty targets", function()
  for _, mode in ipairs({"selection","focus","empty"}) do
    local s=fixture(mode=="english" and "English" or "中文",0,mode=="empty" and 0 or 2)
    s.attrs.AXRole="AXWebArea"
    s.controller:translate()
    if mode=="empty" then equal(#s.requests,0)
    else
      if mode=="selection" then s.attrs.AXSelectedTextRange.length=1 else s.focus={} end
      s.respond("Chinese"); equal(#s.views,0)
    end
    equal(s.pastes,0)
  end
end)

test("protected ancestors are rejected before reading selected text", function()
  local s=fixture("中文",0,2); s.attrs.AXRole="AXGroup"
  s.attrs.AXParent={attributeValue=function(_,name) if name=="AXProtectedContent" then return true end end}
  s.controller:translate(); equal(#s.requests,0)
end)

test("preview stays on its monitor, including negative coordinates and screen edges", function()
  local screens={{x=0,y=0,w=1200,h=800},{x=-1000,y=0,w=1000,h=700}}
  local frame=Text.previewFrame({x=-20,y=650,w=5,h=15},screens)
  assert(frame.x>=-988 and frame.x+frame.w<=-12 and frame.y>=12 and frame.y+frame.h<=688)
  frame=Text.previewFrame({x=1190,y=790,w=0,h=0},screens)
  assert(frame.x>=12 and frame.x+frame.w<=1188 and frame.y>=12 and frame.y+frame.h<=788)
end)

test("translation text cannot inject executable markup into the preview", function()
  local html=Text.previewHTML('</textarea><img src=x onerror="attack()"> & 🙂')
  assert(html:find('&lt;/textarea&gt;&lt;img',1,true))
  assert(not html:find('<img',1,true)); assert(html:find('&amp;',1,true))
  assert(html:find("default-src 'none'",1,true))
end)

test("original copy preserves the captured source despite later edits and clipboard changes", function()
  local s=fixture("unused")
  local original=" \n中文🙂\r\n第二行\n "
  local snapshot={target={text=original}}
  s.controller:preview("English",snapshot)
  snapshot.target.text="changed selection"; s.clip("new clipboard")
  local view=s.views[1]
  assert(view.document:find('id="copy-original" type="button" >',1,true))
  view:send("copy-original","spoofed text")
  equal(s.data["public.utf8-plain-text"],original)
  assert(view.script:find("原文已复制",1,true))
  equal(s.pastes,0)
end)

test("missing source and failed original copy leave the clipboard unchanged", function()
  local s=fixture("unused"); s.controller:preview("English")
  assert(s.views[1].document:find('id="copy-original" type="button" disabled',1,true))
  s.views[1]:send("copy-original","unexpected")
  equal(s.data["public.utf8-plain-text"],"previous clipboard")
  s.controller:preview("English",{target={text="中文"}}); s.denyClipboard=true
  s.views[2]:send("copy-original","unexpected")
  equal(s.data["public.utf8-plain-text"],"previous clipboard")
  assert(s.views[2].script:find("原文复制失败，请重试",1,true))
end)

test("closing, replacing and stopping previews release windows and stale copy callbacks", function()
  local s=fixture("中文")
  s.controller:preview("First",{target={text="旧原文"}}); local first=s.views[1]; local stale=first.bridge.fn
  s.controller:preview("Second"); assert(first.deleted); equal(first.bridge.fn,nil)
  stale({body={action="copy",text="stale"}}); equal(s.data["public.utf8-plain-text"],"previous clipboard")
  stale({body={action="copy-original",text="stale"}}); equal(s.data["public.utf8-plain-text"],"previous clipboard")
  s.views[2]:send("close"); assert(s.views[2].deleted); equal(s.controller.previewView,nil)
  s.controller:preview("Third"); s.controller:stop(); assert(s.views[3].deleted)
  equal(s.views[3].bridge.fn,nil); equal(s.controller.previewView,nil)
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

test("English, Chinese and Japanese translate according to configured language direction", function()
  for _,item in ipairs({{"Machine learning","en","zh","机器学习"},{"机器学习","zh","ja","機械学習"},{"機械学習","ja","en","Machine learning"}}) do
    local s=fixture(item[1]); s.controller.config.source=item[2];s.controller.config.target=item[3]
    s.controller:translate();assert(s.requests[1].input:find("sl="..item[2],1,true));assert(s.requests[1].input:find("tl="..item[3],1,true))
    s.respond(item[4]);s.advance(0.4);equal(s.attrs.AXValue,item[4]);equal(s.pastes,1)
  end
  local s=fixture("English");s.controller.config.source="en";s.controller.config.target="en"
  s.controller:translate();equal(#s.requests,0)
end)

test("terminal selections always preview and unselected terminals never paste", function()
  for _,id in ipairs({"com.apple.Terminal","com.googlecode.iterm2","com.mitchellh.ghostty"}) do
    local s=fixture("English output",0,7);s.bundleID=id;s.controller.config.target="zh"
    s.controller:translate();s.respond("英文");equal(s.previews[1],"英文");equal(s.pastes,0);equal(s.rangeWrites,nil)
    local blank=fixture("命令行");blank.bundleID=id;blank.controller:translate();blank.advance(1)
    equal(#blank.requests,0);equal(blank.pastes,0);equal(blank.copies,1)
  end
end)

test("copy fallback captures a new selection, restores all clipboard formats and only previews", function()
  for _,id in ipairs({"com.apple.Terminal","com.tdesktop.Telegram","ru.keepcoder.Telegram"}) do
    local s=fixture("unused");s.bundleID=id;s.attrs.AXRole="AXGroup";s.copyText="选中文字"
    s.controller:translate();equal(s.copies,1);equal(#s.requests,0);s.advance(0.04)
    equal(s.data["public.utf8-plain-text"],"previous clipboard");equal(s.data["public.rtf"],"old rich data")
    equal(#s.requests,1);s.respond("Selected text")
    equal(s.previews[1],"Selected text");equal(s.pastes,0)
    s.views[1]:send("copy-original","untrusted");equal(s.data["public.utf8-plain-text"],"选中文字")
  end
end)

test("copy fallback restores an empty clipboard even though clearContents returns nothing", function()
  local s=fixture("unused");s.bundleID="com.tencent.xinWeChat";s.attrs.AXRole="AXGroup"
  s.data={};s.copyText="中文";s.controller.copyFallback[s.bundleID]=true
  s.controller:translate();s.advance(0.04)
  equal(next(s.data),nil);equal(#s.requests,1)
  s.respond("Chinese");equal(s.previews[1],"Chinese");equal(s.pastes,0)
  s.views[1]:send("copy-original","unexpected");equal(s.data["public.utf8-plain-text"],"中文")
end)

test("copy fallback still stops when clearing the old empty clipboard does not succeed", function()
  local s=fixture("unused");s.bundleID="com.tencent.xinWeChat";s.attrs.AXRole="AXGroup"
  s.data={};s.copyText="中文";s.denyClear=true;s.controller.copyFallback[s.bundleID]=true
  s.controller:translate();s.advance(0.04)
  equal(#s.requests,0);equal(s.pastes,0);equal(s.data["public.utf8-plain-text"],"中文")
  equal(s.controller.status,"无法恢复原剪贴板，未请求翻译。")
end)

test("copy fallback never translates a stale clipboard or overrides a new user copy", function()
  for _,mode in ipairs({"no-copy","empty","rich","focus","input","secure","protected","new-copy","backup"}) do
    local s=fixture("unused");s.bundleID="com.tdesktop.Telegram";s.attrs.AXRole="AXGroup"
    if mode~="no-copy" then s.copyText="中文" end
    if mode=="empty" then s.copyText="" end
    if mode=="rich" then s.items=2 end
    if mode=="secure" then s.secure=true end
    if mode=="protected" then s.attrs.AXProtectedContent=true end
    if mode=="backup" then s.incompleteBackup=true end
    s.controller:translate()
    if mode=="focus" then s.focus={} end
    if mode=="input" or mode=="new-copy" then s.emit(1) end
    if mode=="new-copy" then s.clip("user copied") end
    s.advance(1);equal(#s.requests,0);equal(s.pastes,0)
    if mode=="new-copy" then equal(s.data["public.utf8-plain-text"],"user copied") end
    if mode=="no-copy" then equal(s.data["public.utf8-plain-text"],"previous clipboard") end
  end
end)

test("copy fallback waits for shortcut release and honours per-application opt-out", function()
  local s=fixture("unused");s.bundleID="com.tdesktop.Telegram";s.attrs.AXRole="AXGroup";s.copyText="中文";s.modifiers={ctrl=true,alt=true}
  s.controller:translate();s.advance(0.1);equal(s.copies,nil)
  s.modifiers={};s.advance(0.1);equal(s.copies,1);equal(#s.requests,1)
  s.controller:cancel();s.controller.copyFallback[s.bundleID]=false;s.controller:translate();equal(s.copies,1)
end)

test("document selection search reads selected attributes outside the focused input", function()
  local s=fixture("");s.bundleID="com.tdesktop.Telegram"
  local selected={attributeValue=function(_,name) if name=="AXSelectedText" then return "中文消息" end end}
  local window={attributeValue=function(_,name) if name=="AXChildren" then return {selected} end end}
  s.root={attributeValue=function(_,name) if name=="AXFocusedWindow" then return window end end}
  local snapshot=assert(s.controller:capture());equal(snapshot.original,"中文消息");assert(snapshot.preview)
  s.controller:translate();s.respond("Message");equal(s.previews[1],"Message");equal(s.copies,nil)
end)

test("DeepL requests use the selected plan and keychain credentials only through stdin", function()
  local s=fixture("Machine learning");s.secret="fake:fx";s.controller.config={provider="deepl",source="en",target="zh",deeplPlan="free",libreURL=""}
  s.controller:translate();equal(#s.requests,0);s.advance(0.02)
  assert(s.requests[1].input:find('https://api-free.deepl.com/v2/translate',1,true))
  assert(s.requests[1].input:find('DeepL-Auth-Key fake:fx',1,true))
  equal(s.encoded.target_lang,"ZH-HANS");equal(s.encoded.source_lang,"EN");equal(s.encoded.text[1],"Machine learning")
  for _,arg in ipairs(s.requests[1].args) do assert(not arg:find("fake",1,true));assert(not arg:find("Machine",1,true)) end
  s.responseData={translations={{text="机器学习"}}};s.requests[1].callback(0,"json\n200");s.advance(0.4);equal(s.attrs.AXValue,"机器学习")
  local request=assert(module.services.build({provider="deepl",source="auto",target="en",deeplPlan="pro"},"中文","fake",s.api.json.encode))
  assert(request.input:find('https://api.deepl.com/v2/translate',1,true));equal(s.encoded.source_lang,nil)
end)

test("unchanged translation does not paste or alter application undo history", function()
  local s=fixture("English");s.controller:translate();s.respond("English");s.advance(0.4)
  equal(s.pastes,0);equal(s.attrs.AXValue,"English");equal(s.controller.job,nil)
end)

test("missing or denied credentials stop DeepL before any network request", function()
  for _,code in ipairs({44,51}) do
    local s=fixture("中文");s.controller.config.provider="deepl";s.keyExitCode=code
    s.controller:translate();s.advance(0.02);equal(#s.requests,0);equal(s.pastes,0)
  end
end)

test("LibreTranslate language metadata restricts available pairs and request direction", function()
  local s=fixture("English");s.controller.config.provider="libre";s.controller.config.libreURL="http://127.0.0.1:5000"
  s.controller:refreshLanguages();equal(#s.requests,1)
  assert(s.requests[1].input:find('/languages',1,true))
  s.responseData={{code="en",targets={"zh"}},{code="zh",targets={"en"}}};s.requests[1].callback(0,"json\n200")
  assert(s.controller:languageSupported("en","zh"));assert(not s.controller:languageSupported("en","ja"))
  s.controller:setLanguage("source","en");s.controller:setLanguage("target","zh")
  s.controller:translate();s.advance(0.02);equal(#s.requests,2)
  assert(s.requests[2].input:find('source=en&target=zh',1,true));assert(s.requests[2].input:find('/translate',1,true))
  s.responseData={translatedText="英文"};s.requests[2].callback(0,"json\n200");s.advance(0.4);equal(s.attrs.AXValue,"英文")
end)

test("service URLs reject insecure remote hosts, credentials and config injection", function()
  for _,url in ipairs({'http://example.com','http://localhost123','http://127.0.0.123','https://user:key@example.com','https://example.com?q=x','https://example.com\nheader=x','https://example.com/"x'}) do
    equal(module.services.libreBase(url),nil)
  end
  equal(module.services.libreBase('http://localhost:5000/api/'),'http://localhost:5000/api')
  equal(module.services.libreBase('https://example.com/api/'),'https://example.com/api')
  local s=fixture("中文");s.controller:selectProvider("libre");s.controller:translate();equal(#s.requests,0)
end)

test("LibreTranslate credentials are scoped to the exact configured endpoint", function()
  local a=module.services.credentialID({provider="libre",libreURL="https://one.example"})
  local b=module.services.credentialID({provider="libre",libreURL="https://two.example"})
  assert(a~=b);assert(not a:find(" ",1,true));equal(module.services.credentialID({provider="deepl"}),"deepl")
end)

test("service settings save secrets through keychain stdin, not settings or process argv", function()
  local s=fixture("中文");s.keyExitCode=0;s.controller:showSettings()
  local view=s.controller.settingsView
  view.bridge.fn({body={action="save",provider="deepl",deeplPlan="pro",libreURL="",key="fake secret",clear=false}})
  equal(#s.keyTasks,1);assert(s.keyTasks[1].input:find('-X 66616b6520736563726574',1,true))
  for _,arg in ipairs(s.keyTasks[1].args) do assert(not arg:find("fake",1,true)) end
  s.advance(0.02);equal(s.controller.config.provider,"deepl");equal(s.controller.config.deeplPlan,"pro")
  equal(s.settings['keywordTranslator.translation'].key,nil);assert(view.deleted)
  local restored=module.new({},s.api);equal(restored.config.provider,"deepl");equal(restored.config.deeplPlan,"pro")
end)

test("settings reject invalid URLs and stopping releases pending keychain and metadata tasks", function()
  local s=fixture("中文");s.controller:showSettings();local view=s.controller.settingsView
  view.bridge.fn({body={action="save",provider="libre",libreURL="http://example.com",key=""}})
  equal(s.controller.config.provider,"google");equal(s.settings['keywordTranslator.translation'],nil)
  view.bridge.fn({body={action="save",provider="deepl",key="fake"}})
  s.controller:stop();assert(view.deleted);assert(s.keyTasks[1].terminated);s.advance(1);equal(s.controller.config.provider,"google")
end)

test("changing settings cancels outstanding translation without changing text", function()
  local s=fixture("中文");s.controller:translate();local task=s.requests[1]
  s.controller:setLanguage("target","zh");assert(task.terminated)
  s.respond("Chinese");s.advance(0.4);equal(s.pastes,0)
  equal(s.settings['keywordTranslator.translation'].target,"zh")
end)

print(count .. " Hammerspoon checks passed (mocked macOS/Hammerspoon APIs; " .. _VERSION .. ").")
