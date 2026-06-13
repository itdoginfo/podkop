"use strict";
"require baseclass";
"require form";
"require ui";
"require uci";
"require fs";
"require view.netshift.main as main";

function createManagerContent(section) {
  const o = section.option(form.DummyValue, "_mount_node");
  o.rawhtml = true;
  o.cfgvalue = () => {
    main.ManagerTab.initController();
    return main.ManagerTab.render();
  };
}

const EntryPoint = {
  createManagerContent,
};

return baseclass.extend(EntryPoint);
