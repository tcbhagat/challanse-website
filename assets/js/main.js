/* ================================================================
   CONSTROVET — SHARED JS  (assets/js/main.js)
   Handles:
   1. Nav & footer injection
   2. Mobile hamburger toggle
   3. Active nav link highlight
   4. Branded app URL handling
   ================================================================ */

(function () {
  "use strict";

  const APP_URL = "/app/";

  /* ── 1. INJECT NAV & FOOTER ─────────────────────────────────── */
  async function loadPartial(selector, url) {
    const el = document.querySelector(selector);
    if (!el) return;
    if (el.innerHTML.trim()) return;
    try {
      const res = await fetch(url);
      if (!res.ok) throw new Error("Fetch failed: " + url);
      el.innerHTML = await res.text();
    } catch (e) {
      console.warn("Partial load error:", e);
    }
  }

  /* Resolve path depth — pages/, blog/, and app/ are one level deep. */
  const isNested =
    window.location.pathname.includes("/pages/") ||
    window.location.pathname.includes("/blog/") ||
    window.location.pathname.includes("/app/") ||
    window.location.pathname.includes("/boardroom/") ||
    window.location.pathname.includes("/ssm-core-demo/");
  const base = isNested ? "../assets/" : "assets/";

  Promise.all([
    loadPartial("#cv-nav-placeholder",    base + "nav.html"),
    loadPartial("#cv-footer-placeholder", base + "footer.html"),
  ]).then(() => {
    configureAppLinks();
    initHamburger();
    highlightActiveLink();
    setFooterYear();
    // Re-run lucide if available
    if (window.lucide) lucide.createIcons();
  });

  /* ── 2. HAMBURGER ───────────────────────────────────────────── */
  function initHamburger() {
    const btn    = document.getElementById("cv-hamburger");
    const drawer = document.getElementById("cv-drawer");
    if (!btn || !drawer) return;
    btn.addEventListener("click", () => {
      drawer.classList.toggle("open");
    });
    // Close on link click
    drawer.querySelectorAll("a").forEach(a => {
      a.addEventListener("click", () => drawer.classList.remove("open"));
    });
  }

  /* ── 3. ACTIVE LINK HIGHLIGHT ───────────────────────────────── */
  function highlightActiveLink() {
    const currentPath = normalizePath(window.location.pathname);
    document.querySelectorAll(".cv-nav__links a, .cv-nav__drawer a").forEach(a => {
      const hrefUrl = new URL(a.getAttribute("href") || "/", window.location.origin);
      const hrefPath = normalizePath(hrefUrl.pathname);
      if (hrefUrl.origin === window.location.origin && hrefPath === currentPath) {
        a.classList.add("active");
      }
    });
  }

  function normalizePath(pathname) {
    const path = pathname || "/";
    return path === "/" ? "/" : path.replace(/\/+$/, "");
  }

  function setFooterYear() {
    const year = document.getElementById("cv-year");
    if (year) year.textContent = new Date().getFullYear();
  }

  function configureAppLinks() {
    document.querySelectorAll("[data-cv-app-link]").forEach(a => {
      a.href = APP_URL;
      a.removeAttribute("target");
      a.removeAttribute("rel");
      a.setAttribute("aria-label", "Open Constrovet live dashboard");
    });
  }

})();
