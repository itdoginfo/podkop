"use strict";
"require baseclass";
"require form";
"require ui";
"require uci";
"require fs";
"require view.podkop.main as main";

function createDiagnosticContent(section) {
  const o = section.option(form.DummyValue, "_mount_node");
  o.rawhtml = true;
  o.cfgvalue = () => {
    main.DiagnosticTab.initController();
    return main.DiagnosticTab.render();
  };
}

const EntryPoint = {
  createDiagnosticContent,
};

return baseclass.extend(EntryPoint);
