"use strict";
"require view";
"require form";
"require baseclass";
"require network";
"require view.podkop.main as main";

// Settings content
"require view.podkop.settings as settings";

// Sections content
"require view.podkop.section as section";

// Dashboard content
"require view.podkop.dashboard as dashboard";

// Diagnostic content
"require view.podkop.diagnostic as diagnostic";

const COLLAPSE_STYLE_ID = "podkop-sections-collapse-style";
const COLLAPSE_STATE_STORAGE_KEY = "podkop-sections-collapse-state";

function ensureCollapseStyles() {
  if (document.getElementById(COLLAPSE_STYLE_ID)) {
    return;
  }

  const style = document.createElement("style");
  style.id = COLLAPSE_STYLE_ID;
  style.textContent = `
    #cbi-podkop-section .podkop-sections-toolbar {
      display: flex;
      justify-content: flex-end;
      margin: 0.5rem 0 1rem;
    }

    #cbi-podkop-section .podkop-section-shell {
      margin-bottom: 1rem;
    }

    #cbi-podkop-section .podkop-section-header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 0.75rem;
      padding: 0.75rem 0.9rem;
      border: 1px solid var(--border-color-medium, rgba(60, 60, 60, 0.18));
      border-radius: 8px;
      background: var(--background-color-medium, rgba(255, 255, 255, 0.72));
    }

    #cbi-podkop-section .podkop-section-shell > .cbi-section-node {
      margin-top: 0.65rem;
    }

    #cbi-podkop-section .podkop-section-shell.is-collapsed > .cbi-section-node {
      display: none;
    }

    #cbi-podkop-section .podkop-section-title {
      display: flex;
      align-items: center;
      gap: 0.7rem;
      margin: 0;
      min-width: 0;
      cursor: pointer;
      user-select: none;
      word-break: break-word;
    }

    #cbi-podkop-section .podkop-section-title::before {
      content: "";
      flex: 0 0 auto;
      width: 0.55rem;
      height: 0.55rem;
      border-right: 2px solid currentColor;
      border-bottom: 2px solid currentColor;
      transform: rotate(45deg);
      transition: transform 0.18s ease;
      opacity: 0.75;
      margin-top: -0.15rem;
    }

    #cbi-podkop-section .podkop-section-shell.is-collapsed .podkop-section-title::before {
      transform: rotate(-45deg);
      margin-top: 0;
    }

    #cbi-podkop-section .podkop-section-actions {
      display: flex;
      align-items: center;
      justify-content: flex-end;
      gap: 0.5rem;
      flex: 0 0 auto;
      margin-left: auto;
    }

    #cbi-podkop-section .podkop-section-toggle {
      min-width: 8.5rem;
      white-space: nowrap;
    }

    #cbi-podkop-section .podkop-section-actions .cbi-section-remove,
    #cbi-podkop-section .podkop-section-actions .cbi-section-remove.right {
      float: none;
      margin: 0;
    }

    #cbi-podkop-section .podkop-section-actions .cbi-section-remove .cbi-button {
      white-space: nowrap;
    }

    #cbi-podkop-section .podkop-section-title:focus-visible,
    #cbi-podkop-section .podkop-section-toggle:focus-visible,
    #cbi-podkop-section .podkop-sections-toolbar .cbi-button:focus-visible {
      outline: 2px solid var(--primary, #2b7cff);
      outline-offset: 2px;
    }

    @media (max-width: 700px) {
      #cbi-podkop-section .podkop-section-header {
        align-items: flex-start;
        flex-direction: column;
      }

      #cbi-podkop-section .podkop-section-actions {
        width: 100%;
      }

      #cbi-podkop-section .podkop-section-toggle,
      #cbi-podkop-section .podkop-section-actions .cbi-section-remove .cbi-button {
        flex: 1 1 auto;
      }
    }
  `;

  document.head.appendChild(style);
}

function getCollapseStateStore() {
  if (window.__podkopSectionCollapseState) {
    return window.__podkopSectionCollapseState;
  }

  let state = Object.create(null);

  try {
    const rawState = window.sessionStorage.getItem(COLLAPSE_STATE_STORAGE_KEY);

    if (rawState) {
      state = JSON.parse(rawState);
    }
  } catch (error) {}

  window.__podkopSectionCollapseState = state;
  return state;
}

function persistCollapseState() {
  try {
    window.sessionStorage.setItem(
      COLLAPSE_STATE_STORAGE_KEY,
      JSON.stringify(getCollapseStateStore()),
    );
  } catch (error) {}
}

function hasValidationErrors(node) {
  return !!node.querySelector(
    ".cbi-input-invalid, .cbi-value-error, .cbi-input-validation-error",
  );
}

