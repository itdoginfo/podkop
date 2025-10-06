'use strict';
'require baseclass';
'require form';
'require ui';
'require uci';
'require fs';
'require view.podkop.utils as utils';
'require view.podkop.main as main';

function createDashboardSection(mainSection) {
    let o = mainSection.tab('dashboard', _('Dashboard'));

    o = mainSection.taboption('dashboard', form.DummyValue, '_status');
    o.rawhtml = true;
    o.cfgvalue = () => {
        main.initDashboardController()

        return main.renderDashboard()
    };
}

const EntryPoint = {
    createDashboardSection,
}

return baseclass.extend(EntryPoint);
