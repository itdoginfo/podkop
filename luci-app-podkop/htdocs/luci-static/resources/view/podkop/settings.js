"use strict";
"require form";
"require uci";
"require baseclass";
"require tools.widgets as widgets";
"require view.podkop.main as main";

function createSettingsContent(section) {
  let o = section.option(
    form.ListValue,
    "dns_type",
    _("DNS Protocol Type"),
    _("Select DNS protocol to use"),
  );
  o.value("doh", _("DNS over HTTPS (DoH)"));
  o.value("dot", _("DNS over TLS (DoT)"));
  o.value("udp", _("UDP (Unprotected DNS)"));
  o.default = "udp";
  o.rmempty = false;

  o = section.option(
    form.Value,
    "dns_server",
    _("DNS Server"),
    _("Select or enter DNS server address"),
  );
  Object.entries(main.DNS_SERVER_OPTIONS).forEach(([key, label]) => {
    o.value(key, _(label));
  });
  o.default = "8.8.8.8";
  o.rmempty = false;
  o.validate = function (section_id, value) {
    const validation = main.validateDNS(value);

    if (validation.valid) {
      return true;
    }

    return validation.message;
  };

  o = section.option(
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

  o = section.option(
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

  o = section.option(
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

  o = section.option(
    form.Flag,
    "enable_output_network_interface",
    _("Enable Output Network Interface"),
    _("You can select Output Network Interface, by default autodetect"),
  );
  o.default = "0";
  o.rmempty = false;

  o = section.option(
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
    if (
        value.startsWith("lan")
    ) {
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

  o = section.option(
    form.Flag,
    "enable_badwan_interface_monitoring",
    _("Interface Monitoring"),
    _("Interface monitoring for Bad WAN"),
  );
  o.default = "0";
  o.rmempty = false;

  o = section.option(
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

  o = section.option(
    form.Value,
    "badwan_reload_delay",
    _("Interface Monitoring Delay"),
    _("Delay in milliseconds before reloading podkop after interface UP"),
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

  o = section.option(
    form.Flag,
    "enable_yacd",
    _("Enable YACD"),
    `<a href="${main.getClashUIUrl()}" target="_blank">${main.getClashUIUrl()}</a>`,
  );
  o.default = "0";
  o.rmempty = false;

  o = section.option(
    form.Flag,
    "enable_yacd_wan_access",
    _("Enable YACD WAN Access"),
    _("Allows access to YACD from the WAN. Make sure to open the appropriate port in your firewall."),
  );
  o.depends("enable_yacd", "1");
  o.default = "0";
  o.rmempty = false;

  o = section.option(
    form.Value,
    "yacd_secret_key",
    _("YACD Secret Key"),
    _("Secret key for authenticating remote access to YACD when WAN access is enabled."),
  );
  o.depends("enable_yacd_wan_access", "1");
  o.rmempty = false;

  o = section.option(
    form.Flag,
    "disable_quic",
    _("Disable QUIC"),
    _(
      "Disable the QUIC protocol to improve compatibility or fix issues with video streaming",
    ),
  );
  o.default = "0";
  o.rmempty = false;

  o = section.option(
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

  o = section.option(
    form.Flag,
    "download_lists_via_proxy",
    _("Download Lists via Proxy/VPN"),
    _("Downloading all lists via specific Proxy/VPN"),
  );
  o.default = "0";
  o.rmempty = false;

  o = section.option(
    form.ListValue,
    "download_lists_via_proxy_section",
    _("Download Lists via specific proxy section"),
    _("Downloading all lists via specific Proxy/VPN"),
  );

  o.rmempty = false;
  o.depends("download_lists_via_proxy", "1");
  o.cfgvalue = function (section_id) {
    return uci.get("podkop", section_id, "download_lists_via_proxy_section");
  };
  o.load = function () {
    const sections = this.map?.data?.state?.values?.podkop ?? {};

    this.keylist = [];
    this.vallist = [];

    for (const secName in sections) {
      const sec = sections[secName];
      if (sec[".type"] === "section") {
        this.keylist.push(secName);
        this.vallist.push(secName);
      }
    }

    return Promise.resolve();
  };

  o = section.option(
    form.Flag,
    "dont_touch_dhcp",
    _("Dont Touch My DHCP!"),
    _("Podkop will not modify your DHCP configuration"),
  );
  o.default = "0";
  o.rmempty = false;

  o = section.option(
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

  o = section.option(
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

  o = section.option(
    form.ListValue,
    "log_level",
    _("Log Level"),
    _(
      "Select the log level for sing-box",
    ),
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

  o = section.option(
    form.Flag,
    "exclude_ntp",
    _("Exclude NTP"),
    _(
      "Exclude NTP protocol traffic from the tunnel to prevent it from being routed through the proxy or VPN",
    ),
  );
  o.default = "0";
  o.rmempty = false;

  o = section.option(
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

    const validation = main.validateIPV4(value);

    if (validation.valid) {
      return true;
    }

    return validation.message;
  };
}

const EntryPoint = {
  createSettingsContent,
};

return baseclass.extend(EntryPoint);
