"use strict";
"require view";
"require form";
"require ui";
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

const SortableTypedSection = form.TypedSection.extend({
  handleMove(sectionId, referenceId, after) {
    const configName = this.uciconfig ?? this.map.config;

    if (this.map.data.move(configName, sectionId, referenceId, after)) {
      return this.map.save(null, true);
    }
  },

  renderContents(sectionIds, nodes) {
    const sectionElement = this.super("renderContents", arguments);

    if (sectionIds.length <= 1) {
      return sectionElement;
    }

    const actionElements = sectionElement.querySelectorAll(
      ":scope > .cbi-section-remove",
    );

    actionElements.forEach((actionElement, index) => {
      const addMoveButton = (title, symbol, referenceId, after, disabled) => {
        actionElement.insertBefore(
          E(
            "button",
            {
              class: "btn pdk-partial-button",
              title,
              click: ui.createHandlerFn(
                this,
                "handleMove",
                sectionIds[index],
                referenceId,
                after,
              ),
              disabled: this.map.readonly || disabled || null,
            },
            [symbol],
          ),
          actionElement.lastElementChild,
        );
      };

      addMoveButton(
        _("Move up"),
        "🡅",
        sectionIds[index - 1],
        false,
        index === 0,
      );
      addMoveButton(
        _("Move down"),
        "🡇",
        sectionIds[index + 1],
        true,
        index === sectionIds.length - 1,
      );
    });

    return sectionElement;
  },
});

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
      SortableTypedSection,
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

    return podkopMap.render();
  },
};

return view.extend(EntryPoint);
