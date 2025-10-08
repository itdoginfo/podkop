'use strict';
'require baseclass';
'require form';
'require ui';
'require uci';
'require fs';
'require view.podkop.main as main';

function createDashboardContent(section) {
    const o = section.option(form.DummyValue, '_mount_node');
    o.rawhtml = true;
    o.cfgvalue = () => {
        main.initDashboardController();
        return main.renderDashboard();
    };
}

const EntryPoint = {
    createDashboardContent,
};

return baseclass.extend(EntryPoint);
