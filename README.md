# 输入框中文英译（Tampermonkey）

在网页文本输入框中按 **Ctrl + '**，将中文翻译为英文并替换对应内容。支持 Chrome 和 Brave，使用 Tampermonkey 安装，无需 API Key 或 Node.js。本项目现仅保留油猴版。

## 安装

1. 从 [Tampermonkey 官方下载页面](https://www.tampermonkey.net/index.php?browser=chrome)进入 Chrome Web Store，安装稳定版 Tampermonkey。Brave 也可以安装这个商店版本。
2. 在 `chrome://extensions` 或 `brave://extensions` 中找到 **Tampermonkey → 详情**，开启 **允许用户脚本 / Allow User Scripts**。Chrome 138+ 的 Chrome 系浏览器和 Tampermonkey 5.3+ 支持这种权限方式，全局“开发者模式”可以关闭，参考 [官方 FAQ](https://www.tampermonkey.net/faq.php?locale=en&q=Q209)。没有此开关时，请更新浏览器和 Tampermonkey。
3. 点击 Tampermonkey 工具栏图标，选择 **添加新脚本 / Create a new script**。
4. 打开 [google-keyword-translator.user.js](userscript/google-keyword-translator.user.js)，复制全部内容，替换脚本编辑器中的模板代码。
5. 按 **Ctrl + S** 保存（Mac 使用 **Command + S**），确认脚本已启用。如果提示联网权限，允许连接 `translate.googleapis.com`。
6. 刷新需要使用的网页。

**升级旧版本：**在 Tampermonkey 管理面板中打开原来的脚本，使用上述文件的全部内容替换旧代码，保存并刷新网页。不要同时启用新旧两个脚本；如果之前安装过本项目的独立扩展，请关闭或移除它。

详细步骤见 [脚本安装说明](userscript/安装说明.md)。无需将本项目发布到 Chrome Web Store。

## 使用

1. 点击网页文本输入框，输入中文，例如“机器学习”。
2. 根据需要选中文字，完成中文输入法选词后，按住 **Ctrl**，再按英文键盘上的**单引号 `'` 键**。Mac 上使用 **Control**。
3. 译文会替换对应部分，例如 `Machine learning`。脚本不会提交表单、执行搜索或发送聊天消息。
4. 替换后 12 秒内，可以点击右下角的 **恢复原文** 按钮。

| 输入状态 | 翻译与替换范围 |
| --- | --- |
| 选中文字，包含跨行选区 | 仅选中部分，其余文字保留 |
| 单行输入框，没有选区 | 整个输入框 |
| 多行文本框，没有选区 | 光标所在的实际行，以换行符分隔 |
| 目标为空或不含中文 | 不发送请求，不替换内容 |

“当前行”按实际换行符计算，屏幕宽度导致的自动折行仍属于同一行。光标停在换行符之前时，处理前一行；停在换行符之后时，处理后一行。空行不会回退为翻译整个文本框。

保留选区外内容、换行、空行、缩进和首尾空白。如果服务返回的换行或空行结构不一致，会保留原文并提示缩小选区。每次待翻译部分最多 2000 个字符；长文本框中的短选区仍可翻译。输入框本身的长度限制同样生效。

翻译等待期间，若文本被修改、开始输入法组合输入、光标或选区改变、焦点移走、页面地址或网站启用状态改变，译文不会回填。恢复原文也不会覆盖之后的修改。

## 支持范围

- 普通 HTTP / HTTPS 网页中的 `input[type=text]`、`input[type=search]` 和 `textarea`，包括 Google、Google Scholar 及其他网站。
- 动态创建的输入框及开放 Shadow DOM 中的上述输入框。
- 密码、只读、禁用、数字输入等字段不处理；会排除可识别的验证码、付款信息和登录凭据字段。识别依赖网页标记，不能覆盖所有网站的自定义字段。
- 浏览器地址栏、浏览器内部页面、iframe、封闭 Shadow DOM、`contenteditable` 富文本和自定义编辑器暂不支持。聊天或文档编辑器只有使用普通输入框或 `textarea` 时才在支持范围内。
- 部分网页会拒绝脚本触发的输入事件，或由自己的状态管理覆盖内容，需要逐站适配。

在 Tampermonkey 图标菜单中选择 **在此网站禁用中文英译** 可立即禁用当前网站；之后可通过 **启用此网站的中文英译** 恢复。设置按完整主机名保存，同一网站的其他标签页会同步更新。

## 翻译服务和隐私

- 使用 `https://translate.googleapis.com/translate_a/single` 的免 Key 在线接口，目标语言固定为英文。该接口没有稳定性保证，可能变更或限流。
- 脚本在普通 HTTP / HTTPS 网站运行，只有在受支持的文本框内手动按快捷键时，才发送本次目标文本。单纯输入或选中文字不会上传。
- 请求只包含目标文本和语言参数，不主动发送网页 URL 或其他页面内容，请求不携带 Cookie。目标文本仍会发送到 Google；请在翻译前确认选区或当前行的内容。
- 不保存输入文本或译文；只通过 Tampermonkey 保存禁用的网站主机名。无需剪贴板或历史记录权限。
- 请求 12 秒超时，不自动重试。失败保留原文，可稍后再按快捷键。
- 翻译服务可能改变引号、布尔运算符等搜索语法。可以只选中自然语言部分进行翻译；专业术语建议核对译文。

## 常见问题

- **按键无反应**：刷新网页，确认脚本启用、允许用户脚本已开启、输入法已完成选词，且光标位于支持的输入框。检查当前网站是否被禁用，以及快捷键是否与系统、输入法或其他脚本冲突。
- **多行内容只翻译一行**：这是未选中文字时的行为。要翻译多行，请先选中需要处理的部分。
- **换行不一致提示**：翻译服务改变了原文分行结构，脚本因此保留原文。可以缩小选区或逐行翻译。
- **翻译失败或超时**：检查网络能否访问 Google 翻译及 Tampermonkey 联网权限；遇到限流请稍后再试。
- **富文本或聊天编辑器没有反应**：许多此类编辑器使用 `contenteditable` 或自定义文档模型，目前尚未适配。

## 开发

安装使用不需要构建。开发使用 Node.js 22 或更新版本：

```sh
npm run build
npm test
```

`userscript/config.js` 定义选区与格式规则，`userscript/transport.js` 封装 Tampermonkey 请求，`userscript/content.js` 处理文本框和网站菜单。构建后生成可直接安装的单文件脚本，运行时无需第三方库或远程执行代码。

可选浏览器检查使用 Playwright 和独立临时浏览器配置。通过 `PLAYWRIGHT_MODULE` 指定 Playwright 路径，`BROWSER_EXECUTABLE` 指定 Chrome 或 Brave 可执行文件，然后运行 `npm run test:browser`。检查使用网页夹具及模拟的 Tampermonkey API 和翻译响应，不涉及日常浏览器配置。覆盖范围和限制见 [验证记录](验证记录.md)。
