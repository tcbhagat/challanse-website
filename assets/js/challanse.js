(function () {
  "use strict";

  const workflow = document.querySelector("[data-cs-workflow]");
  const year = document.getElementById("cs-year");
  const pilotDialog = document.getElementById("cs-pilot-dialog");
  const pilotForm = document.getElementById("cs-pilot-form");
  const formStatus = document.getElementById("cs-form-status");
  const runtimeConfig = window.ChallanSeConfig || {};
  let turnstileToken = "";
  let turnstileWidgetId = null;

  if (year) {
    year.textContent = new Date().getFullYear();
  }

  function openPilotDialog() {
    if (!pilotDialog) return;
    if (typeof pilotDialog.showModal === "function") pilotDialog.showModal();
    else pilotDialog.setAttribute("open", "");
    pilotDialog.querySelector("input")?.focus();
  }

  document.querySelectorAll("[data-pilot-request]").forEach((button) => {
    button.addEventListener("click", openPilotDialog);
  });

  pilotDialog?.querySelector(".cs-dialog-close")?.addEventListener("click", () => pilotDialog.close());
  pilotDialog?.addEventListener("click", (event) => {
    if (event.target === pilotDialog) pilotDialog.close();
  });

  function renderTurnstile() {
    if (!pilotForm || turnstileWidgetId !== null || !window.turnstile) return;
    if (!runtimeConfig.turnstileSiteKey || runtimeConfig.turnstileSiteKey.startsWith("__")) {
      if (formStatus) formStatus.textContent = "Pilot requests are not configured yet.";
      return;
    }
    turnstileWidgetId = window.turnstile.render("#cs-turnstile", {
      sitekey: runtimeConfig.turnstileSiteKey,
      callback(token) { turnstileToken = token; },
      "expired-callback"() { turnstileToken = ""; },
    });
  }

  const turnstileTimer = window.setInterval(() => {
    renderTurnstile();
    if (turnstileWidgetId !== null) window.clearInterval(turnstileTimer);
  }, 250);
  window.setTimeout(() => window.clearInterval(turnstileTimer), 10000);

  pilotForm?.addEventListener("submit", async (event) => {
    event.preventDefault();
    if (!runtimeConfig.apiBaseUrl || runtimeConfig.apiBaseUrl.startsWith("__") || !turnstileToken) {
      if (formStatus) formStatus.textContent = "Complete the verification before sending.";
      return;
    }
    const submit = pilotForm.querySelector('[type="submit"]');
    submit.disabled = true;
    if (formStatus) formStatus.textContent = "Sending…";
    const data = new FormData(pilotForm);
    try {
      const response = await fetch(`${runtimeConfig.apiBaseUrl.replace(/\/$/, "")}/v1/pilot-requests`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          name: data.get("name"), company: data.get("company"), email: data.get("email"),
          phone: data.get("phone"), message: data.get("message"), website: data.get("website"),
          turnstileToken,
        }),
      });
      if (!response.ok) throw new Error("request_failed");
      pilotForm.reset();
      if (formStatus) formStatus.textContent = "Request received. We will contact you about the one-site pilot.";
      if (turnstileWidgetId !== null) window.turnstile.reset(turnstileWidgetId);
      turnstileToken = "";
    } catch {
      if (formStatus) formStatus.textContent = "Request could not be sent. Please try again.";
    } finally {
      submit.disabled = false;
    }
  });

  if (!workflow) {
    return;
  }

  const tabs = Array.from(workflow.querySelectorAll('[role="tab"]'));
  const panels = Array.from(workflow.querySelectorAll('[role="tabpanel"]'));

  function activateTab(nextIndex, moveFocus) {
    tabs.forEach((tab, index) => {
      const selected = index === nextIndex;
      tab.setAttribute("aria-selected", String(selected));
      tab.tabIndex = selected ? 0 : -1;
      panels[index].hidden = !selected;
    });

    if (moveFocus) {
      tabs[nextIndex].focus();
    }
  }

  tabs.forEach((tab, index) => {
    tab.addEventListener("click", () => activateTab(index, false));
    tab.addEventListener("keydown", (event) => {
      let nextIndex = index;

      if (event.key === "ArrowRight" || event.key === "ArrowDown") {
        nextIndex = (index + 1) % tabs.length;
      } else if (event.key === "ArrowLeft" || event.key === "ArrowUp") {
        nextIndex = (index - 1 + tabs.length) % tabs.length;
      } else if (event.key === "Home") {
        nextIndex = 0;
      } else if (event.key === "End") {
        nextIndex = tabs.length - 1;
      } else {
        return;
      }

      event.preventDefault();
      activateTab(nextIndex, true);
    });
  });

  activateTab(0, false);
})();
