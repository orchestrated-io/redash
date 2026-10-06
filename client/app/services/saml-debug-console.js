/**
 * Dev-oriented SAML / auth flow tracing in the browser console.
 * Logs only URLs and navigation metadata (no secrets).
 */
import { collectBrowserSamlDebugContext } from "./saml-browser-debug-collect";

const PREFIX = "[Redash SAML debug]";

function navigationSummary() {
  try {
    // Navigation Timing 1 (deprecated but present for Safari 10.1 / Opera 42 in browserslist).
    // Avoid performance.getEntriesByType("navigation") — not supported there (compat/compat).
    const perfNav = performance && performance.navigation;
    if (perfNav && typeof perfNav.type === "number") {
      const TYPE_NAMES = ["navigate", "reload", "back_forward", "reserved"];
      const typeName = TYPE_NAMES[perfNav.type];
      return {
        typeLegacy: typeName !== undefined ? typeName : perfNav.type,
        redirectCount: perfNav.redirectCount,
      };
    }
  } catch (e) {
    // ignore
  }
  return {};
}

export function logAppShellLoaded() {
  let browser;
  try {
    browser = collectBrowserSamlDebugContext();
  } catch (e) {
    browser = { collectError: String(e) };
  }
  // eslint-disable-next-line no-console
  console.info(PREFIX, "app shell loaded — post-login destination (expect document 200, not 302)", {
    href: window.location.href,
    pathname: window.location.pathname,
    search: window.location.search,
    referrer: document.referrer || null,
    ...navigationSummary(),
    browser,
  });
}
