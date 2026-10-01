"""Install the independent module without replacing an existing init.lua."""
import argparse
from datetime import datetime
from pathlib import Path
import shutil
import re

BEGIN = '-- BEGIN keyword-translator (managed installation)'
END = '-- END keyword-translator (managed installation)'
BLOCK = '''
-- BEGIN keyword-translator (managed installation)
keywordTranslator = require("keyword_translator").new({
    translateModifiers = {"ctrl", "alt"},
    translateKey = "'",
}):start()
-- END keyword-translator (managed installation)
'''


def install(directory):
    source = Path(__file__).with_name('keyword_translator.lua')
    directory = Path(directory).expanduser()
    directory.mkdir(parents=True, exist_ok=True)
    init = directory / 'init.lua'
    module = directory / source.name
    original = init.read_bytes().decode('utf-8') if init.exists() else ''
    if (BEGIN in original) != (END in original):
        raise ValueError('Installation markers in init.lua are incomplete; nothing has been changed.')
    if BEGIN not in original and re.search(r'''require\s*\(?\s*['"]keyword_translator['"]''', original):
        raise ValueError('init.lua already loads this module outside the managed block; review that setup first.')
    stamp = datetime.now().strftime('%Y%m%d-%H%M%S-%f')
    changed = []
    if not module.exists() or module.read_bytes() != source.read_bytes():
        if module.exists():
            shutil.copy2(module, directory / (module.name + '.backup-' + stamp))
        shutil.copy2(source, module)
        changed.append(module)
    updated = original
    if BEGIN in original:
        start = original.index(BEGIN)
        end = original.index(END, start)
        block = original[start:end]
        # Remove only retired options inside our block; preserve user hotkeys
        # and all unrelated configuration byte-for-byte.
        block = re.sub(r"(?m)^[ \t]*undo(?:Modifiers|Key)[ \t]*=[^\r\n]*\r?\n", '', block)
        updated = original[:start] + block + original[end:]
    else:
        prefix = original if not original or original.endswith(('\n', '\r')) else original + '\n'
        updated = prefix + BLOCK
    if updated != original:
        if init.exists():
            shutil.copy2(init, directory / ('init.lua.backup-' + stamp))
        init.write_bytes(updated.encode('utf-8'))
        changed.append(init)
    return changed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=Path, default=Path.home() / '.hammerspoon')
    args = parser.parse_args()
    for path in install(args.directory):
        print('Updated:', path)
    print('Installation ready. In Hammerspoon, choose Reload Config.')
    print("Translate: Control + Option + '; undo with the application's Command + Z.")


if __name__ == '__main__':
    main()
