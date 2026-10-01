// ==UserScript==
// @name         Google / Scholar 中文关键词英译
// @namespace    google-keyword-translator
// @version      1.0.0
// @description  在网页搜索框按 Ctrl + 单引号，将中文关键词翻译为英文，支持恢复中文。
// @match        https://google.com/*
// @match        https://www.google.com/*
// @match        https://scholar.google.com/*
// @match        https://google.com.hk/*
// @match        https://www.google.com.hk/*
// @match        https://scholar.google.com.hk/*
// @match        https://google.com.tw/*
// @match        https://www.google.com.tw/*
// @match        https://scholar.google.com.tw/*
// @match        https://google.cn/*
// @match        https://www.google.cn/*
// @match        https://scholar.google.cn/*
// @match        https://google.co.uk/*
// @match        https://www.google.co.uk/*
// @match        https://scholar.google.co.uk/*
// @match        https://google.ca/*
// @match        https://www.google.ca/*
// @match        https://scholar.google.ca/*
// @match        https://google.com.au/*
// @match        https://www.google.com.au/*
// @match        https://scholar.google.com.au/*
// @match        https://google.co.jp/*
// @match        https://www.google.co.jp/*
// @match        https://scholar.google.co.jp/*
// @match        https://google.co.kr/*
// @match        https://www.google.co.kr/*
// @match        https://scholar.google.co.kr/*
// @match        https://google.de/*
// @match        https://www.google.de/*
// @match        https://scholar.google.de/*
// @match        https://google.fr/*
// @match        https://www.google.fr/*
// @match        https://scholar.google.fr/*
// @match        https://google.co.in/*
// @match        https://www.google.co.in/*
// @match        https://scholar.google.co.in/*
// @match        https://google.com.sg/*
// @match        https://www.google.com.sg/*
// @match        https://scholar.google.com.sg/*
// @grant        GM_xmlhttpRequest
// @connect      translate.googleapis.com
// @run-at       document-idle
// @sandbox      DOM
// @noframes
// ==/UserScript==

