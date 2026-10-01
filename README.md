# 搜索关键词英译（Chrome / Brave）

在 Google 搜索或 Google Scholar 的**网页搜索框**输入中文，按 **Ctrl + '**，关键词会翻译为英文并填回原搜索框。然后按回车搜索。无需 API Key，无需安装 Node.js 或其他依赖。

## 安装

1. Chrome 打开 `chrome://extensions`；Brave 打开 `brave://extensions`。
2. 打开右上角的“开发者模式”。
3. 点击“加载已解压的扩展程序”（Load unpacked）。
4. 选择本项目中的 **`extension` 文件夹**，里面有 `manifest.json`。如果使用 ZIP，请先解压。
5. 刷新已经打开的 Google / Google Scholar 网页。

此扩展使用 Manifest V3。Brave 支持 Chromium 扩展，参考 [Brave 官方说明](https://support.brave.app/hc/en-us/articles/360017909112-How-can-I-add-extensions-to-Brave)。同一份 `extension` 文件夹可分别加载到两款浏览器。

## 使用

1. 打开 <https://www.google.com/> 或 <https://scholar.google.com/>。
2. 点击网页里的搜索框，输入中文关键词，例如“跨区域农作物制图”。
3. 完成中文输入法选词后，按住 **Ctrl**，再按英文键盘上的**单引号 `'` 键**（回车左侧的按键）。Mac 上使用 **Control**，而不是 Command。
4. 搜索框将显示英文，例如 `Cross-regional crop mapping`。按回车搜索。
5. 替换后 12 秒内，可以点击右下角的“恢复中文”按钮，恢复原关键词。

支持首页和搜索结果页的搜索框，也支持 Scholar 高级搜索的“包含全部字词”框。翻译整个搜索框内容，包含简体、繁体和中英混合文本。空白输入、纯英文输入不会发起翻译。

等待期间若你修改内容、开始输入法组合输入，或返回时焦点已不在原搜索框、页面地址已改变，扩展不会直接覆盖当前输入。失败时保留原内容并提示原因。恢复中文也不会覆盖已修改的内容。

支持 `google.com`、`google.com.hk`、`google.com.tw`、`google.cn`、`google.co.uk`、`google.ca`、`google.com.au`、`google.co.jp`、`google.co.kr`、`google.de`、`google.fr`、`google.co.in`、`google.com.sg` 的裸域名、`www` 和 `scholar` 子域名。域名是否提供相应服务取决于 Google；域名重定向至上述地址时也可使用。

## 翻译服务和隐私

- 使用 `https://translate.googleapis.com/translate_a/single` 的免 Key 在线接口，目标语言固定为英文。这不是有稳定性保证的官方 Cloud Translation API，可能变更或限流。
- 只有在搜索框内按快捷键时才发送关键词；普通输入不会触发翻译或上传，不存储搜索词，不请求历史记录、Cookie、剪贴板或全站访问权限。
- 请求仅包含待翻译关键词和语言参数，不发送网页内容或网页 URL，不携带 Cookie。关键词仍会发送至 Google 服务进行处理。
- 需要网络能够访问 Google 翻译。请求 12 秒超时，不做自动重试。
- 搜索语法（如 `site:`、引号、布尔运算符）也会一起交给翻译服务，不能保证原样保留；复杂检索式建议先翻译自然语言部分，再手动添加检索语法。学术术语建议核对译文。

## 常见问题

- **按键无反应**：先刷新页面，确认光标位于网页搜索框、中文输入法已完成选词。浏览器地址栏和新标签页内置搜索框不在扩展范围内。如果操作系统、输入法或其他扩展抢占该组合键，需要解除冲突。
- **翻译失败或超时**：检查网络是否可以访问 Google 翻译，稍后再次按快捷键。
- **扩展重新加载后失效**：刷新搜索网页，重新注入内容脚本。
- **在扩展快捷键设置中看不到 Ctrl + '**：这是预期行为。Chrome 的 [Commands API 支持键列表](https://developer.chrome.com/docs/extensions/reference/api/commands#supported_keys)没有单引号，本扩展直接监听搜索框的键盘事件，无需在该设置中配置。
- **添加其他 Google 地区域名**：编辑 `extension/shared.js` 的 `domains` 数组，在项目根目录运行 `npm run build`，然后重新加载扩展并刷新网页。

## 开发

安装和使用不需要构建。开发时使用 Node.js 22 或更新版本：

```sh
npm run build
npm test
```

源代码不包含第三方运行时依赖或远程执行代码。跨域翻译请求通过后台 service worker 发起，遵循 [Chrome 扩展跨域请求文档](https://developer.chrome.com/docs/extensions/develop/concepts/network-requests)。

测试覆盖后台请求参数、错误处理、消息来源验证，以及搜索框快捷键、输入法组合输入、异步返回覆盖保护和恢复中文。真实页面检查步骤：分别在两款浏览器加载扩展，测试 Google 首页、Google 搜索结果页、Scholar 首页和结果页；输入关键词后按 Ctrl + '，确认英文填回，再按回车搜索；模拟断网时应保留原内容。

`tools/browser-check.mjs` 提供可选的浏览器集成测试，需自行提供 Playwright（设置 `PLAYWRIGHT_MODULE`）和浏览器可执行文件（设置 `BROWSER_EXECUTABLE`）。它使用独立临时浏览器配置，运行后删除，不修改日常配置。Brave/Chromium 加载完整扩展；近期正式版 Chrome 不允许命令行加载扩展，可设置 `CONTENT_ONLY=1` 检查搜索框脚本。默认使用网页测试夹具及模拟翻译响应，另在完整扩展模式下验证一次真实翻译请求；设置 `LIVE_PAGES=1` 可追加真实 Google 和 Scholar 首页检查。
