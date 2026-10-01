importScripts("shared.js");

const config = KeywordTranslatorConfig;

async function translate(text) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 12000);
  try {
    const url = new URL("https://translate.googleapis.com/translate_a/single");
    url.search = new URLSearchParams({
      client: "gtx", sl: "auto", tl: "en", dt: "t", q: text
    }).toString();

    const response = await fetch(url.href, {
      signal: controller.signal,
      credentials: "omit",
      cache: "no-store",
      redirect: "error"
    });
    if (!response.ok) {
      if (response.status === 429) throw new Error("请求过于频繁，请稍后重试。");
      throw new Error(`翻译服务暂时不可用（HTTP ${response.status}）。`);
    }
    const data = await response.json();
    const segments = Array.isArray(data) && Array.isArray(data[0]) ? data[0] : [];
    const translated = segments.map(segment =>
      Array.isArray(segment) && typeof segment[0] === "string" ? segment[0] : ""
    ).join("").trim();
    if (!translated || translated === text || config.containsChinese(translated)) {
      throw new Error("未获得完整的英文译文，请调整关键词后重试。");
    }
    return translated;
  } catch (error) {
    if (controller.signal.aborted) throw new Error("翻译超时，请检查网络后重试。");
    if (error instanceof TypeError) {
      throw new Error("无法连接 Google 翻译，请检查网络后重试。");
    }
    throw error;
  } finally {
    clearTimeout(timeout);
  }
}

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message?.type !== config.messageType) return false;
  if (sender.id !== chrome.runtime.id || !sender.tab || sender.frameId !== 0 ||
      !config.isSupportedPage(sender.url)) {
    sendResponse({ ok: false, error: "仅支持 Google 搜索和 Google Scholar 搜索页面。" });
    return false;
  }
  if (typeof message.text !== "string" || !message.text.trim() ||
      message.text.length > config.maxLength || !config.containsChinese(message.text)) {
    sendResponse({ ok: false, error: "请输入包含中文的关键词（最多 2000 个字符）。" });
    return false;
  }

  translate(message.text.trim()).then(
    text => sendResponse({ ok: true, text }),
    error => sendResponse({ ok: false, error: error.message || "翻译失败，请稍后重试。" })
  );
  // Keep the response channel open for the asynchronous network request.
  return true;
});
