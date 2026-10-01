"""Run portable Lua tests; use Hammerspoon's bundled Lua when no Lua CLI exists."""
import ctypes
import os
from pathlib import Path
import shutil
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
script = root / 'tests/hammerspoon.test.lua'
cli = os.environ.get('LUA_EXECUTABLE') or shutil.which('lua') or shutil.which('lua5.4')
if cli:
    raise SystemExit(subprocess.run([cli, str(script)], cwd=root).returncode)
framework = Path(os.environ.get('HAMMERSPOON_LUA_LIBRARY',
    '/Applications/Hammerspoon.app/Contents/Frameworks/LuaSkin.framework/Versions/A/LuaSkin'))
if not framework.is_file():
    sys.exit('Lua 5.3+ or Hammerspoon is required for these tests; set LUA_EXECUTABLE if needed.')
lib = ctypes.CDLL(str(framework))
state_type = ctypes.c_void_p
lib.luaL_newstate.restype = state_type
lib.luaL_openlibs.argtypes = [state_type]
lib.luaL_loadfilex.argtypes = [state_type, ctypes.c_char_p, ctypes.c_char_p]
lib.lua_pcallk.argtypes = [state_type, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_longlong, ctypes.c_void_p]
lib.lua_tolstring.argtypes = [state_type, ctypes.c_int, ctypes.POINTER(ctypes.c_size_t)]
lib.lua_tolstring.restype = ctypes.c_char_p
lib.lua_close.argtypes = [state_type]
os.chdir(root)
state = lib.luaL_newstate()
if not state:
    sys.exit('Unable to create Lua state')
try:
    lib.luaL_openlibs(state)
    status = lib.luaL_loadfilex(state, os.fsencode(script), None)
    if status == 0:
        status = lib.lua_pcallk(state, 0, 0, 0, 0, None)
    if status:
        error = lib.lua_tolstring(state, -1, None)
        print(error.decode('utf-8', errors='replace') if error else 'Lua error', file=sys.stderr)
finally:
    lib.lua_close(state)
raise SystemExit(bool(status))
