"use strict";
"require form";
"require uci";
"require ui";
"require baseclass";
"require tools.widgets as widgets";
"require view.netshift.main as main";

// One benchmark at a time for the whole page: every render of the Settings page (and a render after
// Save & Apply) builds a new table, and runs started by two of them would share the local ports.
let dnsBenchmarkRunning = false;

function createSettingsContent(section) {
  // Group the 28 settings options into 5 native CBI option-group tabs.
  // HARD RULE: once a section has tab(), every option MUST be added via
  // taboption() — any leftover section.option(...) renders nothing.
  // depends() works across tabs; a tab whose options are all depends-hidden
  // auto-hides from the strip.
  section.tab(
    "dns",
    _("DNS"),
    _("Upstream and bootstrap DNS resolvers, and optional DNS-over-proxy"),
  );
  section.tab(
    "network",
    _("Network"),
    _("Source and output interfaces, Bad WAN interface monitoring and devices excluded from routing"),
  );
  section.tab(
    "lists",
    _("Lists & Updates"),
    _("List update schedule and the way lists and components are downloaded"),
  );
  section.tab(
    "yacd",
    _("Dashboard"),
    _("Dashboard tiles, YACD web dashboard access and remote-access protection"),
  );
  section.tab(
    "advanced",
    _("Advanced"),
    _("Protocol toggles, file paths and logging. Block DoH only after switching upstream DNS to UDP or DoT."),
  );

  // --- DNS tab ---
  // One table of DNS servers: the first row is the main server, the others are the
  // pool used by the mode below. Every row says how its queries go (directly, or
  // through a section's proxy/VPN) and shows how fast the server answers.
  // Stored in the options the backend has always read (dns_type + dns_server for the
  // main server, dns_pool_server for the rest) plus dns_server_route, so an older
  // config opens as it is and nothing is migrated.
  let o = section.taboption(
    "dns",
    form.Value,
    "dns_servers",
    _("DNS servers"),
    _(
      "scheme://host[:port][/path], where scheme is udp, tcp, dot, doh, doh3 or doq. The first server is the main one. Choose for each server whether its queries go directly or through the proxy/VPN of a section (bootstrap DNS always stays direct). The time is measured from the router, through the tunnel for the servers that go through one, with the routes saved last.",
    ),
  );
  o.rmempty = true;
  o.forcewrite = true;
  o.rows = null;
  if (!main.getCoreCapabilities().quic) {
    o.description = `${o.description} ${_("This core is built without QUIC: DoH3 and DoQ servers are replaced by DoH and DoT.")}`;
  }

  // The proxy/VPN sections a server can be sent through: the ones the backend accepts as a route
  // (see isConfiguredOutboundSection).
  const tunnelSections = () =>
    uci
      .sections("netshift", "section")
      .filter(main.isConfiguredOutboundSection)
      .map((sec) => sec[".name"]);

  // What a server without an entry does: the old global switch decides.
  const backendDefaultRoute = (section_id) =>
    uci.get("netshift", section_id, "dns_via_outbound") === "1"
      ? "tunnel"
      : "direct";

  // The section the older "tunnel" route (and the old switch) points at.
  const defaultTunnelSection = (section_id) => {
    const wanted = uci.get("netshift", section_id, "dns_outbound_section");
    const names = tunnelSections();

    return names.includes(wanted) ? wanted : names[0] || "";
  };

  o.cfgvalue = function (section_id) {
    const servers = main.dnsServersFromOptions({
      dns_type: uci.get("netshift", section_id, "dns_type"),
      dns_server: uci.get("netshift", section_id, "dns_server"),
      dns_pool_server: main.toIpList(
        uci.get("netshift", section_id, "dns_pool_server"),
      ),
    });
    const routes = main.dnsRoutesFromOptions(
      main.toIpList(uci.get("netshift", section_id, "dns_server_route")),
    );
    const fallback = backendDefaultRoute(section_id);
    const tunnelSection = defaultTunnelSection(section_id);

    return servers.map((server) => {
      let route = routes[server] || fallback;

      // "tunnel" is shown as the section it stands for
      if (route === "tunnel") {
        route = tunnelSection ? main.dnsRouteVia(tunnelSection) : "direct";
      }

      return `${server} ${route}`;
    });
  };

  const splitRow = (entry) => {
    const text = String(entry).trim();
    const split = text.lastIndexOf(" ");

    return split < 0
      ? { server: text, route: "direct" }
      : { server: text.slice(0, split), route: text.slice(split + 1) };
  };

  o.formvalue = function () {
    return (this.rows || []).map((row) => `${row.server} ${row.route}`);
  };

  o.write = function (section_id, value) {
    const rows = (Array.isArray(value) ? value : [value]).map(splitRow);
    const servers = rows.map((row) => row.server);
    const options = main.dnsServersToOptions(servers);

    if (!options) {
      return;
    }

    const routes = {};
    const fallback = backendDefaultRoute(section_id);
    // A row that still shows what the global switch does ("via:<section>" for "tunnel") has not
    // been changed by the user: it stays "follows the switch" and is not written as an entry of
    // its own (that would pin it to this section after every save).
    const shownFallback =
      fallback === "tunnel" && defaultTunnelSection(section_id)
        ? main.dnsRouteVia(defaultTunnelSection(section_id))
        : fallback;

    rows.forEach((row) => {
      routes[row.server] = row.route === shownFallback ? fallback : row.route;
    });

    uci.set("netshift", section_id, "dns_type", options.dns_type);
    uci.set("netshift", section_id, "dns_server", options.dns_server);
    uci.set(
      "netshift",
      section_id,
      "dns_pool_server",
      options.dns_pool_server.length ? options.dns_pool_server : null,
    );

    const entries = main.dnsRoutesToOptions(servers, routes, fallback);

    uci.set(
      "netshift",
      section_id,
      "dns_server_route",
      entries.length ? entries : null,
    );
  };
  o.remove = function () {};

  o.renderWidget = function (section_id, option_index, cfgvalue) {
    const widget = this;
    const names = tunnelSections();
    const times = {};
    let busy = false;

    widget.rows = (Array.isArray(cfgvalue) ? cfgvalue : [cfgvalue])
      .filter(Boolean)
      .map(splitRow);

    // the scheme and the host are not case sensitive (the backend compares them in lower case)
    const lowerHost = (server) => {
      const cut = server.indexOf("/", server.indexOf("://") + 3);

      return cut < 0
        ? server.toLowerCase()
        : server.slice(0, cut).toLowerCase() + server.slice(cut);
    };
    const presetLabel = (server) =>
      main.DNS_POOL_PRESETS[server] || main.DNS_POOL_PRESETS[lowerHost(server)] || "";
    // a quieter line under a name (not cbi-value-description: themes put a help icon in front of it)
    const quiet = "opacity:.75;font-size:90%";
    const cellStyle = "vertical-align:middle;padding:.3em .5em";
    const mainMark = E(
      "span",
      { style: `${quiet};margin-left:.5em` },
      `(${_("main")})`,
    );

    const body = E("tbody", {});
    const status = E("span", { style: quiet });
    const refreshButton = E(
      "button",
      {
        class: "btn cbi-button",
        click: (ev) => {
          ev.preventDefault();
          measure();
        },
      },
      _("Refresh"),
    );
    const problem = E("div", {
      style: "color:var(--error-color, #c00);font-size:90%",
    });
    // isValid below shows its verdict here
    widget.problemNode = problem;

    const routeOptions = (route) => {
      const known = ["direct", ...names.map((name) => main.dnsRouteVia(name))];
      const values = known.includes(route) ? known : [...known, route];

      return values.map((value) => {
        const section = main.dnsRouteSection(value);
        let label = _("Directly");

        if (section) {
          label = names.includes(section)
            ? _("Through %s").format(section)
            : _("Through %s (not available)").format(section);
        } else if (value !== "direct") {
          label = value;
        }

        return E(
          "option",
          { value, ...(route === value ? { selected: "" } : {}) },
          label,
        );
      });
    };

    const timeCell = (row) => {
      const result = times[row.server];

      if (result === undefined) {
        return busy ? "…" : "";
      }

      if (result === null) {
        return _("no answer");
      }

      // how it was measured: if the temporary sing-box could not start, the server was
      // asked from the router even though its route says "tunnel"
      const how = result.via === "tunnel" ? _("via the tunnel") : _("from the router");

      return `${result.ms} ${_("ms")} (${how})`;
    };

    const move = (index, step) => {
      const target = index + step;

      if (target < 0 || target >= widget.rows.length) {
        return;
      }

      const [row] = widget.rows.splice(index, 1);

      widget.rows.splice(target, 0, row);
      redraw();
    };

    const redraw = () => {
      body.replaceChildren(
        ...widget.rows.map((row, index) =>
          E("tr", { class: "tr" }, [
            E("td", { class: "td", style: cellStyle }, [
              presetLabel(row.server)
                ? E("div", {}, [
                    presetLabel(row.server),
                    index === 0 ? mainMark : "",
                  ])
                : "",
              E(
                presetLabel(row.server) ? "div" : "span",
                {
                  style: presetLabel(row.server)
                    ? `${quiet};word-break:break-all`
                    : "word-break:break-all",
                },
                row.server,
              ),
              !presetLabel(row.server) && index === 0 ? mainMark : "",
            ]),
            E("td", { class: "td", style: cellStyle }, [
              E(
                "select",
                {
                  class: "cbi-input-select",
                  change: (ev) => {
                    row.route = ev.target.value;
                    delete times[row.server];
                    redraw();
                  },
                },
                routeOptions(row.route),
              ),
            ]),
            E(
              "td",
              { class: "td", style: `${cellStyle};white-space:nowrap` },
              timeCell(row),
            ),
            E("td", { class: "td", style: `${cellStyle};white-space:nowrap` }, [
              E(
                "button",
                {
                  class: "btn cbi-button",
                  title: _("Move up"),
                  ...(index === 0 ? { disabled: "" } : {}),
                  click: (ev) => {
                    ev.preventDefault();
                    move(index, -1);
                  },
                },
                "↑",
              ),
              E(
                "button",
                {
                  class: "btn cbi-button",
                  title: _("Move down"),
                  ...(index === widget.rows.length - 1 ? { disabled: "" } : {}),
                  click: (ev) => {
                    ev.preventDefault();
                    move(index, 1);
                  },
                },
                "↓",
              ),
              E(
                "button",
                {
                  class: "btn cbi-button cbi-button-remove",
                  title: _("Remove"),
                  ...(widget.rows.length <= 1 ? { disabled: "" } : {}),
                  click: (ev) => {
                    ev.preventDefault();
                    widget.rows.splice(index, 1);
                    redraw();
                  },
                },
                "✕",
              ),
            ]),
          ]),
        ),
      );
    };

    // The speed test: every server of the table, from the router or through the
    // tunnel (the routes saved last decide which).
    const measure = () => {
      if (dnsBenchmarkRunning && !busy) {
        // a test started by a page that was redrawn meanwhile is still running: say so and
        // leave the button alone until it ends (its answer goes to that page, not this one)
        status.textContent = _("Testing...");
        refreshButton.disabled = true;
        // a table that has left the page (redrawn again, another page opened) stops asking:
        // it would start a test nobody sees
        window.setTimeout(() => status.isConnected && measure(), 2000);
        return;
      }

      if (busy || dnsBenchmarkRunning) {
        return;
      }

      busy = true;
      dnsBenchmarkRunning = true;
      refreshButton.disabled = true;
      status.textContent = _("Testing...");
      Object.keys(times).forEach((key) => delete times[key]);
      redraw();

      return main.NetShiftShellMethods.dnsBenchmark(
        widget.rows.map((row) => row.server),
      )
        .then((reply) => {
          const results = reply.success
            ? main.parseDnsBenchmark(reply.data)
            : [];

          results.forEach((result) => {
            times[result.server] =
              result.ms === null
                ? null
                : { ms: result.ms, via: result.via };
          });
          status.textContent = results.length
            ? ""
            : _("The test could not be run");
        })
        .catch(() => {
          status.textContent = _("The test could not be run");
        })
        .finally(() => {
          busy = false;
          dnsBenchmarkRunning = false;
          refreshButton.disabled = false;
          redraw();
        });
    };

    // Add a server: pick a ready-made one from the list, or type any
    // scheme://host and press Enter (the same picker the list used to have).
    const addServer = (value) => {
      const validation = main.validateDnsPoolServer(value);

      if (!validation.valid) {
        problem.textContent = validation.message;
        return;
      }

      if (widget.rows.some((row) => row.server === value)) {
        problem.textContent = _("This server is already in the list");
        return;
      }

      problem.textContent = "";
      widget.rows.push({ server: value, route: "direct" });
      redraw();

      // A second server is useless in "first server only" mode: switch to priority
      // (the mode can still be changed below).
      if (widget.rows.length === 2 && main.getCoreCapabilities().dns_pool) {
        const mode = widget.section.getUIElement(section_id, "dns_pool_mode");

        if (mode && mode.getValue() === "single") {
          mode.setValue("fallback");
        }
      }
    };
    const picker = new ui.Combobox("", main.DNS_POOL_PRESETS, {
      placeholder: _("Add a server: pick one or type scheme://host"),
      custom_placeholder: _("scheme://host[:port][/path], then Enter"),
      sort: Object.keys(main.DNS_POOL_PRESETS),
    });
    const pickerNode = picker.render();

    pickerNode.addEventListener("cbi-dropdown-change", (ev) => {
      const value = String(ev.detail?.value?.value ?? "").trim();

      if (value) {
        addServer(value);
        picker.setValue("");
      }
    });

    redraw();
    window.setTimeout(measure, 0);

    return E("div", {}, [
      E("div", { style: "overflow-x:auto" }, [
        E("table", { class: "table cbi-section-table" }, [
          E("thead", {}, [
            E("tr", { class: "tr table-titles" }, [
              E("th", { class: "th" }, _("Server")),
              E("th", { class: "th" }, _("Route")),
              E("th", { class: "th" }, _("Time")),
              E(
                "th",
                { class: "th", style: "text-align:right;white-space:nowrap" },
                refreshButton,
              ),
            ]),
          ]),
          body,
        ]),
      ]),
      E("div", { style: "margin-top:.5em" }, [status]),
      E("div", { style: "margin-top:.5em;max-width:28em" }, [pickerNode]),
      problem,
    ]);
  };
  // The first row is the main server and must be scheme://host: without this a list whose
  // first row is not (a hand-edited dns_type) would just not be saved. LuCI hands validate()
  // to the widgets it builds itself and reaches it on save through isValid() -> the widget
  // found by the id of the option; this table is plain DOM with no such widget, so the check is
  // made in isValid() itself (a false answer stops the save), and its message is shown under
  // the table.
  o.isValid = function (section_id) {
    const servers = (this.rows || [])
      .map((row) => row.server)
      .filter(Boolean);
    const valid = !servers.length || Boolean(main.dnsServersToOptions(servers));

    if (this.problemNode) {
      this.problemNode.textContent = valid
        ? ""
        : _(
            "Use scheme://host[:port][/path], where scheme is udp, tcp, dot, doh, doh3 or doq. Example: doh://dns.google/dns-query",
          );
    }

    return valid;
  };

  o = section.taboption(
    "dns",
    form.ListValue,
    "dns_pool_mode",
    _("Several DNS servers"),
    _(
      "How the servers of the list are used together when there are several. Needs sing-box 1.14 or newer; on an older core only the first server is used.",
    ),
  );
  if (!main.getCoreCapabilities().dns_pool) {
    o.description = `${o.description} ${_("The installed core (%s) is older: only the first server is used.").format(main.getCoreCapabilities().version)}`;
  }
  o.value("single", _("First server only"));
  o.value("fallback", _("Priority: next server if the previous one fails"));
  o.value("race", _("Parallel: the first usable answer wins"));
  o.default = "single";
  o.rmempty = false;

  o = section.taboption(
    "dns",
    form.Value,
    "dns_pool_timeout",
    _("DNS server timeout"),
    _(
      "How long one DNS server may take before the next one is tried (priority) or its answer is dropped (parallel). Examples: 500ms, 2s",
    ),
  );
  o.depends("dns_pool_mode", "fallback");
  o.depends("dns_pool_mode", "race");
  o.default = "2s";
  o.rmempty = false;
  o.validate = function (section_id, value) {
    const validation = main.validateDnsPoolTimeout(value);

    if (validation.valid) {
      return true;
    }

    return validation.message;
  };

  o = section.taboption(
    "dns",
    form.Value,
    "bootstrap_dns_server",
    _("Bootstrap DNS server"),
    _(
      "The DNS server used to look up the IP address of an upstream DNS server",
    ),
  );
  Object.entries(main.BOOTSTRAP_DNS_SERVER_OPTIONS).forEach(([key, label]) => {
    o.value(key, _(label));
  });
  o.default = "77.88.8.8";
  o.rmempty = false;
  o.validate = function (section_id, value) {
    const validation = main.validateDNS(value);

    if (validation.valid) {
      return true;
    }

    return validation.message;
  };

  o = section.taboption(
    "dns",
    form.DynamicList,
    "dns_forward",
    _("DNS forwarding by zone"),
    _(
      'One entry per line: "zone server", for example "ru 77.88.8.8" sends the zone .ru and all its subdomains to that DNS server directly, the way a "server=/ru/77.88.8.8" line does in the dnsmasq config. The server is an IP address, optionally with #port. The names of these zones get their real addresses, not FakeIP, so they are not routed by domain; the entries are applied to dnsmasq unless "Dont Touch My DHCP" is on.',
    ),
  );
  o.placeholder = "ru 77.88.8.8";
  o.rmempty = true;
  o.validate = function (section_id, value) {
    if (!value) {
      return true;
    }

    const validation = main.validateDnsForward(value);

    if (validation.valid) {
      return true;
    }

    return validation.message;
  };

  o = section.taboption(
    "dns",
    form.Value,
    "dns_rewrite_ttl",
    _("DNS Rewrite TTL"),
    _("Time in seconds for DNS record caching (default: 60)"),
  );
  o.default = "60";
  o.rmempty = false;
  o.validate = function (section_id, value) {
    if (!value) {
      return _("TTL value cannot be empty");
    }

    const ttl = parseInt(value);
    if (isNaN(ttl) || ttl < 0) {
      return _("TTL must be a positive number");
    }

    return true;
  };

  // The WAN interfaces and the ECS subnet each one gives (netshift
  // get_wan_addresses). Asking can take a few seconds: a private WAN address makes
  // the router look its external address up once.
  let wanAddresses = null;
  const loadWanAddresses = () => {
    wanAddresses ??= main
      .executeShellCommand({
        command: "/usr/bin/netshift",
        args: ["get_wan_addresses"],
        timeout: 30000,
      })
      .then((reply) => {
        try {
          const data = JSON.parse(reply.stdout || "{}");

          return Array.isArray(data.interfaces) ? data.interfaces : [];
        } catch (e) {
          return [];
        }
      })
      .catch(() => []);

    return wanAddresses;
  };

  o = section.taboption(
    "dns",
    form.Flag,
    "dns_client_subnet_auto",
    _("Detect the EDNS Client Subnet from the WAN"),
    _(
      "Take the subnet from a WAN interface: its public address, or, when the interface has a private (NAT) address, the address the internet sees (looked up once and remembered). The value below is used when no address can be determined. IPv4 only, the /24 of the address.",
    ),
  );
  o.default = o.disabled;
  o.rmempty = true;

  o = section.taboption(
    "dns",
    form.ListValue,
    "dns_client_subnet_interface",
    _("WAN interface for the EDNS Client Subnet"),
    _("With several WAN interfaces choose the one whose address represents you. Automatic uses the first working one."),
  );
  o.depends("dns_client_subnet_auto", "1");
  o.value("", _("Automatic (first working)"));
  o.rmempty = true;
  o.load = function (section_id) {
    return loadWanAddresses().then((interfaces) => {
      interfaces.forEach((item) => {
        const label = item.subnet
          ? `${item.interface} (${item.subnet})`
          : `${item.interface} (${_("no address")})`;

        if (!this.keylist?.includes(item.interface)) {
          this.value(item.interface, label);
        }
      });

      return form.ListValue.prototype.load.call(this, section_id);
    });
  };

  o = section.taboption(
    "dns",
    form.Value,
    "dns_client_subnet",
    _("EDNS Client Subnet"),
    _(
      "Send this IP address or prefix with every DNS query (EDNS Client Subnet, RFC 7871), so geo-distributed services resolve to the node closest to you. Leave empty to disable. The detected WAN subnets are offered in the list.",
    ),
  );
  o.placeholder = "203.0.113.0/24";
  o.rmempty = true;
  o.load = function (section_id) {
    return loadWanAddresses().then((interfaces) => {
      interfaces.forEach((item) => {
        if (item.subnet && !this.keylist?.includes(item.subnet)) {
          this.value(item.subnet, `${item.subnet} (${item.interface})`);
        }
      });

      return form.Value.prototype.load.call(this, section_id);
    });
  };
  o.validate = function (section_id, value) {
    if (!value) {
      return true;
    }

    const validation = main.validateSubnet(value);

    if (validation.valid) {
      return true;
    }

    return validation.message;
  };

  // --- Network tab ---
  o = section.taboption(
    "network",
    widgets.DeviceSelect,
    "source_network_interfaces",
    _("Source Network Interface"),
    _("Select the network interface from which the traffic will originate"),
  );
  o.default = "br-lan";
  o.noaliases = true;
  o.nobridges = false;
  o.noinactive = false;
  o.multiple = true;
  o.filter = function (section_id, value) {
    // Block specific interface names from being selectable
    const blocked = ["wan", "phy0-ap0", "phy1-ap0", "pppoe-wan"];
    if (blocked.includes(value)) {
      return false;
    }

    // Try to find the device object by its name
    const device = this.devices.find((dev) => dev.getName() === value);

    // If no device is found, allow the value
    if (!device) {
      return true;
    }

    // Check the type of the device
    const type = device.getType();

    // Consider any Wi-Fi / wireless / wlan device as invalid
    const isWireless =
      type === "wifi" || type === "wireless" || type.includes("wlan");

    // Allow only non-wireless devices
    return !isWireless;
  };

  o = section.taboption(
    "network",
    form.Value,
    "direct_tcp_ports",
    _("TCP ports that always go directly"),
    _(
      "Traffic to these TCP ports never takes the tunnel, even for a domain or a subnet that is routed through it. Ports and ranges, separated by commas, for example: 22, 25, 6881-6889.",
    ),
  );
  o.placeholder = "80, 443, 1000-2000";
  o.rmempty = true;
  o.validate = function (section_id, value) {
    if (!value) {
      return true;
    }

    const validation = main.validatePortList(value);

    return validation.valid ? true : validation.message;
  };

  o = section.taboption(
    "network",
    form.Value,
    "direct_udp_ports",
    _("UDP ports that always go directly"),
    _(
      "Traffic to these UDP ports never takes the tunnel (voice calls, games, NTP). Ports and ranges, separated by commas.",
    ),
  );
  o.placeholder = "80, 443, 1000-2000";
  o.rmempty = true;
  o.validate = function (section_id, value) {
    if (!value) {
      return true;
    }

    const validation = main.validatePortList(value);

    return validation.valid ? true : validation.message;
  };

  o = section.taboption(
    "network",
    form.Flag,
    "wifi_calling_direct",
    _("Wi-Fi Calling directly"),
    _(
      "Adds UDP ports 500 and 4500 (the IKE and NAT-T tunnel of the operator's ePDG) to the ports that go out directly. A call over Wi-Fi is not accepted by the operator from a foreign exit address of a tunnel. Added to the list above; nothing else changes.",
    ),
  );
  o.default = "0";
  o.rmempty = false;

  o = section.taboption(
    "network",
    form.Value,
    "proxy_only_tcp_ports",
    _("Only these TCP ports take the tunnel"),
    _(
      "When set, TCP traffic to every other port goes directly. For example 80, 443 keeps mail and torrents out of the tunnel. A port in the list above still goes directly.",
    ),
  );
  o.placeholder = "80, 443, 1000-2000";
  o.rmempty = true;
  o.validate = function (section_id, value) {
    if (!value) {
      return true;
    }

    const validation = main.validatePortList(value);

    return validation.valid ? true : validation.message;
  };

  o = section.taboption(
    "network",
    form.Value,
    "proxy_only_udp_ports",
    _("Only these UDP ports take the tunnel"),
    _(
      "When set, UDP traffic to every other port goes directly. For example 443 leaves only QUIC to the tunnel. A port in the list above still goes directly.",
    ),
  );
  o.placeholder = "80, 443, 1000-2000";
  o.rmempty = true;
  o.validate = function (section_id, value) {
    if (!value) {
      return true;
    }

    const validation = main.validatePortList(value);

    return validation.valid ? true : validation.message;
  };

  o = section.taboption(
    "network",
    form.Flag,
    "dns_hijack",
    _("Send LAN DNS queries to the router"),
    _(
      "Plain DNS (port 53) of the devices in the source interfaces is redirected to the router even when a device asks another server, such as a hard-coded 8.8.8.8. Without it such devices never get the FakeIP answers that routing by domain depends on. DNS over TLS/HTTPS is not touched.",
    ),
  );
  o.default = "0";
  o.rmempty = false;

  o = section.taboption(
    "network",
    form.Flag,
    "enable_output_network_interface",
    _("Enable Output Network Interface"),
    _("You can select Output Network Interface, by default autodetect"),
  );
  o.default = "0";
  o.rmempty = false;

  o = section.taboption(
    "network",
    widgets.DeviceSelect,
    "output_network_interface",
    _("Output Network Interface"),
    _("Select the network interface to which the traffic will originate"),
  );
  o.noaliases = true;
  o.multiple = false;
  o.depends("enable_output_network_interface", "1");
  o.filter = function (section_id, value) {
    // Blocked interface names that should never be selectable
    const blockedInterfaces = ["br-lan"];

    // Reject immediately if the value matches any blocked interface
    if (blockedInterfaces.includes(value)) {
      return false;
    }

    // Reject lan*
    if (value.startsWith("lan")) {
      return false;
    }

    // Reject tun*, wg*, vpn*, awg*, oc*
    if (
      value.startsWith("tun") ||
      value.startsWith("wg") ||
      value.startsWith("vpn") ||
      value.startsWith("awg") ||
      value.startsWith("oc")
    ) {
      return false;
    }

    // Try to find the device object with the given name
    const device = this.devices.find((dev) => dev.getName() === value);

    // If no device is found, allow the value
    if (!device) {
      return true;
    }

    // Get the device type (e.g., "wifi", "ethernet", etc.)
    const type = device.getType();

    // Reject wireless-related devices
    const isWireless =
      type === "wifi" || type === "wireless" || type.includes("wlan");

    return !isWireless;
  };

  o = section.taboption(
    "network",
    form.Flag,
    "enable_badwan_interface_monitoring",
    _("Interface Monitoring"),
    _("Interface monitoring for Bad WAN"),
  );
  o.default = "0";
  o.rmempty = false;

  o = section.taboption(
    "network",
    widgets.NetworkSelect,
    "badwan_monitored_interfaces",
    _("Monitored Interfaces"),
    _("Select the WAN interfaces to be monitored"),
  );
  o.depends("enable_badwan_interface_monitoring", "1");
  o.multiple = true;
  o.filter = function (section_id, value) {
    // Reject if the value is in the blocked list ['lan', 'loopback']
    if (["lan", "loopback"].includes(value)) {
      return false;
    }

    // Reject if the value starts with '@' (means it's an alias/reference)
    if (value.startsWith("@")) {
      return false;
    }

    // Otherwise allow it
    return true;
  };

  o = section.taboption(
    "network",
    form.Value,
    "badwan_reload_delay",
    _("Interface Monitoring Delay"),
    _("Delay in milliseconds before reloading NetShift after interface UP"),
  );
  o.depends("enable_badwan_interface_monitoring", "1");
  o.default = "2000";
  o.rmempty = false;
  o.validate = function (section_id, value) {
    if (!value) {
      return _("Delay value cannot be empty");
    }
    return true;
  };

  // Where NetShift itself is updated from: the developer's repository or the fork.
  o = section.taboption(
    "lists",
    form.ListValue,
    "update_repo",
    _("NetShift update source"),
    _(
      "Where the NetShift updates (the Components manager and the notice on the dashboard) come from. Each repository offers its latest release (the one GitHub shows as latest; a release marked as a pre-release is never offered), even when its version is lower than the installed one: after switching the source, press Check update in the Components manager to see what is offered and what is new in it. The builds of the fork are ordinary releases and are offered like any other.",
    ),
  );
  o.value("upstream", _("yandexru45/netshift (developer, stable releases)"));
  o.value("fork", _("cergo666/netshift (fork builds)"));
  o.default = "upstream";
  o.rmempty = false;

  // Automatic updates of NetShift and sing-box with a rollback (lib/autoupdate.sh).
  o = section.taboption(
    "lists",
    form.Flag,
    "auto_update",
    _("Automatic updates"),
    _(
      "Checks for new releases of NetShift and sing-box and installs them by itself. Before the update and after it, NetShift checks that it works (sing-box answers and a proxy or VPN section reaches the internet). If it stops working after an update, the previous version is installed again and the release that broke it is skipped from then on. Nothing is updated while NetShift does not work.",
    ),
  );
  o.default = "0";
  o.rmempty = false;

  o = section.taboption(
    "lists",
    form.Flag,
    "auto_update_netshift",
    _("Update NetShift automatically"),
    _("From the update source chosen above."),
  );
  o.depends("auto_update", "1");
  o.default = "1";
  o.rmempty = false;

  o = section.taboption(
    "lists",
    form.Flag,
    "auto_update_sing_box",
    _("Update sing-box automatically"),
    _(
      "sing-box-extended and its lite build. The stock sing-box comes from the firmware packages and cannot be rolled back, so it is not updated automatically.",
    ),
  );
  o.depends("auto_update", "1");
  o.default = "1";
  o.rmempty = false;

  o = section.taboption(
    "lists",
    form.Flag,
    "auto_update_on_boot",
    _("Check after boot"),
    _("A few minutes after the router has started."),
  );
  o.depends("auto_update", "1");
  o.default = "1";
  o.rmempty = false;

  o = section.taboption(
    "lists",
    form.ListValue,
    "auto_update_interval",
    _("Check on schedule"),
  );
  o.value("off", _("Off"));
  o.value("12h", _("Every 12 hours"));
  o.value("1d", _("Every day"));
  o.value("1w", _("Every week (Sunday)"));
  o.depends("auto_update", "1");
  o.default = "1d";
  o.rmempty = false;

  o = section.taboption(
    "lists",
    form.Value,
    "auto_update_time",
    _("Time of the check"),
    _("HH:MM, router time. Every 12 hours: at this time and twelve hours later."),
  );
  o.depends({ auto_update: "1", auto_update_interval: "12h" });
  o.depends({ auto_update: "1", auto_update_interval: "1d" });
  o.depends({ auto_update: "1", auto_update_interval: "1w" });
  o.default = "04:30";
  o.placeholder = "04:30";
  o.rmempty = false;
  o.validate = function (section_id, value) {
    return /^([01][0-9]|2[0-3]):[0-5][0-9]$/.test(value || "")
      ? true
      : _("Use HH:MM, for example 04:30");
  };

  o = section.taboption(
    "lists",
    form.DummyValue,
    "_auto_update_status",
    _("Last automatic update"),
  );
  o.depends("auto_update", "1");
  o.rawhtml = true;
  o.cfgvalue = function () {
    const result = E("div", {}, _("Loading..."));

    main.NetShiftShellMethods.getAutoUpdateStatus()
      .then((reply) => {
        const lines = reply.success ? main.describeAutoUpdateState(reply.data) : [];

        result.replaceChildren(
          ...(lines.length
            ? lines.map((line) => E("div", {}, line))
            : [E("div", {}, _("No run yet"))]),
        );
      })
      .catch(() => result.replaceChildren(E("div", {}, _("No run yet"))));

    return result;
  };

  o = section.taboption(
    "lists",
    form.DynamicList,
    "update_mirror",
    _("GitHub mirrors for downloads"),
    _(
      "Optional: https:// addresses of GitHub mirrors, for when GitHub is hard to reach. A mirror is tried only after the direct download failed, and is put in front of the full GitHub address (for example https://gh-proxy.com/). What a mirror returns is not signed, so list only a mirror you trust: it supplies the downloaded packages (checksum lists are always read from GitHub itself). Empty: no mirror.",
    ),
  );
  o.rmempty = true;
  o.validate = function (section_id, value) {
    if (!value) {
      return true;
    }

    return /^https:\/\/[^\s/]+(\/[^\s]*)?$/.test(value)
      ? true
      : _("Use an https:// address, for example https://gh-proxy.com/");
  };

  o = section.taboption(
    "network",
    form.DynamicList,
    "routing_excluded_ips",
    _("Routing Excluded IPs"),
    _("Specify a local IP address to be excluded from routing"),
  );
  o.placeholder = "IP";
  o.rmempty = true;
  o.validate = function (section_id, value) {
    // Optional
    if (!value || value.length === 0) {
      return true;
    }

    const validation = main.validateIP(value);

    if (validation.valid) {
      return true;
    }

    return validation.message;
  };

  o = section.taboption(
    "network",
    form.Flag,
    "bypass_excluded_ips",
    _("Bypass sing-box for excluded IPs"),
    _(
      "Traffic of the IP addresses listed above never enters sing-box: the router sends it out directly, which saves CPU (a streaming TV, a game console). They also skip Fully Routed IPs and Global Proxy.",
    ),
  );
  o.default = "0";
  o.rmempty = false;

  o = section.taboption(
    "lists",
    form.ListValue,
    "update_interval",
    _("List Update Frequency"),
    _("Select how often the domain or subnet lists are updated automatically"),
  );
  Object.entries(main.UPDATE_INTERVAL_OPTIONS).forEach(([key, label]) => {
    o.value(key, _(label));
  });
  o.default = "1d";
  o.rmempty = false;

  // --- Lists & Updates tab ---
  o = section.taboption(
    "lists",
    form.Flag,
    "update_notice",
    _("Notify about new versions"),
    _(
      "Show a notice on the dashboard when a newer NetShift or sing-box-extended version is out. When the dashboard is opened and the last check is more than a day old, the router asks GitHub once in the background; nothing is installed.",
    ),
  );
  o.default = "1";
  o.rmempty = false;

  o = section.taboption(
    "lists",
    form.Flag,
    "download_lists_via_proxy",
    _("Download Lists via Proxy/VPN"),
    _("Downloading all lists via specific Proxy/VPN"),
  );
  o.default = "0";
  o.rmempty = false;

  o = section.taboption(
    "lists",
    form.ListValue,
    "download_lists_via_proxy_section",
    _("Download Lists via specific proxy section"),
    _("Downloading all lists via specific Proxy/VPN"),
  );

  o.rmempty = false;
  o.depends("download_lists_via_proxy", "1");
  o.depends("download_components_via_proxy", "1");
  o.cfgvalue = function (section_id) {
    return uci.get("netshift", section_id, "download_lists_via_proxy_section");
  };
  o.load = function () {
    const sections = this.map?.data?.state?.values?.netshift ?? {};

    this.keylist = [];
    this.vallist = [];

    for (const secName in sections) {
      const sec = sections[secName];
      if (
        sec[".type"] === "section" &&
        sec["connection_type"] !== "block" &&
        sec["connection_type"] !== "dns" &&
        sec["connection_type"] !== "exclusion" &&
        sec["disabled"] !== "1"
      ) {
        this.keylist.push(secName);
        this.vallist.push(secName);
      }
    }

    return Promise.resolve();
  };

  o = section.taboption(
    "lists",
    form.Flag,
    "download_components_via_proxy",
    _("Download components via Proxy/VPN"),
    _(
      "Download sing-box, NetShift packages and release information through the proxy section selected below. Useful when GitHub is blocked; a failed download falls back to a direct connection.",
    ),
  );
  o.default = "0";
  o.rmempty = false;

  o = section.taboption(
    "yacd",
    form.Flag,
    "dashboard_widgets",
    _("Show the tiles on the dashboard"),
    _(
      "The tiles with the traffic, the total traffic, the system information and the services above the lists of servers. Turn them off to leave only the servers.",
    ),
  );
  o.default = "1";
  o.rmempty = false;

  // --- Dashboard / YACD tab ---
  o = section.taboption(
    "yacd",
    form.Flag,
    "enable_yacd",
    _("Enable YACD"),
    `<a href="${main.getClashUIUrl()}" target="_blank">${main.getClashUIUrl()}</a>`,
  );
  o.default = "0";
  o.rmempty = false;

  o = section.taboption(
    "yacd",
    form.Flag,
    "enable_yacd_wan_access",
    _("Enable YACD WAN Access"),
    _(
      "Allows access to YACD from the WAN. Make sure to open the appropriate port in your firewall.",
    ),
  );
  o.depends("enable_yacd", "1");
  o.default = "0";
  o.rmempty = false;

  o = section.taboption(
    "yacd",
    form.Value,
    "yacd_secret_key",
    _("YACD Secret Key"),
    _(
      "Secret key for authenticating remote access to YACD when WAN access is enabled.",
    ),
  );
  o.depends("enable_yacd_wan_access", "1");
  o.rmempty = false;

  o = section.taboption(
    "advanced",
    form.Flag,
    "enable_ipv6",
    _("Enable IPv6 Support"),
    _("Enable IPv6 TProxy routing, IPv6 DNS inbound, and IPv6 FakeIP support.") +
      " " +
      _("Use this only when the router has working IPv6 connectivity."),
  );
  o.default = "0";
  o.rmempty = false;

  // --- Advanced tab ---
  o = section.taboption(
    "advanced",
    form.ListValue,
    "disable_quic",
    _("Disable QUIC"),
    _(
      "Disable the QUIC protocol to improve compatibility or fix issues with video streaming. Only the QUIC that goes through the tunnel: the app falls back to TCP, traffic that goes out directly is not touched. All QUIC: also the QUIC that goes out directly, every UDP/443 packet from the network is refused.",
    ),
  );
  o.value("0", _("Off"));
  o.value("1", _("Only QUIC through the tunnel"));
  o.value("all", _("All QUIC (UDP/443)"));
  o.default = "0";
  o.rmempty = false;

  o = section.taboption(
    "advanced",
    form.Flag,
    "block_doh",
    _("Block DoH Servers"),
    _(
      "Block direct connections to known public DoH servers (Cloudflare, Google, Quad9, OpenDNS, AdGuard, Yandex) so apps cannot bypass router DNS filtering.",
    ),
  );
  o.default = "0";
  o.rmempty = false;

  o = section.taboption(
    "advanced",
    form.Flag,
    "block_leaks",
    _("Block Leaks When Tunnel Is Down"),
    _(
      "Fail-closed kill switch: while NetShift is not intercepting traffic — service restart or sing-box crash/recovery — traffic bound for proxied destinations is blocked instead of leaking straight to the internet, and DNS is not handed back to the direct resolvers, so proxied domains wait too. Boot before NetShift's first start is not covered.",
    ) +
      " " +
      _(
        "While sing-box is down, DNS (and therefore name resolution) is unavailable until it recovers. Direct non-proxied traffic is unaffected while sing-box is up.",
      ),
  );
  o.default = "0";
  o.rmempty = false;

  o = section.taboption(
    "advanced",
    form.Flag,
    "exclude_ntp",
    _("Exclude NTP"),
    _(
      "Exclude NTP protocol traffic from the tunnel to prevent it from being routed through the proxy or VPN",
    ),
  );
  o.default = "0";
  o.rmempty = false;

  o = section.taboption(
    "advanced",
    form.Flag,
    "exclude_bittorrent",
    _("Exclude BitTorrent"),
    _(
      "Route BitTorrent traffic directly, bypassing the proxy or VPN. Some providers block subscriptions when they detect torrent traffic.",
    ),
  );
  o.default = "0";
  o.rmempty = false;

  o = section.taboption(
    "advanced",
    form.Flag,
    "dont_touch_dhcp",
    _("Dont Touch My DHCP!"),
    _("NetShift will not modify your DHCP configuration"),
  );
  o.default = "0";
  o.rmempty = false;

  o = section.taboption(
    "advanced",
    form.Value,
    "latency_test_url",
    _("Latency test URL"),
    _(
      "The URL the dashboard uses to measure server latency. Change it if the default is slow or blocked in your region.",
    ),
  );
  o.value(
    "https://www.gstatic.com/generate_204",
    "https://www.gstatic.com/generate_204 (Google)",
  );
  o.value(
    "https://cp.cloudflare.com/generate_204",
    "https://cp.cloudflare.com/generate_204 (Cloudflare)",
  );
  o.value("https://captive.apple.com", "https://captive.apple.com (Apple)");
  o.default = "https://www.gstatic.com/generate_204";
  o.rmempty = true;
  o.validate = function (section_id, value) {
    if (!value || value.length === 0) {
      return true;
    }

    const validation = main.validateUrl(value);

    if (validation.valid) {
      return true;
    }

    return validation.message;
  };

  o = section.taboption(
    "advanced",
    form.ListValue,
    "config_path",
    _("Config File Path"),
    _(
      "Select path for sing-box config file. Change this ONLY if you know what you are doing",
    ),
  );
  o.value("/etc/sing-box/config.json", "Flash (/etc/sing-box/config.json)");
  o.value("/tmp/sing-box/config.json", "RAM (/tmp/sing-box/config.json)");
  o.default = "/etc/sing-box/config.json";
  o.rmempty = false;

  o = section.taboption(
    "advanced",
    form.Value,
    "cache_path",
    _("Cache File Path"),
    _(
      "Select or enter path for sing-box cache file. Change this ONLY if you know what you are doing",
    ),
  );
  o.value("/tmp/sing-box/cache.db", "RAM (/tmp/sing-box/cache.db)");
  o.value(
    "/usr/share/sing-box/cache.db",
    "Flash (/usr/share/sing-box/cache.db)",
  );
  o.default = "/tmp/sing-box/cache.db";
  o.rmempty = false;
  o.validate = function (section_id, value) {
    if (!value) {
      return _("Cache file path cannot be empty");
    }

    if (!value.startsWith("/")) {
      return _("Path must be absolute (start with /)");
    }

    if (!value.endsWith("cache.db")) {
      return _("Path must end with cache.db");
    }

    const parts = value.split("/").filter(Boolean);
    if (parts.length < 2) {
      return _("Path must contain at least one directory (like /tmp/cache.db)");
    }

    return true;
  };

  o = section.taboption(
    "advanced",
    form.ListValue,
    "log_level",
    _("Log Level"),
    _("Select the log level for sing-box"),
  );
  o.value("trace", "Trace");
  o.value("debug", "Debug");
  o.value("info", "Info");
  o.value("warn", "Warn");
  o.value("error", "Error");
  o.value("fatal", "Fatal");
  o.value("panic", "Panic");
  o.default = "warn";
  o.rmempty = false;

}

const EntryPoint = {
  createSettingsContent,
};

return baseclass.extend(EntryPoint);
