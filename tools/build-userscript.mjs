import fs from "node:fs";
import vm from "node:vm";

const extension = new URL("../extension/", import.meta.url);
const userscript = new URL("../userscript/", import.meta.url);
const shared = fs.readFileSync(new URL("shared.js", extension), "utf8");
const context = vm.createContext({ URL });
vm.runInContext(shared, context);
const matches = context.KeywordTranslatorConfig.domains.flatMap(domain => [
  `https://${domain}/*`, `https://www.${domain}/*`, `https://scholar.${domain}/*`
]);
const header = [
  "// ==UserScript==",
  "// @name         Google / Scholar 中文关键词英译",
  "// @namespace    google-keyword-translator",
  "// @version      1.0.0",
  "// @description  在网页搜索框按 Ctrl + 单引号，将中文关键词翻译为英文，支持恢复中文。",
  ...matches.map(match => `// @match        ${match}`),
  "// @grant        GM_xmlhttpRequest",
  "// @connect      translate.googleapis.com",
  "// @run-at       document-idle",
  "// @sandbox      DOM",
  "// @noframes",
  "// ==/UserScript=="
].join("\n");
const request = `await chrome.runtime.sendMessage({
        type: config.messageType, text: original
      })`;
let content = fs.readFileSync(new URL("content.js", extension), "utf8");
if (content.split(request).length !== 2) {
  throw new Error("Content script transport changed; update the userscript build adapter.");
}
content = content.replace(request, "await translateSearchKeywords(original)");
const transport = fs.readFileSync(new URL("transport.js", userscript), "utf8");
const output = `${header}\n\n(() => {\n\"use strict\";\n${shared}\n${transport}\n${content}\n})();\n`;
new vm.Script(output);
fs.writeFileSync(new URL("google-keyword-translator.user.js", userscript), output);
console.log(`Userscript generated with ${matches.length} host patterns.`);
