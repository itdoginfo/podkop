"use strict";
"require form";
"require baseclass";
"require ui";
"require tools.widgets as widgets";
"require view.netshift.main as main";

function createSectionContent(section) {
  // Group the 36 connection options into 4 native CBI option-group tabs.
  // HARD RULE: once a section has tab(), every option MUST be added via
  // taboption() — any leftover section.option(...) renders nothing.
  // depends() works across tabs; a tab whose options are all depends-hidden
  // auto-hides from the strip (desired, e.g. Subscription for proxy/url).
  section.tab(
    "connection",
    _("Connection"),
    _("Connection type, transport and DNS resolver for this section"),
  );
  section.tab(
    "subscription",
    _("Subscription"),
    _("Subscription feeds, server filters and URLTest tuning"),
  );
  section.tab(
    "routing",
    _("Routing"),
    _("Domain and subnet lists that decide which traffic uses this section"),
  );
  section.tab(
    "advanced",
    _("Advanced"),
    _("Mixed proxy and DNS resolution tuning"),
  );

  let o = section.taboption(
    "connection",
    form.ListValue,
    "connection_type",
    _("Connection Type"),
    _("Select between VPN and Proxy connection methods for traffic routing"),
  );
  o.value("proxy", "Proxy");
  o.value("vpn", "VPN");
  o.value("block", "Block");
  o.value("exclusion", "Exclusion");

  o = section.taboption(
    "connection",
    form.ListValue,
    "proxy_config_type",
    _("Configuration Type"),
    _("Select how to configure the proxy"),
  );
  o.value("url", _("Connection URL"));
  o.value("selector", _("Selector"));
  o.value("urltest", _("URLTest"));
  o.value("subscription", _("Subscription"));
  o.value("outbound", _("Outbound Config"));
  o.default = "url";
  o.depends("connection_type", "proxy");

  o = section.taboption(
    "connection",
    form.TextValue,
    "proxy_string",
    _("Proxy Configuration URL"),
    _(
      "vless://, vmess://, ss://, trojan://, socks4/5://, hy2/hysteria2:// links",
    ),
  );
  o.depends({ connection_type: "proxy", proxy_config_type: "url" });
  o.rows = 5;
  // Enable soft wrapping for multi-line proxy URLs (e.g., for URLTest proxy links)
  o.wrap = "soft";
  // Render as a textarea to allow multiple proxy URLs/configs
  o.textarea = true;
  o.rmempty = false;
  o.sectionDescriptions = new Map();
  o.validate = function (section_id, value) {
    // Optional
    if (!value || value.length === 0) {
      return true;
    }

    const validation = main.validateProxyUrl(value);

    if (validation.valid) {
      return true;
    }

    return validation.message;
  };

  o = section.taboption(
    "connection",
    form.TextValue,
    "outbound_json",
    _("Outbound Configuration"),
    _("Enter complete outbound configuration in JSON format"),
  );
  o.depends({ connection_type: "proxy", proxy_config_type: "outbound" });
  o.rows = 10;
  o.validate = function (section_id, value) {
    // Optional
    if (!value || value.length === 0) {
      return true;
    }

    const validation = main.validateOutboundJson(value);

    if (validation.valid) {
      return true;
    }

    return validation.message;
  };

  o = section.taboption(
    "subscription",
    form.DynamicList,
    "subscription_url",
    _("Subscription URLs"),
    _(
      "Add one or more subscription URLs to fetch proxy configurations from. All feeds are downloaded and merged.",
    ),
  );
  o.depends({ connection_type: "proxy", proxy_config_type: "subscription" });
  o.placeholder = "https://example.com/api/sub";
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
    "subscription",
    form.ListValue,
    "subscription_format_preference",
    _("Subscription format"),
    _(
      "Which subscription format (client) to fetch first. Auto uses the default order. Choose Xray JSON (Happ) when your panel only exposes some nodes (e.g. xhttp) under a Happ-like client, or Sing-box to prefer the sing-box format.",
    ),
  );
  o.value("auto", _("Auto"));
  o.value("xray", _("Xray JSON (Happ)"));
  o.value("singbox", _("Sing-box"));
  o.default = "auto";
  o.depends({ connection_type: "proxy", proxy_config_type: "subscription" });

  o = section.taboption(
    "subscription",
    form.Flag,
    "subscription_insecure",
    _("Allow insecure TLS for subscription fetch"),
    _("Disables TLS certificate verification when downloading the subscription.") +
      " " +
      _("Use only for IP-host panels that serve an invalid or self-signed certificate.") +
      " " +
      _("This is a security trade-off: an attacker could intercept the fetch."),
  );
  o.default = "0";
  o.rmempty = false;
  o.depends({ connection_type: "proxy", proxy_config_type: "subscription" });

  o = section.taboption(
    "subscription",
    form.ListValue,
    "subscription_update_interval",
    _("Subscription Update Interval"),
    _("How often to automatically update the subscription"),
  );
  o.value("30m", _("Every 30 minutes"));
  o.value("1h", _("Every hour"));
  o.value("3h", _("Every 3 hours"));
  o.value("6h", _("Every 6 hours"));
  o.value("12h", _("Every 12 hours"));
  o.value("1d", _("Every day"));
  o.default = "1h";
  o.depends({ connection_type: "proxy", proxy_config_type: "subscription" });

  o = section.taboption(
    "subscription",
    form.ListValue,
    "subscription_group_mode",
    _("Subscription grouping"),
    _(
      "Group subscription proxies into URLTest groups. 'By country flag' uses the flag emoji at the start of each name; 'By name prefix' groups by the first N characters.",
    ),
  );
  o.value("off", _("Off"));
  o.value("country", _("By country flag"));
  o.value("prefix", _("By name prefix"));
  o.default = "off";
  o.rmempty = false;
  o.depends({ connection_type: "proxy", proxy_config_type: "subscription" });

  o = section.taboption(
    "subscription",
    form.Value,
    "subscription_group_prefix_len",
    _("Prefix length"),
    _("Number of leading characters of each proxy name to group by."),
  );
  o.default = "2";
  o.datatype = "and(uinteger,min(1))";
  o.rmempty = false;
  o.depends({
    connection_type: "proxy",
    proxy_config_type: "subscription",
    subscription_group_mode: "prefix",
  });

  o = section.taboption(
    "subscription",
    form.DynamicList,
    "subscription_filter_include_keywords",
    _("Include servers by keyword"),
    _(
      "Keep only subscription servers whose name contains at least one of these keywords (case-insensitive). Leave empty to keep all.",
    ),
  );
  o.depends({ connection_type: "proxy", proxy_config_type: "subscription" });
  o.rmempty = true;

  o = section.taboption(
    "subscription",
    form.DynamicList,
    "subscription_filter_exclude_keywords",
    _("Exclude servers by keyword"),
    _(
      "Drop subscription servers whose name contains any of these keywords (case-insensitive).",
    ),
  );
  o.depends({ connection_type: "proxy", proxy_config_type: "subscription" });
  o.rmempty = true;

  o = section.taboption(
    "connection",
    form.DynamicList,
    "selector_proxy_links",
    _("Selector Proxy Links"),
    _(
      "vless://, vmess://, ss://, trojan://, socks4/5://, hy2/hysteria2:// links",
    ),
  );
  o.depends({ connection_type: "proxy", proxy_config_type: "selector" });
  o.rmempty = false;
  o.validate = function (section_id, value) {
    // Optional
    if (!value || value.length === 0) {
      return true;
    }

    const validation = main.validateProxyUrl(value);

    if (validation.valid) {
      return true;
    }

    return validation.message;
  };

  o = section.taboption(
    "subscription",
    form.DynamicList,
    "urltest_proxy_links",
    _("URLTest Proxy Links"),
    _(
      "vless://, vmess://, ss://, trojan://, socks4/5://, hy2/hysteria2:// links",
    ),
  );
  o.depends({ connection_type: "proxy", proxy_config_type: "urltest" });
  o.rmempty = false;
  o.validate = function (section_id, value) {
    // Optional
    if (!value || value.length === 0) {
      return true;
    }

    const validation = main.validateProxyUrl(value);

    if (validation.valid) {
      return true;
    }

    return validation.message;
  };

  o = section.taboption(
    "subscription",
    form.ListValue,
    "urltest_check_interval",
    _("URLTest Check Interval"),
    _("The interval between connectivity tests"),
  );
  o.value("30s", _("Every 30 seconds"));
  o.value("1m", _("Every 1 minute"));
  o.value("3m", _("Every 3 minutes"));
  o.value("5m", _("Every 5 minutes"));
  o.default = "3m";
  o.depends({ connection_type: "proxy", proxy_config_type: "urltest" });
  o.depends({ connection_type: "proxy", proxy_config_type: "subscription" });

  o = section.taboption(
    "subscription",
    form.Value,
    "urltest_tolerance",
    _("URLTest Tolerance"),
    _(
      "The maximum difference in response times (ms) allowed when comparing servers",
    ),
  );
  o.default = "50";
  o.rmempty = false;
  o.depends({ connection_type: "proxy", proxy_config_type: "urltest" });
  o.depends({ connection_type: "proxy", proxy_config_type: "subscription" });
  o.validate = function (section_id, value) {
    if (!value || value.length === 0) {
      return true;
    }

    const parsed = parseFloat(value);

    if (
      /^[0-9]+$/.test(value) &&
      !isNaN(parsed) &&
      isFinite(parsed) &&
      parsed >= 50 &&
      parsed <= 1000
    ) {
      return true;
    }

    return _("Must be a number in the range of 50 - 1000");
  };

  o = section.taboption(
    "subscription",
    form.Value,
    "urltest_testing_url",
    _("URLTest Testing URL"),
    _("The URL used to test server connectivity"),
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
  o.value(
    "https://connectivity-check.ubuntu.com",
    "https://connectivity-check.ubuntu.com (Ubuntu)",
  );
  o.default = "https://www.gstatic.com/generate_204";
  o.rmempty = false;
  o.depends({ connection_type: "proxy", proxy_config_type: "urltest" });
  o.depends({ connection_type: "proxy", proxy_config_type: "subscription" });

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
    "connection",
    form.Flag,
    "enable_udp_over_tcp",
    _("UDP over TCP"),
    _("Applicable for SOCKS and Shadowsocks proxy"),
  );
  o.default = "0";
  o.depends("connection_type", "proxy");
  o.rmempty = false;

  o = section.taboption(
    "connection",
    form.Flag,
    "global_proxy",
    _("Global Proxy"),
    _("Route all unmatched traffic through this section's outbound.") +
      " " +
      _(
        "When enabled, traffic not matching any other section's lists will go through this proxy.",
      ) +
      " " +
      _("Use with Exclusion sections to route specific domains directly.") +
      " " +
      _("Only one section can be global at a time."),
  );
  o.default = "0";
  o.rmempty = false;

  o = section.taboption(
    "connection",
    widgets.DeviceSelect,
    "interface",
    _("Network Interface"),
    _("Select network interface for VPN connection"),
  );
  o.depends("connection_type", "vpn");
  o.noaliases = true;
  o.nobridges = false;
  o.noinactive = false;
  o.filter = function (section_id, value) {
    // Blocked interface names that should never be selectable
    const blockedInterfaces = [
      "br-lan",
      "eth0",
      "eth1",
      "wan",
      "phy0-ap0",
      "phy1-ap0",
      "pppoe-wan",
      "lan",
    ];

    // Reject immediately if the value matches any blocked interface
    if (blockedInterfaces.includes(value)) {
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
    "connection",
    form.Flag,
    "domain_resolver_enabled",
    _("Domain Resolver"),
    _("Enable built-in DNS resolver for domains handled by this section"),
  );
  o.default = "0";
  o.rmempty = false;
  o.depends("connection_type", "vpn");

  o = section.taboption(
    "connection",
    form.ListValue,
    "domain_resolver_dns_type",
    _("DNS Protocol Type"),
    _("Select the DNS protocol type for the domain resolver"),
  );
  o.value("doh", _("DNS over HTTPS (DoH)"));
  o.value("dot", _("DNS over TLS (DoT)"));
  o.value("udp", _("UDP (Unprotected DNS)"));
  o.default = "udp";
  o.rmempty = false;
  o.depends("domain_resolver_enabled", "1");

  o = section.taboption(
    "connection",
    form.Value,
    "domain_resolver_dns_server",
    _("DNS Server"),
    _("Select or enter DNS server address"),
  );
  Object.entries(main.DNS_SERVER_OPTIONS).forEach(([key, label]) => {
    o.value(key, _(label));
  });
  o.default = "8.8.8.8";
  o.rmempty = false;
  o.depends("domain_resolver_enabled", "1");
  o.validate = function (section_id, value) {
    const validation = main.validateDNS(value);

    if (validation.valid) {
      return true;
    }

    return validation.message;
  };

  o = section.taboption(
    "routing",
    form.DynamicList,
    "community_lists",
    _("Community Lists"),
    _("Select a predefined list for routing") +
      ' <a href="https://github.com/itdoginfo/allow-domains" target="_blank">github.com/itdoginfo/allow-domains</a>',
  );
  o.placeholder = "Service list";
  Object.entries(main.DOMAIN_LIST_OPTIONS).forEach(([key, label]) => {
    o.value(key, _(label));
  });
  o.rmempty = true;
  let lastValues = [];
  let isProcessing = false;

  o.onchange = function (ev, section_id, value) {
    if (isProcessing) return;
    isProcessing = true;

    try {
      const values = Array.isArray(value) ? value : [value];
      let newValues = [...values];
      let notifications = [];

      const selectedRegionalOptions = main.REGIONAL_OPTIONS.filter((opt) =>
        newValues.includes(opt),
      );

      if (selectedRegionalOptions.length > 1) {
        const lastSelected =
          selectedRegionalOptions[selectedRegionalOptions.length - 1];
        const removedRegions = selectedRegionalOptions.slice(0, -1);
        newValues = newValues.filter(
          (v) => v === lastSelected || !main.REGIONAL_OPTIONS.includes(v),
        );
        notifications.push(
          E("p", {}, [
            E("strong", {}, _("Regional options cannot be used together")),
            E("br"),
            _(
              "Warning: %s cannot be used together with %s. Previous selections have been removed.",
            ).format(removedRegions.join(", "), lastSelected),
          ]),
        );
      }

      if (newValues.includes("russia_inside")) {
        const removedServices = newValues.filter(
          (v) => !main.ALLOWED_WITH_RUSSIA_INSIDE.includes(v),
        );
        if (removedServices.length > 0) {
          newValues = newValues.filter((v) =>
            main.ALLOWED_WITH_RUSSIA_INSIDE.includes(v),
          );
          notifications.push(
            E("p", { class: "alert-message warning" }, [
              E("strong", {}, _("Russia inside restrictions")),
              E("br"),
              _(
                "Warning: Russia inside can only be used with %s. %s already in Russia inside and have been removed from selection.",
              ).format(
                main.ALLOWED_WITH_RUSSIA_INSIDE.map(
                  (key) => main.DOMAIN_LIST_OPTIONS[key],
                )
                  .filter((label) => label !== "Russia inside")
                  .join(", "),
                removedServices.join(", "),
              ),
            ]),
          );
        }
      }

      if (JSON.stringify(newValues.sort()) !== JSON.stringify(values.sort())) {
        this.getUIElement(section_id).setValue(newValues);
      }

      notifications.forEach((notification) =>
        ui.addNotification(null, notification),
      );
      lastValues = newValues;
    } catch (e) {
      console.error("Error in onchange handler:", e);
    } finally {
      isProcessing = false;
    }
  };

  // --- Custom domains group (mode selector + the matching input below) ---
  // Three UCI keys kept (user_domain_list_type, user_domains,
  // user_domains_text); depends() shows only the input for the chosen mode,
  // so the trio reads as one "list-or-text" control.
  o = section.taboption(
    "routing",
    form.ListValue,
    "user_domain_list_type",
    _("Custom domains"),
    _(
      "Add your own domains: choose Dynamic List (one per row) or Text List (free-form), or Disabled to skip",
    ),
  );
  o.value("disabled", _("Disabled"));
  o.value("dynamic", _("Dynamic List"));
  o.value("text", _("Text List"));
  o.default = "disabled";
  o.rmempty = false;

  o = section.taboption(
    "routing",
    form.DynamicList,
    "user_domains",
    _("User Domains"),
    _(
      "Enter domain names without protocols, e.g. example.com or sub.example.com",
    ),
  );
  o.placeholder = "Domains list";
  o.depends("user_domain_list_type", "dynamic");
  o.rmempty = false;
  o.validate = function (section_id, value) {
    // Optional
    if (!value || value.length === 0) {
      return true;
    }

    const validation = main.validateDomain(value, true);

    if (validation.valid) {
      return true;
    }

    return validation.message;
  };

  o = section.taboption(
    "routing",
    form.TextValue,
    "user_domains_text",
    _("User Domains List"),
    _(
      "Enter domain names separated by commas, spaces, or newlines. You can add comments using //",
    ),
  );
  o.placeholder =
    "example.com, sub.example.com\n// Social networks\ndomain.com test.com // personal domains";
  o.depends("user_domain_list_type", "text");
  o.rows = 8;
  o.rmempty = false;
  o.validate = function (section_id, value) {
    // Optional
    if (!value || value.length === 0) {
      return true;
    }

    const domains = main.parseValueList(value);

    if (!domains.length) {
      return _(
        "At least one valid domain must be specified. Comments-only content is not allowed.",
      );
    }

    const { valid, results } = main.bulkValidate(domains, (row) =>
      main.validateDomain(row, true),
    );

    if (!valid) {
      const errors = results
        .filter((validation) => !validation.valid) // Leave only failed validations
        .map((validation) => `${validation.value}: ${validation.message}`); // Collect validation errors

      return [_("Validation errors:"), ...errors].join("\n");
    }

    return true;
  };

  // --- Custom subnets group (mode selector + the matching input below) ---
  // Same pattern as the domains group; keeps user_subnet_list_type,
  // user_subnets and user_subnets_text as separate UCI keys.
  o = section.taboption(
    "routing",
    form.ListValue,
    "user_subnet_list_type",
    _("Custom subnets"),
    _(
      "Add your own subnets or IPs: choose Dynamic List (one per row) or Text List (free-form), or Disabled to skip",
    ),
  );
  o.value("disabled", _("Disabled"));
  o.value("dynamic", _("Dynamic List"));
  o.value("text", _("Text List"));
  o.default = "disabled";
  o.rmempty = false;

  o = section.taboption(
    "routing",
    form.DynamicList,
    "user_subnets",
    _("User Subnets"),
    _(
      "Enter subnets in CIDR notation (e.g. 103.21.244.0/22) or single IP addresses",
    ),
  );
  o.placeholder = "IP or subnet";
  o.depends("user_subnet_list_type", "dynamic");
  o.rmempty = false;
  o.validate = function (section_id, value) {
    // Optional
    if (!value || value.length === 0) {
      return true;
    }

    const validation = main.validateSubnet(value);

    if (validation.valid) {
      return true;
    }

    return validation.message;
  };

  o = section.taboption(
    "routing",
    form.TextValue,
    "user_subnets_text",
    _("User Subnets List"),
    _(
      "Enter subnets in CIDR notation or single IP addresses, separated by commas, spaces, or newlines. " +
        "You can add comments using //",
    ),
  );
  o.placeholder =
    "103.21.244.0/22\n// Google DNS\n8.8.8.8\n1.1.1.1/32, 9.9.9.9 // Cloudflare and Quad9";
  o.depends("user_subnet_list_type", "text");
  o.rows = 10;
  o.rmempty = false;
  o.validate = function (section_id, value) {
    // Optional
    if (!value || value.length === 0) {
      return true;
    }

    const subnets = main.parseValueList(value);

    if (!subnets.length) {
      return _(
        "At least one valid subnet or IP must be specified. Comments-only content is not allowed.",
      );
    }

    const { valid, results } = main.bulkValidate(subnets, main.validateSubnet);

    if (!valid) {
      const errors = results
        .filter((validation) => !validation.valid) // Leave only failed validations
        .map((validation) => `${validation.value}: ${validation.message}`); // Collect validation errors

      return [_("Validation errors:"), ...errors].join("\n");
    }

    return true;
  };

  o = section.taboption(
    "routing",
    form.DynamicList,
    "local_domain_lists",
    _("Local Domain Lists"),
    _("Specify the path to the list file located on the router filesystem"),
  );
  o.placeholder = "/path/file.lst";
  o.rmempty = true;
  o.validate = function (section_id, value) {
    // Optional
    if (!value || value.length === 0) {
      return true;
    }

    const validation = main.validatePath(value);

    if (validation.valid) {
      return true;
    }

    return validation.message;
  };

  o = section.taboption(
    "routing",
    form.DynamicList,
    "local_subnet_lists",
    _("Local Subnet Lists"),
    _("Specify the path to the list file located on the router filesystem"),
  );
  o.placeholder = "/path/file.lst";
  o.rmempty = true;
  o.validate = function (section_id, value) {
    // Optional
    if (!value || value.length === 0) {
      return true;
    }

    const validation = main.validatePath(value);

    if (validation.valid) {
      return true;
    }

    return validation.message;
  };

  o = section.taboption(
    "routing",
    form.DynamicList,
    "remote_domain_lists",
    _("Remote Domain Lists"),
    _("Specify remote URLs to download and use domain lists"),
  );
  o.placeholder = "https://example.com/domains.srs";
  o.rmempty = true;
  o.validate = function (section_id, value) {
    // Optional
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
    "routing",
    form.DynamicList,
    "remote_subnet_lists",
    _("Remote Subnet Lists"),
    _("Specify remote URLs to download and use subnet lists"),
  );
  o.placeholder = "https://example.com/subnets.srs";
  o.rmempty = true;
  o.validate = function (section_id, value) {
    // Optional
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
    "routing",
    form.DynamicList,
    "fully_routed_ips",
    _("Fully Routed IPs"),
    _(
      "Specify local IP addresses or subnets whose traffic will always be routed through the configured route",
    ),
  );
  o.placeholder = "192.168.1.2 or 192.168.1.0/24";
  o.rmempty = true;
  o.depends("connection_type", "proxy");
  o.depends("connection_type", "vpn");
  o.validate = function (section_id, value) {
    // Optional
    if (!value || value.length === 0) {
      return true;
    }

    const validation = main.validateSubnet(value);

    if (validation.valid) {
      return true;
    }

    return validation.message;
  };

  o = section.taboption(
    "advanced",
    form.Flag,
    "mixed_proxy_enabled",
    _("Enable Mixed Proxy"),
    _(
      "Enable the mixed proxy, allowing this section to route traffic through both HTTP and SOCKS proxies",
    ),
  );
  o.default = "0";
  o.rmempty = false;
  o.depends("connection_type", "proxy");
  o.depends("connection_type", "vpn");

  o = section.taboption(
    "advanced",
    form.Value,
    "mixed_proxy_port",
    _("Mixed Proxy Port"),
    _(
      "Specify the port number on which the mixed proxy will run for this section. " +
        "Make sure the selected port is not used by another service",
    ),
  );
  o.default = "2080";
  o.placeholder = "2080";
  o.datatype = "port";
  o.rmempty = true;
  o.depends("mixed_proxy_enabled", "1");

  o = section.taboption(
    "advanced",
    form.Flag,
    "resolve_real_ip_for_routing",
    _("Resolve real IP for routing"),
    _("Enable DNS resolve to get real IP when routing"),
  );
  o.default = "0";
  o.rmempty = false;
  o.depends("connection_type", "proxy");
  o.depends("connection_type", "vpn");
}

const EntryPoint = {
  createSectionContent,
};

return baseclass.extend(EntryPoint);
