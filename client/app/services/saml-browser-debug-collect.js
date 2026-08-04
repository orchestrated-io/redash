/**
 * Collects browser / environment details for SAML troubleshooting (no secrets).
 * Used on the server-rendered login page (global bundle) and the SPA shell.
 */

function inferBrowserFamily(userAgent) {
  if (!userAgent || typeof userAgent !== "string") {
    return "unknown";
  }
  const ua = userAgent.toLowerCase();
  // Order matters: Edge contains Chrome token; Opera / OPR; Samsung; etc.
  if (ua.includes("edg/") || ua.includes("edga/") || ua.includes("edgios/")) {
    return "Edge";
  }
  if (ua.includes("opr/") || ua.includes("opera")) {
    return "Opera";
  }
  if (ua.includes("firefox/")) {
    return "Firefox";
  }
  if (ua.includes("safari/") && !ua.includes("chrome") && !ua.includes("chromium")) {
    return "Safari";
  }
  if (ua.includes("chrome") || ua.includes("chromium")) {
    return "Chrome";
  }
  return "unknown";
}

function getUserAgentDataSummary() {
  const uad = navigator.userAgentData;
  if (!uad || typeof uad.brands === "undefined") {
    return null;
  }
  try {
    const brands = uad.brands.map(b => `${b.brand} ${b.version}`).join(", ");
    return {
      brands,
      mobile: uad.mobile,
      platform: uad.platform || null,
    };
  } catch (e) {
    return { readError: String(e) };
  }
}

function listNavigatorPlugins(max = 40) {
  const plugins = navigator.plugins;
  if (!plugins || !plugins.length) {
    return { count: 0, names: [], note: "empty_or_unavailable" };
  }
  const names = [];
  for (let i = 0; i < plugins.length && names.length < max; i += 1) {
    const p = plugins[i];
    names.push(p.name || p.filename || "(unnamed)");
  }
  return {
    count: plugins.length,
    names,
    truncated: plugins.length > max,
  };
}

function getMimeTypesSummary() {
  try {
    const m = navigator.mimeTypes;
    return m ? m.length : 0;
  } catch (e) {
    return null;
  }
}

function getMetaCspDirectives() {
  const selectors = [
    'meta[http-equiv="Content-Security-Policy"]',
    'meta[http-equiv="Content-Security-Policy-Report-Only"]',
  ];
  const out = [];
  selectors.forEach(sel => {
    document.querySelectorAll(sel).forEach(meta => {
      const content = meta.getAttribute("content");
      out.push({
        httpEquiv: meta.getAttribute("http-equiv"),
        contentLength: content ? content.length : 0,
        contentPreview: content ? `${content.slice(0, 240)}${content.length > 240 ? "…" : ""}` : null,
      });
    });
  });
  return {
    metaTags: out,
    httpCspNote:
      "HTTP Content-Security-Policy / Report-Only headers are not exposed to page JavaScript; check Network tab for document response headers.",
  };
}

function storageAvailability() {
  const tryStorage = name => {
    try {
      const s = window[name];
      if (!s) {
        return "unavailable";
      }
      const k = "__redash_saml_dbg__";
      s.setItem(k, "1");
      s.removeItem(k);
      return "ok";
    } catch (e) {
      return `blocked:${e.name || "Error"}`;
    }
  };
  return {
    localStorage: tryStorage("localStorage"),
    sessionStorage: tryStorage("sessionStorage"),
  };
}

function getFeatureFlags() {
  const nav = navigator;
  return {
    cookieEnabled: !!nav.cookieEnabled,
    doNotTrack: nav.doNotTrack != null ? String(nav.doNotTrack) : null,
    pdfViewerEnabled: typeof nav.pdfViewerEnabled === "boolean" ? nav.pdfViewerEnabled : null,
    webdriver: typeof nav.webdriver === "boolean" ? nav.webdriver : null,
    hardwareConcurrency: typeof nav.hardwareConcurrency === "number" ? nav.hardwareConcurrency : null,
    deviceMemory: typeof nav.deviceMemory === "number" ? nav.deviceMemory : null,
    maxTouchPoints: typeof nav.maxTouchPoints === "number" ? nav.maxTouchPoints : null,
  };
}

/**
 * Known automation / oddities (best-effort; browsers differ).
 */
function getEnvironmentHints() {
  const hints = [];
  if (window.chrome && window.chrome.runtime && window.chrome.runtime.id) {
    hints.push("chrome_extension_runtime_present");
  }
  if (typeof window.isSecureContext === "boolean" && !window.isSecureContext) {
    hints.push("not_secure_context");
  }
  try {
    if (navigator.brave && typeof navigator.brave.isBrave === "function") {
      hints.push("brave_api_present");
    }
  } catch (e) {
    // ignore
  }
  return hints;
}

export function collectBrowserSamlDebugContext() {
  const ua = navigator.userAgent || "";
  return {
    browserInferred: inferBrowserFamily(ua),
    userAgent: ua,
    userAgentData: getUserAgentDataSummary(),
    vendor: navigator.vendor || null,
    platform: navigator.platform || null,
    languages: navigator.languages ? [...navigator.languages] : [navigator.language].filter(Boolean),
    plugins: listNavigatorPlugins(),
    mimeTypesCount: getMimeTypesSummary(),
    features: getFeatureFlags(),
    storage: storageAvailability(),
    screen: {
      width: window.screen ? window.screen.width : null,
      height: window.screen ? window.screen.height : null,
      devicePixelRatio: typeof window.devicePixelRatio === "number" ? window.devicePixelRatio : null,
    },
    csp: getMetaCspDirectives(),
    envHints: getEnvironmentHints(),
  };
}
