"use strict";
"require view";
"require form";
"require baseclass";
"require network";
"require uci";

const COMPILED_ASSET_VERSION = "__COMPILED_ASSET_VERSION_VARIABLE__";
const UNCOMPILED_ASSET_VERSION = [
  "__COMPILED",
  "ASSET_VERSION_VARIABLE__",
].join("_");

function sanitizeAssetVersion(version) {
  return String(version || "").replace(/[^A-Za-z0-9_.~-]/g, "_");
}

async function getAssetVersion() {
  try {
    await uci.load("podkop");
    return (
      uci.get("podkop", "settings", "ui_asset_version") ||
      COMPILED_ASSET_VERSION
    );
  } catch (e) {
    return COMPILED_ASSET_VERSION;
  }
}

async function loadPodkopModules() {
  const defaultResourceVersion = L.env.resource_version;
  const assetVersion = sanitizeAssetVersion(await getAssetVersion());

  if (
    assetVersion &&
    assetVersion !== UNCOMPILED_ASSET_VERSION
  ) {
    // Let LuCI append the Podkop package asset version to dynamically loaded
    // view modules, so browsers fetch fresh UI code after package upgrades.
    L.env.resource_version = `podkop-${assetVersion}`;
  }

  try {
    const [main, settings, section, dashboard, diagnostic] = await Promise.all([
      L.require("view.podkop.main"),
      L.require("view.podkop.settings"),
      L.require("view.podkop.section"),
      L.require("view.podkop.dashboard"),
      L.require("view.podkop.diagnostic"),
    ]);

    return { main, settings, section, dashboard, diagnostic };
  } finally {
    L.env.resource_version = defaultResourceVersion;
  }
}

const EntryPoint = {
  async render() {
    const { main, settings, section, dashboard, diagnostic } =
      await loadPodkopModules();

    main.injectGlobalStyles();

    // Options of features the installed sing-box does not have are not created
    const singBoxFeatures = await main.CustomPodkopMethods.getSingBoxFeatures();

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
    section.createSectionContent(sectionsSection, singBoxFeatures);

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