(() => {
"use strict";
/* Shared by the content script and the Manifest V3 service worker. */
(() => {
  const domains = Object.freeze([
    "google.com", "google.com.hk", "google.com.tw", "google.cn",
    "google.co.uk", "google.ca", "google.com.au", "google.co.jp",
    "google.co.kr", "google.de", "google.fr", "google.co.in", "google.com.sg"
  ]);
  const hosts = new Set(domains.flatMap(domain => [domain, `www.${domain}`, `scholar.${domain}`]));

  globalThis.KeywordTranslatorConfig = Object.freeze({
    domains,
    maxLength: 2000,
    messageType: "TRANSLATE_SEARCH_KEYWORDS",
    containsChinese: text => /\p{Script=Han}/u.test(text),
    isSupportedPage(rawUrl) {
      try {
        const url = new URL(rawUrl);
        if (url.protocol !== "https:" || !hosts.has(url.hostname)) return false;
        const paths = url.hostname.startsWith("scholar.")
          ? ["/", "/scholar", "/scholar_advanced"]
          : ["/", "/search", "/webhp"];
        return paths.includes(url.pathname);
      } catch {
        return false;
      }
    }
  });
})();

// Tampermonkey sends this request from its extension background context.
function translateSearchKeywords(text) {
  return new Promise(resolve => {
    const config = KeywordTranslatorConfig;
    if (typeof text !== "string" || !text.trim() || text.length > config.maxLength ||
        !config.containsChinese(text)) {
      resolve({ ok: false, error: "请输入包含中文的关键词（最多 2000 个字符）。" });
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
          if (response.status < 200 || response.status >= 300) {
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
              return fail("未获得完整的英文译文，请调整关键词后重试。");
            }
            finish({ ok: true, text: translated });
          } catch {
            fail("翻译服务返回了无法识别的数据，请稍后重试。");
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

(() => {
  const config = KeywordTranslatorConfig;
  if (!config.isSupportedPage(location.href)) return;

  const revisions = new WeakMap();
  const composing = new WeakSet();
  let busy = false;
  let noticeHost;
  let noticeTimer;

  function isSearchField(element) {
    return (element instanceof HTMLInputElement || element instanceof HTMLTextAreaElement) &&
      (element.name === "q" ||
        (location.hostname.startsWith("scholar.") && element.name === "as_q")) &&
      !element.disabled && !element.readOnly &&
      (element instanceof HTMLTextAreaElement || ["text", "search"].includes(element.type));
  }

  function showNotice(message, { error = false, undo, duration = 5000 } = {}) {
    clearTimeout(noticeTimer);
    noticeHost?.remove();
    noticeHost = document.createElement("div");
    noticeHost.setAttribute("data-keyword-translator", "notice");
    const root = noticeHost.attachShadow({ mode: "closed" });
    const style = document.createElement("style");
    style.textContent = `
      :host { all: initial; position: fixed; right: 24px; bottom: 24px;
        z-index: 2147483647; max-width: calc(100vw - 48px); color-scheme: light; }
      .notice { box-sizing: border-box; display: flex; align-items: center; gap: 12px;
        padding: 14px 16px; border: 1px solid ${error ? "#fca5a5" : "#c7d2fe"};
        border-radius: 12px; background: #fff; color: #172554;
        box-shadow: 0 8px 30px #0f172a26;
        font: 14px/1.5 system-ui, -apple-system, sans-serif; }
      span { overflow-wrap: anywhere; }
      button { flex-shrink: 0; cursor: pointer; border: 0; border-radius: 6px;
        padding: 6px 8px; background: #eef2ff; color: #3730a3;
        font: inherit; white-space: nowrap; }
      button:hover { background: #e0e7ff; }
      button:focus-visible { outline: 2px solid #4f46e5; }
      .close { background: transparent; color: #64748b; font-size: 18px; }
    `;
    const notice = document.createElement("div");
    notice.className = "notice";
    notice.setAttribute("role", error ? "alert" : "status");
    notice.setAttribute("aria-live", error ? "assertive" : "polite");
    const label = document.createElement("span");
    label.textContent = message;
    notice.append(label);
    if (undo) {
      const button = document.createElement("button");
      button.type = "button";
      button.textContent = "恢复中文";
      button.addEventListener("click", undo);
      notice.append(button);
    }
    const close = document.createElement("button");
    close.type = "button";
    close.className = "close";
    close.textContent = "×";
    close.setAttribute("aria-label", "关闭提示");
    close.addEventListener("click", () => noticeHost?.remove());
    notice.append(close);
    root.append(style, notice);
    document.documentElement.append(noticeHost);
    if (duration > 0) {
      const current = noticeHost;
      noticeTimer = setTimeout(() => current.remove(), duration);
    }
  }

  function setFieldValue(field, value) {
    const prototype = field instanceof HTMLTextAreaElement
      ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
    Object.getOwnPropertyDescriptor(prototype, "value").set.call(field, value);
    field.dispatchEvent(new InputEvent("input", {
      bubbles: true, inputType: "insertReplacementText", data: value
    }));
    field.dispatchEvent(new Event("change", { bubbles: true }));
    field.focus();
    field.setSelectionRange(value.length, value.length);
  }

  async function translateField(field) {
    if (busy) return;
    const original = field.value;
    if (!original.trim()) {
      showNotice("请先在搜索框输入中文关键词。");
      return;
    }
    if (!config.containsChinese(original)) {
      showNotice("搜索框中没有中文关键词。");
      return;
    }
    if (original.length > config.maxLength) {
      showNotice("关键词过长，请控制在 2000 个字符以内。", { error: true });
      return;
    }

    const revision = revisions.get(field) || 0;
    const pageUrl = location.href;
    busy = true;
    showNotice("正在将关键词翻译为英文…", { duration: 0 });
    try {
      const response = await translateSearchKeywords(original);
      if (!response?.ok || typeof response.text !== "string" || !response.text.trim()) {
        throw new Error(response?.error || "翻译失败，请稍后重试。");
      }
      // Never overwrite text entered while the request was in flight.
      if (!field.isConnected || field.value !== original ||
          (revisions.get(field) || 0) !== revision || composing.has(field) ||
          document.activeElement !== field || location.href !== pageUrl) {
        showNotice("搜索框内容或焦点已改变，未替换关键词。请重新按 Ctrl + '。");
        return;
      }
      setFieldValue(field, response.text);
      const translatedRevision = revisions.get(field) || 0;
      showNotice("已翻译为英文，按回车搜索。", {
        duration: 12000,
        undo() {
          if (field.isConnected && field.value === response.text &&
              (revisions.get(field) || 0) === translatedRevision) {
            setFieldValue(field, original);
            showNotice("已恢复原中文关键词。");
          } else {
            showNotice("搜索框内容已改变，未覆盖当前内容。");
          }
        }
      });
    } catch (error) {
      const message = /Extension context invalidated|Receiving end does not exist/i.test(error.message)
        ? "扩展已更新或重新加载，请刷新页面后重试。"
        : error.message || "翻译失败，请检查网络后重试。";
      showNotice(message, { error: true, duration: 8000 });
    } finally {
      busy = false;
    }
  }

  document.addEventListener("input", event => {
    if (isSearchField(event.target)) {
      revisions.set(event.target, (revisions.get(event.target) || 0) + 1);
    }
  }, true);
  document.addEventListener("compositionstart", event => {
    if (isSearchField(event.target)) {
      composing.add(event.target);
      revisions.set(event.target, (revisions.get(event.target) || 0) + 1);
    }
  }, true);
  document.addEventListener("compositionend", event => composing.delete(event.target), true);

  document.addEventListener("keydown", event => {
    if (!event.ctrlKey || event.altKey || event.metaKey || event.shiftKey ||
        !(event.code === "Quote" || event.key === "'") ||
        event.isComposing || event.keyCode === 229 || !config.isSupportedPage(location.href)) return;
    const field = document.activeElement;
    if (!isSearchField(field) || composing.has(field)) return;
    event.preventDefault();
    event.stopImmediatePropagation();
    if (!event.repeat) void translateField(field);
  }, true);
})();

})();
