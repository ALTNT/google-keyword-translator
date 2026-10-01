import fs from "node:fs";
import vm from "node:vm";

const extension = new URL("../extension/", import.meta.url);
const context = vm.createContext({ URL });
vm.runInContext(fs.readFileSync(new URL("shared.js", extension), "utf8"), context);
const matches = context.KeywordTranslatorConfig.domains.flatMap(domain => [
  `https://${domain}/*`, `https://www.${domain}/*`, `https://scholar.${domain}/*`
]);
const manifest = {
  manifest_version: 3,
  name: "搜索关键词英译 · Google / Scholar",
  version: "1.0.0",
  description: "在 Google 或 Google Scholar 搜索框按 Ctrl + 单引号，将中文关键词翻译为英文。",
  minimum_chrome_version: "109",
  host_permissions: ["https://translate.googleapis.com/*"],
  background: { service_worker: "background.js" },
  content_scripts: [{
    matches,
    js: ["shared.js", "content.js"],
    run_at: "document_idle"
  }],
  action: { default_popup: "popup.html", default_title: "搜索关键词英译（Ctrl + '）" }
};
fs.writeFileSync(new URL("manifest.json", extension), JSON.stringify(manifest, null, 2) + "\n");
console.log(`Manifest generated: ${matches.length} Google / Scholar host patterns.`);