function updateSectionCollapsedState(sectionState, collapsed, persist) {
  if (collapsed && hasValidationErrors(sectionState.node)) {
    collapsed = false;
  }

  sectionState.collapsed = collapsed;
  sectionState.shell.classList.toggle("is-collapsed", collapsed);
  sectionState.node.hidden = collapsed;
  sectionState.node.setAttribute("aria-hidden", collapsed ? "true" : "false");
  sectionState.titleEl.setAttribute("aria-expanded", collapsed ? "false" : "true");
  sectionState.toggleButton.setAttribute(
    "aria-expanded",
    collapsed ? "false" : "true",
  );
  sectionState.toggleButton.textContent = collapsed ? _("Expand") : _("Collapse");

  if (persist) {
    const stateStore = getCollapseStateStore();
    stateStore[sectionState.key] = collapsed;
    persistCollapseState();
  }
}

function collectSectionStates(container) {
  return Array.from(container.querySelectorAll(".podkop-section-shell"))
    .map((shell) => shell.__podkopSectionState)
    .filter(Boolean);
}

function syncBulkToggleButton(container) {
  const bulkButton = container.__podkopBulkToggleButton;

  if (!bulkButton) {
    return;
  }

  const sectionStates = collectSectionStates(container);
  const allCollapsed =
    sectionStates.length > 0 &&
    sectionStates.every((sectionState) => sectionState.collapsed);

  bulkButton.disabled = sectionStates.length === 0;
  bulkButton.textContent = allCollapsed ? _("Expand all") : _("Collapse all");
}

function toggleAllSections(container) {
  const sectionStates = collectSectionStates(container);
  const allCollapsed =
    sectionStates.length > 0 &&
    sectionStates.every((sectionState) => sectionState.collapsed);
  const nextCollapsed = !allCollapsed;

  sectionStates.forEach((sectionState) => {
    updateSectionCollapsedState(sectionState, nextCollapsed, true);
  });

  syncBulkToggleButton(container);
}

function createSectionToggleButton() {
  const button = document.createElement("button");
  button.type = "button";
  button.className = "cbi-button podkop-section-toggle";
  return button;
}

function getTopLevelSectionNodes(container) {
  return Array.from(container.children).filter(
    (child) =>
      child.classList.contains("cbi-section-node") &&
      child.hasAttribute("data-section-id"),
  );
}

function getSectionTitleNode(node, index) {
  const sectionId = node.getAttribute("data-section-id");
  const titleNode = document.createElement("h3");

  titleNode.textContent = sectionId || _("Section %d").format(index + 1);
  return titleNode;
}

function createSectionShell(container, node, index) {
  if (node.__podkopSectionState) {
    return node.__podkopSectionState;
  }

  if (node.parentNode !== container) {
    return null;
  }

  const sectionId = node.getAttribute("data-section-id") || String(index);
  let titleEl = node.previousElementSibling;
  let removeEl = null;

  if (
    !(titleEl instanceof HTMLElement) ||
    titleEl.parentNode !== container ||
    titleEl.tagName !== "H3"
  ) {
    titleEl = null;
  }

  if (
    titleEl &&
    titleEl.previousElementSibling instanceof HTMLElement &&
    titleEl.previousElementSibling.parentNode === container &&
    titleEl.previousElementSibling.classList.contains("cbi-section-remove")
  ) {
    removeEl = titleEl.previousElementSibling;
  }

  const shell = document.createElement("div");
  shell.className = "podkop-section-shell";
  shell.setAttribute("data-section-id", sectionId);

  const header = document.createElement("div");
  header.className = "podkop-section-header";

  const titleNode = titleEl || getSectionTitleNode(node, index);
  titleNode.classList.add("podkop-section-title");
  titleNode.setAttribute("role", "button");
  titleNode.setAttribute("tabindex", "0");

  if (node.id) {
    titleNode.setAttribute("aria-controls", node.id);
  }

  const actions = document.createElement("div");
  actions.className = "podkop-section-actions";

  const toggleButton = createSectionToggleButton();
  actions.appendChild(toggleButton);

  if (removeEl) {
    actions.appendChild(removeEl);
  }

  header.appendChild(titleNode);
  header.appendChild(actions);

  const anchor = [removeEl, titleEl, node].find(
    (element) => element && element.parentNode === container,
  );

  if (!anchor) {
    return null;
  }

  container.insertBefore(shell, anchor);
  shell.appendChild(header);
  shell.appendChild(node);

  const sectionState = {
    key: sectionId,
    collapsed: false,
    shell,
    node,
    titleEl: titleNode,
    toggleButton,
  };

  shell.__podkopSectionState = sectionState;
  node.__podkopSectionState = sectionState;

  const toggleSection = function (ev) {
    if (ev) {
      ev.preventDefault();
    }

    updateSectionCollapsedState(sectionState, !sectionState.collapsed, true);
    syncBulkToggleButton(container);
  };

  toggleButton.addEventListener("click", toggleSection);
  titleNode.addEventListener("click", toggleSection);
  titleNode.addEventListener("keydown", function (ev) {
    if (ev.key === "Enter" || ev.key === " ") {
      toggleSection(ev);
    }
  });

  const storedState = getCollapseStateStore()[sectionId];
  updateSectionCollapsedState(sectionState, storedState === true, false);

  return sectionState;
}

