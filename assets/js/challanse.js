(function () {
  "use strict";

  const workflow = document.querySelector("[data-cs-workflow]");
  const year = document.getElementById("cs-year");

  if (year) {
    year.textContent = new Date().getFullYear();
  }

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
