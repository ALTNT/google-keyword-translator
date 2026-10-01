import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import test from "node:test";

const installer = new URL("../hammerspoon/install.py", import.meta.url);
test("Hammerspoon installation preserves existing config, backs it up and is idempotent", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "keyword-translator-install-"));
  try {
    const original = 'require("existing_module")\r\n-- existing settings\r\n\r\n';
    fs.writeFileSync(path.join(dir, "init.lua"), original);
    fs.writeFileSync(path.join(dir, "keyword_translator.lua"), "old version\n");
    const run = () => spawnSync(process.env.PYTHON_EXECUTABLE || "python3",
      [fileURLToPath(installer), "--directory", dir], { encoding: "utf8" });
    const first = run();
    assert.equal(first.status, 0, first.stderr);
    const config = fs.readFileSync(path.join(dir, "init.lua"), "utf8");
    assert.ok(config.startsWith(original));
    assert.equal((config.match(/require\("keyword_translator"\)/g) || []).length, 1);
    const files = fs.readdirSync(dir);
    const backup = files.find(file => file.startsWith("init.lua.backup-"));
    assert.equal(fs.readFileSync(path.join(dir, backup), "utf8"), original);
    assert.equal(run().status, 0);
    assert.equal(fs.readFileSync(path.join(dir, "init.lua"), "utf8"), config);
    assert.deepEqual(fs.readdirSync(dir), files);
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});

test("upgrade removes retired undo options, retaining custom translation keys and unrelated CRLF config", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "keyword-translator-upgrade-"));
  try {
    const prefix = 'require("existing_module")\r\n';
    const suffix = 'require("another_module")\r\n';
    const block = '-- BEGIN keyword-translator (managed installation)\r\n'
      + 'keywordTranslator = require("keyword_translator").new({\r\n'
      + '    translateModifiers = {"ctrl"},\r\n    translateKey = "t",\r\n'
      + '    undoModifiers = {"ctrl", "shift"},\r\n    undoKey = "t",\r\n'
      + '}):start()\r\n-- END keyword-translator (managed installation)\r\n';
    const original = prefix + block + suffix;
    fs.writeFileSync(path.join(dir, "init.lua"), original);
    const run = () => spawnSync(process.env.PYTHON_EXECUTABLE || "python3",
      [fileURLToPath(installer), "--directory", dir], { encoding: "utf8" });
    assert.equal(run().status, 0);
    const config = fs.readFileSync(path.join(dir, "init.lua"), "utf8");
    assert.equal(config, original.replace(/^    undo[^\r\n]*\r\n/gm, ""));
    assert.ok(config.startsWith(prefix) && config.endsWith(suffix));
    const files = fs.readdirSync(dir);
    assert.equal(fs.readFileSync(path.join(dir, files.find(f => f.startsWith("init.lua.backup-"))), "utf8"), original);
    assert.equal(run().status, 0);
    assert.deepEqual(fs.readdirSync(dir), files);
    assert.equal(fs.readFileSync(path.join(dir, "init.lua"), "utf8"), config);
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});
