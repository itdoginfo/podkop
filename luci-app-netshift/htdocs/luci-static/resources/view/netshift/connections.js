"use strict";
"require baseclass";
"require form";
"require ui";
"require view.netshift.main as main";

// Connections tab: the live connection table of sing-box (through the backend,
// netshift clash_api get_connections). Each connection can be closed, or all of
// them at once; the table follows the router while the tab is on screen.

const REFRESH_MS = 3000;

function sectionNameOf(chains) {
  return chains.length ? chains[0] : "";
}

function ageText(connection) {
  const age = main.connectionAge(connection.start, Date.now());

  if (!age) {
    return "-";
  }

  const units = { s: _("s"), min: _("min"), h: _("h"), d: _("d") };

  return `${age.value} ${units[age.unit]}`;
}

function buildConnections() {
  const tableBody = E("tbody");
  const summary = E("div", { class: "cbi-section-descr" });
  const searchInput = E("input", {
    type: "search",
    class: "cbi-input-text",
    style: "width: 100%; box-sizing: border-box;",
    placeholder: _("Search by address, section or list"),
    input: () => render(),
  });
  const sortSelect = E(
    "select",
    { class: "cbi-input-select", change: () => render() },
    [
      E("option", { value: "recent" }, _("Newest first")),
      E("option", { value: "traffic" }, _("Most traffic first")),
      E("option", { value: "host" }, _("By address")),
    ],
  );
  let snapshot = main.EMPTY_CONNECTIONS;
  let failed = false;
  let timer = null;
  const root = E("div", { class: "cbi-section" });

  function closeOne(connection) {
    main.NetShiftShellMethods.closeConnection(connection.id).then(() => refresh());
  }

  function closeAll() {
    if (!window.confirm(_("Close all connections? Active downloads and calls will be interrupted."))) {
      return;
    }

    main.NetShiftShellMethods.closeAllConnections().then(() => refresh());
  }

  function render() {
    const shown = main
      .sortConnections(
        main.filterConnections(snapshot.connections, searchInput.value),
        sortSelect.value,
      );

    summary.textContent = failed
      ? _("The connection list is not available: is the service running?")
      : `${_("Connections")}: ${snapshot.total} · ↓ ${main.prettyBytes(snapshot.downloadTotal)} · ↑ ${main.prettyBytes(snapshot.uploadTotal)}`;

    tableBody.replaceChildren(
      ...shown.map((connection) =>
        E("tr", { class: "tr" }, [
          E("td", { class: "td" }, [main.connectionTarget(connection)]),
          E("td", { class: "td" }, [connection.network.toUpperCase()]),
          E("td", { class: "td" }, [connection.source]),
          E("td", { class: "td" }, [
            main.connectionRoute(connection) || sectionNameOf(connection.chains) || "-",
          ]),
          E("td", { class: "td" }, [
            `↓ ${main.prettyBytes(connection.download)} ↑ ${main.prettyBytes(connection.upload)}`,
          ]),
          E("td", { class: "td" }, [ageText(connection)]),
          E("td", { class: "td" }, [
            E(
              "button",
              { class: "btn cbi-button", click: () => closeOne(connection) },
              _("Close"),
            ),
          ]),
        ]),
      ),
    );
  }

  function refresh() {
    return main.NetShiftShellMethods.getConnections()
      .then((reply) => {
        failed = !reply.success;
        snapshot = reply.success
          ? main.parseConnections(reply.data)
          : main.EMPTY_CONNECTIONS;
        render();
      })
      .catch(() => {
        failed = true;
        render();
      });
  }

  // Poll while the tab is on screen, stop when it is hidden or gone.
  function tick() {
    if (!root.isConnected) {
      window.clearInterval(timer);
      timer = null;
      return;
    }

    if (root.offsetParent !== null) {
      refresh();
    }
  }

  root.append(
    E("div", { class: "cbi-section-descr" }, [
      _(
        "The connections the router is carrying right now. A closed connection is opened again by the application if it still needs it.",
      ),
    ]),
    summary,
    E("div", { class: "cbi-value" }, [searchInput]),
    E("div", { class: "cbi-value" }, [
      sortSelect,
      " ",
      E("button", { class: "btn cbi-button-negative", click: closeAll }, _("Close all")),
    ]),
    E("div", { class: "table" }, [
      E("table", { class: "table" }, [
        E("thead", {}, [
          E("tr", { class: "tr table-titles" }, [
            E("th", { class: "th" }, [_("Destination")]),
            E("th", { class: "th" }, [_("Protocol")]),
            E("th", { class: "th" }, [_("Source")]),
            E("th", { class: "th" }, [_("Route")]),
            E("th", { class: "th" }, [_("Traffic")]),
            E("th", { class: "th" }, [_("Age")]),
            E("th", { class: "th" }, []),
          ]),
        ]),
        tableBody,
      ]),
    ]),
  );

  render();
  refresh();
  timer = window.setInterval(tick, REFRESH_MS);

  return root;
}

function createConnectionsContent(connectionsSection) {
  const o = connectionsSection.option(form.DummyValue, "_connections");

  o.render = function () {
    return Promise.resolve(E("div", { class: "cbi-value" }, [buildConnections()]));
  };
}

const EntryPoint = {
  createConnectionsContent,
};

return baseclass.extend(EntryPoint);