function ensureBulkToggleToolbar(container) {
  if (
    container.__podkopToolbar &&
    container.__podkopBulkToggleButton &&
    container.contains(container.__podkopToolbar)
  ) {
    return;
  }

  const toolbar = document.createElement("div");
  toolbar.className = "podkop-sections-toolbar";

  const bulkButton = document.createElement("button");
  bulkButton.type = "button";
  bulkButton.className = "cbi-button";
  bulkButton.addEventListener("click", function (ev) {
    ev.preventDefault();
    toggleAllSections(container);
  });

  toolbar.appendChild(bulkButton);

  let insertBefore = null;
  const children = Array.from(container.children);

  for (let i = 0; i < children.length; i += 1) {
    const child = children[i];

    if (
      child.classList.contains("cbi-section-remove") ||
      child.classList.contains("cbi-section-node") ||
      child.classList.contains("podkop-section-shell") ||
      child.classList.contains("cbi-section-create")
    ) {
      insertBefore = child;
      break;
    }

    if (child.tagName === "EM" || (child.tagName === "H3" && i > 0)) {
      insertBefore = child;
      break;
    }
  }

  if (insertBefore) {
    container.insertBefore(toolbar, insertBefore);
  } else {
    container.appendChild(toolbar);
  }

  container.__podkopToolbar = toolbar;
  container.__podkopBulkToggleButton = bulkButton;
}

function applySectionCollapseUI(rootNode) {
  ensureCollapseStyles();

  const sectionsContainer = rootNode.querySelector("#cbi-podkop-section");

  if (!sectionsContainer) {
    return;
  }

  ensureBulkToggleToolbar(sectionsContainer);

  const sectionNodes = getTopLevelSectionNodes(sectionsContainer);

  sectionNodes.forEach((node, index) => {
    createSectionShell(sectionsContainer, node, index);
  });

  collectSectionStates(sectionsContainer).forEach((sectionState) => {
    if (hasValidationErrors(sectionState.node)) {
      updateSectionCollapsedState(sectionState, false, true);
    }
  });

  syncBulkToggleButton(sectionsContainer);
}

function observeSectionCollapseUI(rootNode) {
  if (rootNode.__podkopSectionObserver) {
    return;
  }

  let scheduled = false;

  const scheduleRefresh = function () {
    if (scheduled) {
      return;
    }

    scheduled = true;
    window.requestAnimationFrame(function () {
      scheduled = false;
      applySectionCollapseUI(rootNode);
    });
  };

  const observer = new MutationObserver(scheduleRefresh);
  observer.observe(rootNode, {
    childList: true,
    subtree: true,
  });

  rootNode.__podkopSectionObserver = observer;
}

const EntryPoint = {
  async render() {
    main.injectGlobalStyles();

    const podkopMap = new form.Map(
      "podkop",
      _("Podkop Settings"),
      _("Configuration for Podkop service"),
    );
    // Enable tab views
    podkopMap.tabbed = true;

    // Sections tab
    const sectionsSection = podkopMap.section(
      form.TypedSection,
      "section",
      _("Sections"),
    );
    sectionsSection.anonymous = false;
    sectionsSection.addremove = true;
    sectionsSection.template = "cbi/simpleform";

    // Render section content
    section.createSectionContent(sectionsSection);

    // Settings tab
    const settingsSection = podkopMap.section(
      form.TypedSection,
      "settings",
      _("Settings"),
    );
    settingsSection.anonymous = true;
    settingsSection.addremove = false;
    // Make it named [ config settings 'settings' ]
    settingsSection.cfgsections = function () {
      return ["settings"];
    };

    // Render settings content
    settings.createSettingsContent(settingsSection);

    // Diagnostic tab
    const diagnosticSection = podkopMap.section(
      form.TypedSection,
      "diagnostic",
      _("Diagnostics"),
    );
    diagnosticSection.anonymous = true;
    diagnosticSection.addremove = false;
    diagnosticSection.cfgsections = function () {
      return ["diagnostic"];
    };

    // Render diagnostic content
    diagnostic.createDiagnosticContent(diagnosticSection);

    // Dashboard tab
    const dashboardSection = podkopMap.section(
      form.TypedSection,
      "dashboard",
      _("Dashboard"),
    );
    dashboardSection.anonymous = true;
    dashboardSection.addremove = false;
    dashboardSection.cfgsections = function () {
      return ["dashboard"];
    };

    // Render dashboard content
    dashboard.createDashboardContent(dashboardSection);

    // Inject core service
    main.coreService();

    const renderedMap = await podkopMap.render();
    applySectionCollapseUI(renderedMap);
    observeSectionCollapseUI(renderedMap);

    return renderedMap;
  },
};

return view.extend(EntryPoint);
