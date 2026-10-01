const KeywordTranslatorConfig = Object.freeze({
  maxLength: 2000,
  containsChinese: text => /\p{Script=Han}/u.test(text),
  isSupportedPage(rawUrl) {
    try {
      return ["https:", "http:"].includes(new URL(rawUrl).protocol);
    } catch {
      return false;
    }
  },
  translationRange(value, selectionStart, selectionEnd, multiline) {
    if (selectionEnd > selectionStart) {
      return { start: selectionStart, end: selectionEnd, scope: "选中文字" };
    }
    if (!multiline) return { start: 0, end: value.length, scope: "输入内容" };
    const start = selectionStart === 0 ? 0 : value.lastIndexOf("\n", selectionStart - 1) + 1;
    const nextBreak = value.indexOf("\n", selectionStart);
    return { start, end: nextBreak < 0 ? value.length : nextBreak, scope: "当前行" };
  },
  restoreFormatting(original, translated) {
    const body = original.trim();
    const leading = original.match(/^\s*/u)[0];
    const trailing = original.slice(leading.length + body.length);
    const parts = body.split(/(\r\n|\n|\r)/u);
    const lines = translated.trim().split(/\r\n|\n|\r/u);
    if (lines.length !== (parts.length + 1) / 2) {
      throw new Error("译文换行与原文不一致，未替换。请缩小选区后重试。");
    }
    for (let i = 0; i < parts.length; i += 2) {
      const line = parts[i];
      const translation = lines[i / 2].trim();
      if (!line.trim()) {
        if (translation) throw new Error("译文空行与原文不一致，未替换。");
        continue;
      }
      if (!translation) throw new Error("译文遗漏了原文中的行，未替换。请缩小选区后重试。");
      parts[i] = line.match(/^[^\S\r\n]*/u)[0] + translation + line.match(/[^\S\r\n]*$/u)[0];
    }
    return leading + parts.join("") + trailing;
  }
});
