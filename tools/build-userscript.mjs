import fs from "node:fs";
import vm from "node:vm";

const userscript = new URL("../userscript/", import.meta.url);
const header = [
  "// ==UserScript==",
  "// @name         通用输入框中文英译",
  "// @namespace    google-keyword-translator",
  "// @version      1.1.0",
  "// @description  在网页文本框按 Ctrl + 单引号，翻译选中文字或光标所在行，支持恢复原文和网站禁用。",
  "// @match        https://*/*",
  "// @match        http://*/*",
  "// @grant        GM_xmlhttpRequest",
  "// @grant        GM_getValue",
  "// @grant        GM_setValue",
  "// @grant        GM_registerMenuCommand",
  "// @grant        GM_unregisterMenuCommand",
  "// @grant        GM_addValueChangeListener",
  "// @connect      translate.googleapis.com",
  "// @run-at       document-idle",
  "// @sandbox      DOM",
  "// @noframes",
  "// ==/UserScript=="
].join("\n");
const source = ["config.js", "transport.js", "content.js"]
  .map(name => fs.readFileSync(new URL(name, userscript), "utf8")).join("\n");
const output = `${header}\n\n(() => {\n\"use strict\";\n${source}\n})();\n`;
new vm.Script(output);
fs.writeFileSync(new URL("google-keyword-translator.user.js", userscript), output);
console.log("Standalone userscript generated for HTTP / HTTPS pages.");
