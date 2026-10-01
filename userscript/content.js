(() => {
  const config = KeywordTranslatorConfig;
  if (!config.isSupportedPage(location.href) || window.top !== window.self) return;

  const revisions = new WeakMap();
  const composing = new WeakSet();
  const storageKey = "disabledHosts";
  let busy = false;
  let noticeHost;
  let noticeTimer;
  let menuId;
  let siteEpoch = 0;
  const cleanHosts = value => Array.isArray(value) ? value.filter(host => typeof host === "string") : [];
  let disabled = cleanHosts(GM_getValue(storageKey, [])).includes(location.hostname);

  function isTextField(element) {
    if (!(element instanceof HTMLInputElement || element instanceof HTMLTextAreaElement) ||
        element.readOnly || element.matches(":disabled") || element.getAttribute("aria-hidden") === "true") return false;
    if (element instanceof HTMLInputElement && !["text", "search"].includes(element.type)) return false;
    if (["numeric", "decimal"].includes(element.inputMode)) return false;
    const autocomplete = element.autocomplete.toLowerCase().split(/\s+/u);
    if (autocomplete.some(token => /^(?:one-time-code|current-password|new-password|username|cc-.+)$/u.test(token))) return false;
    const identity = `${element.id} ${element.name}`;
    if (/(?:password|passwd|\bpwd\b|\botp\b|\bcvv\b|\bcvc\b|card[-_ ]?(?:number|holder)|credit[-_ ]?card|verification[-_ ]?code|验证码|密码|银行卡)/iu.test(identity)) return false;
    return Array.from(element.getClientRects()).some(rect => rect.width > 0 && rect.height > 0);
  }

  function activeField() {
    let element = document.activeElement;
    while (element?.shadowRoot?.activeElement) element = element.shadowRoot.activeElement;
    return element;
  }

  function fieldFromEvent(event) {
    return event.composedPath().find(element => isTextField(element));
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
      button.textContent = "恢复原文";
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

  function updateMenu() {
    if (menuId !== undefined) GM_unregisterMenuCommand(menuId);
    menuId = GM_registerMenuCommand(disabled ? "启用此网站的中文英译" : "在此网站禁用中文英译", () => {
      const hosts = new Set(cleanHosts(GM_getValue(storageKey, [])));
      if (disabled) hosts.delete(location.hostname);
      else hosts.add(location.hostname);
      try {
        GM_setValue(storageKey, Array.from(hosts));
        updateSiteState(Array.from(hosts));
        showNotice(disabled ? "已在此网站禁用中文英译。" : "已在此网站启用中文英译。");
      } catch {
        showNotice("无法保存网站设置，请检查 Tampermonkey 权限。", { error: true });
      }
    });
  }

  function updateSiteState(hosts) {
    const next = cleanHosts(hosts).includes(location.hostname);
    if (next !== disabled) {
      disabled = next;
      siteEpoch++;
      updateMenu();
    }
  }
  updateMenu();
  GM_addValueChangeListener(storageKey, (_name, _old, value) => updateSiteState(value));

  function setFieldValue(field, value, start, end = start, direction = "none", data = value) {
    const prototype = field instanceof HTMLTextAreaElement
      ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
    Object.getOwnPropertyDescriptor(prototype, "value").set.call(field, value);
    field.focus();
    field.setSelectionRange(start, end, direction);
    field.dispatchEvent(new InputEvent("input", {
      bubbles: true, composed: true, inputType: "insertReplacementText", data
    }));
    field.dispatchEvent(new Event("change", { bubbles: true, composed: true }));
  }

  async function translateField(field) {
    if (busy) return;
    const original = field.value;
    const selectionStart = field.selectionStart;
    const selectionEnd = field.selectionEnd;
    const direction = field.selectionDirection;
    const range = config.translationRange(original, selectionStart, selectionEnd, field instanceof HTMLTextAreaElement);
    const target = original.slice(range.start, range.end);
    if (!target.trim()) {
      showNotice(`${range.scope}为空，请先输入或选中中文。`);
      return;
    }
    if (!config.containsChinese(target)) {
      showNotice(`${range.scope}中没有中文，未修改内容。`);
      return;
    }
    if (target.length > config.maxLength) {
      showNotice("待翻译文本超过 2000 个字符，请缩小选区后重试。", { error: true });
      return;
    }

    const revision = revisions.get(field) || 0;
    const epoch = siteEpoch;
    const pageUrl = location.href;
    busy = true;
    showNotice(`正在将${range.scope}翻译为英文…`, { duration: 0 });
    try {
      const response = await translateSearchKeywords(target);
      if (!response?.ok || typeof response.text !== "string" || !response.text.trim()) {
        throw new Error(response?.error || "翻译失败，请稍后重试。");
      }
      if (disabled || siteEpoch !== epoch || !field.isConnected || !isTextField(field) ||
          field.value !== original || (revisions.get(field) || 0) !== revision ||
          composing.has(field) || activeField() !== field || location.href !== pageUrl ||
          field.selectionStart !== selectionStart || field.selectionEnd !== selectionEnd) {
        showNotice("文本、选区、焦点或网站设置已改变，未替换内容。请重新按 Ctrl + '。");
        return;
      }
      const nextValue = original.slice(0, range.start) + response.text + original.slice(range.end);
      if (field.maxLength >= 0 && nextValue.length > field.maxLength) {
        showNotice("译文超过此输入框的长度限制，未替换内容。", { error: true });
        return;
      }
      const caret = range.start + response.text.length;
      setFieldValue(field, nextValue, caret, caret, "none", response.text);
      if (field.value !== nextValue) {
        showNotice("网站未接受译文，此输入框可能需要单独适配。", { error: true });
        return;
      }
      const translatedRevision = revisions.get(field) || 0;
      showNotice(`已将${range.scope}翻译为英文。`, {
        duration: 12000,
        undo() {
          if (field.isConnected && isTextField(field) && field.value === nextValue &&
              (revisions.get(field) || 0) === translatedRevision) {
            setFieldValue(field, original, selectionStart, selectionEnd, direction);
            showNotice("已恢复原文。");
          } else {
            showNotice("输入框内容或状态已改变，未覆盖当前内容。");
          }
        }
      });
    } catch (error) {
      showNotice(error.message || "翻译失败，请检查网络后重试。", { error: true, duration: 8000 });
    } finally {
      busy = false;
    }
  }

  document.addEventListener("input", event => {
    const field = fieldFromEvent(event);
    if (field) revisions.set(field, (revisions.get(field) || 0) + 1);
  }, true);
  document.addEventListener("compositionstart", event => {
    const field = fieldFromEvent(event);
    if (field) {
      composing.add(field);
      revisions.set(field, (revisions.get(field) || 0) + 1);
    }
  }, true);
  document.addEventListener("compositionend", event => {
    const field = fieldFromEvent(event);
    if (field) composing.delete(field);
  }, true);

  document.addEventListener("keydown", event => {
    if (!event.isTrusted || disabled || !event.ctrlKey || event.altKey || event.metaKey || event.shiftKey ||
        !(event.code === "Quote" || event.key === "'") || event.isComposing || event.keyCode === 229) return;
    const field = activeField();
    if (!isTextField(field) || composing.has(field)) return;
    event.preventDefault();
    event.stopImmediatePropagation();
    if (!event.repeat) void translateField(field);
  }, true);
})();
