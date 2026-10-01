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
