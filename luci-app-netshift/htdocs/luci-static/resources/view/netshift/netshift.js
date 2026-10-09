"use strict";
"require view";
"require form";
"require baseclass";
"require network";
"require view.netshift.main as main";

// Settings content
"require view.netshift.settings as settings";

// Sections content
"require view.netshift.section as section";

// Dashboard content
"require view.netshift.dashboard as dashboard";

// Local devices content
"require view.netshift.devices as devices";

// Connections content
"require view.netshift.connections as connections";

// Diagnostic content
"require view.netshift.diagnostic as diagnostic";

// Component Manager content
"require view.netshift.manager as manager";

const EntryPoint = {
  async render() {
    main.injectGlobalStyles();

    const netshiftMap = new form.Map(
      "netshift",
      _("NetShift Settings"),
      _("Configuration for NetShift service"),
    );
    // Enable tab views
    netshiftMap.tabbed = true;

    // Dashboard tab (first / landing tab)
    const dashboardSection = netshiftMap.section(
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

    // Sections tab
    const sectionsSection = netshiftMap.section(
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
    const settingsSection = netshiftMap.section(
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

    // Devices tab: drives the Fully Routed IPs / Routing Excluded IPs widgets
    const devicesSection = netshiftMap.section(
      form.TypedSection,
      "devices",
      _("Devices"),
    );
    devicesSection.anonymous = true;
    devicesSection.addremove = false;
    devicesSection.cfgsections = function () {
      return ["devices"];
    };

    devices.createDevicesContent(
      devicesSection,
      sectionsSection,
      settingsSection,
    );

    // Connections tab: the live connection table
    const connectionsSection = netshiftMap.section(
      form.TypedSection,
      "connections",
      _("Connections"),
    );
    connectionsSection.anonymous = true;
    connectionsSection.addremove = false;
    connectionsSection.cfgsections = function () {
      return ["connections"];
    };

    connections.createConnectionsContent(connectionsSection);

    // Component Manager tab
    const managerSection = netshiftMap.section(
      form.TypedSection,
      "manager",
      _("Component Manager"),
    );
    managerSection.anonymous = true;
    managerSection.addremove = false;
    managerSection.cfgsections = function () {
      return ["manager"];
    };

    // Render Component Manager content
    manager.createManagerContent(managerSection);

    // Diagnostic tab
    const diagnosticSection = netshiftMap.section(
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

    // Inject core service
    main.coreService();

    return netshiftMap.render();
  },
};

return view.extend(EntryPoint);
