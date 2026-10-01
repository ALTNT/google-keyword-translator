// Tampermonkey sends this request from its extension background context.
function translateSearchKeywords(text) {
  return new Promise(resolve => {
    const config = KeywordTranslatorConfig;
    if (typeof text !== "string" || !text.trim() || text.length > config.maxLength ||
        !config.containsChinese(text)) {
      resolve({ ok: false, error: "请输入或选中包含中文的文本（最多 2000 个字符）。" });
      return;
    }
    if (typeof GM_xmlhttpRequest !== "function") {
      resolve({ ok: false, error: "请通过 Tampermonkey 安装此脚本，并开启允许用户脚本。" });
      return;
    }
    const url = new URL("https://translate.googleapis.com/translate_a/single");
    url.search = new URLSearchParams({
      client: "gtx", sl: "auto", tl: "en", dt: "t", q: text.trim()
    }).toString();

    let settled = false;
    let request;
    const finish = result => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve(result);
    };
    const fail = error => finish({ ok: false, error });
    // anonymous requests can use fetch internally, where the manager's timeout
    // option is not always effective. Enforce the deadline ourselves as well.
    const timer = setTimeout(() => {
      fail("翻译超时，请检查网络后重试。");
      request?.abort();
    }, 12000);
    try {
      request = GM_xmlhttpRequest({
        method: "GET",
        url: url.href,
        anonymous: true,
        nocache: true,
        timeout: 12000,
        responseType: "json",
        onload(response) {
          if (settled) return;
          if (response.status === 429) return fail("请求过于频繁，请稍后重试。");
          if (!(response.status >= 200 && response.status < 300)) {
            return fail(`翻译服务暂时不可用（HTTP ${response.status}）。`);
          }
          try {
            if (response.finalUrl && new URL(response.finalUrl).origin !== url.origin) {
              return fail("翻译服务地址发生变化，请稍后重试。");
            }
            const data = response.response ?? JSON.parse(response.responseText);
            const segments = Array.isArray(data) && Array.isArray(data[0]) ? data[0] : [];
            const translated = segments.map(segment =>
              Array.isArray(segment) && typeof segment[0] === "string" ? segment[0] : ""
            ).join("").trim();
            if (!translated || translated === text.trim() || config.containsChinese(translated)) {
              return fail("未获得完整的英文译文，请调整文本或选区后重试。");
            }
            finish({ ok: true, text: config.restoreFormatting(text, translated) });
          } catch (error) {
            fail(error.message?.startsWith("译文") ? error.message : "翻译服务返回了无法识别的数据，请稍后重试。");
          }
        },
        onerror: () => fail("无法连接 Google 翻译，请检查网络或脚本联网权限后重试。"),
        ontimeout: () => fail("翻译超时，请检查网络后重试。"),
        onabort: () => fail("翻译请求已取消，请重试。")
      });
    } catch {
      fail("无法发起翻译，请检查 Tampermonkey 的脚本权限后重试。");
    }
  });
}
