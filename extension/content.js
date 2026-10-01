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
      const response = await chrome.runtime.sendMessage({
        type: config.messageType, text: original
      });
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
