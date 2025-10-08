'use strict';
'require view';
'require form';
'require baseclass';
'require network';
'require view.podkop.main as main';

// Settings content
'require view.podkop.settings as settings';

// Sections content
'require view.podkop.section as section';

// Dashboard content
'require view.podkop.dashboard as dashboard';


const EntryPoint = {
  async render() {
    main.injectGlobalStyles();

    const podkopMap = new form.Map('podkop', _('Podkop Settings'), _('Configuration for Podkop service'));
    // Enable tab views
    podkopMap.tabbed = true;


    // Settings tab
    const settingsSection = podkopMap.section(form.TypedSection, 'settings', _('Settings'));
    settingsSection.anonymous = true;
    settingsSection.addremove = false;
    // Make it named [ config settings 'settings' ]
    settingsSection.cfgsections = function () { return ['settings']; };

    // Render settings content
    settings.createSettingsContent(settingsSection);


    // Sections tab
    const sectionsSection = podkopMap.section(form.TypedSection, 'section', _('Sections'));
    sectionsSection.anonymous = false;
    sectionsSection.addremove = true;
    sectionsSection.template = 'cbi/simpleform';

    // Render section content
    section.createSectionContent(sectionsSection);


    // Dashboard tab
    const dashboardSection = podkopMap.section(form.TypedSection, 'dashboard', _('Dashboard'));
    dashboardSection.anonymous = true;
    dashboardSection.addremove = false;
    // dashboardSection.title = '';
    dashboardSection.cfgsections = function () { return ['dashboard']; };

    // Render dashboard content
    dashboard.createDashboardContent(dashboardSection);



    // Inject core service
    main.coreService();

    return podkopMap.render();
  }
}


return view.extend(EntryPoint);
