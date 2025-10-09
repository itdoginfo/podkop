'use strict';
'require form';
'require baseclass';
'require tools.widgets as widgets';
'require view.podkop.main as main';

function createAdditionalSection(mainSection) {
  let o = mainSection.tab('additional', _('Additional Settings'));

  o = mainSection.taboption(
    'additional',
    form.Flag,
    'yacd',
    _('Yacd enable'),
    `<a href="${main.getClashUIUrl()}" target="_blank">${main.getClashUIUrl()}</a>`,
  );
  o.default = '0';
  o.rmempty = false;
  o.ucisection = 'main';

  o = mainSection.taboption(
    'additional',
    form.Flag,
    'exclude_ntp',
    _('Exclude NTP'),
    _('Allows you to exclude NTP protocol traffic from the tunnel'),
  );
  o.default = '0';
  o.rmempty = false;
  o.ucisection = 'main';

  o = mainSection.taboption(
    'additional',
    form.Flag,
    'quic_disable',
    _('QUIC disable'),
    _('For issues with the video stream'),
  );
  o.default = '0';
  o.rmempty = false;
  o.ucisection = 'main';

  o = mainSection.taboption(
    'additional',
    form.ListValue,
    'update_interval',
    _('List Update Frequency'),
    _('Select how often the lists will be updated'),
  );
  Object.entries(main.UPDATE_INTERVAL_OPTIONS).forEach(([key, label]) => {
    o.value(key, _(label));
  });
  o.default = '1d';
  o.rmempty = false;
  o.ucisection = 'main';

  o = mainSection.taboption(
    'additional',
    form.ListValue,
    'dns_type',
    _('DNS Protocol Type'),
    _('Select DNS protocol to use'),
  );
  o.value('doh', _('DNS over HTTPS (DoH)'));
  o.value('dot', _('DNS over TLS (DoT)'));
  o.value('udp', _('UDP (Unprotected DNS)'));
  o.default = 'udp';
  o.rmempty = false;
  o.ucisection = 'main';

  o = mainSection.taboption(
    'additional',
    form.Value,
    'dns_server',
    _('DNS Server'),
    _('Select or enter DNS server address'),
  );
  Object.entries(main.DNS_SERVER_OPTIONS).forEach(([key, label]) => {
    o.value(key, _(label));
  });
  o.default = '8.8.8.8';
  o.rmempty = false;
  o.ucisection = 'main';
  o.validate = function (section_id, value) {
    const validation = main.validateDNS(value);

    if (validation.valid) {
      return true;
    }

    return validation.message;
  };

  o = mainSection.taboption(
    'additional',
    form.Value,
    'bootstrap_dns_server',
    _('Bootstrap DNS server'),
    _(
      'The DNS server used to look up the IP address of an upstream DNS server',
    ),
  );
  Object.entries(main.BOOTSTRAP_DNS_SERVER_OPTIONS).forEach(([key, label]) => {
    o.value(key, _(label));
  });
  o.default = '77.88.8.8';
  o.rmempty = false;
  o.ucisection = 'main';
  o.validate = function (section_id, value) {
    const validation = main.validateDNS(value);

    if (validation.valid) {
      return true;
    }

    return validation.message;
  };

  o = mainSection.taboption(
    'additional',
    form.Value,
    'dns_rewrite_ttl',
    _('DNS Rewrite TTL'),
    _('Time in seconds for DNS record caching (default: 60)'),
  );
  o.default = '60';
  o.rmempty = false;
  o.ucisection = 'main';
  o.validate = function (section_id, value) {
    if (!value) {
      return _('TTL value cannot be empty');
    }

    const ttl = parseInt(value);
    if (isNaN(ttl) || ttl < 0) {
      return _('TTL must be a positive number');
    }

    return true;
  };

  o = mainSection.taboption(
    'additional',
    form.ListValue,
    'config_path',
    _('Config File Path'),
    _(
      'Select path for sing-box config file. Change this ONLY if you know what you are doing',
    ),
  );
  o.value('/etc/sing-box/config.json', 'Flash (/etc/sing-box/config.json)');
  o.value('/tmp/sing-box/config.json', 'RAM (/tmp/sing-box/config.json)');
  o.default = '/etc/sing-box/config.json';
  o.rmempty = false;
  o.ucisection = 'main';

  o = mainSection.taboption(
    'additional',
    form.Value,
    'cache_path',
    _('Cache File Path'),
    _(
      'Select or enter path for sing-box cache file. Change this ONLY if you know what you are doing',
    ),
  );
  o.value('/tmp/sing-box/cache.db', 'RAM (/tmp/sing-box/cache.db)');
  o.value(
    '/usr/share/sing-box/cache.db',
    'Flash (/usr/share/sing-box/cache.db)',
  );
  o.default = '/tmp/sing-box/cache.db';
  o.rmempty = false;
  o.ucisection = 'main';
  o.validate = function (section_id, value) {
    if (!value) {
      return _('Cache file path cannot be empty');
    }

    if (!value.startsWith('/')) {
      return _('Path must be absolute (start with /)');
    }

    if (!value.endsWith('cache.db')) {
      return _('Path must end with cache.db');
    }

    const parts = value.split('/').filter(Boolean);
    if (parts.length < 2) {
      return _('Path must contain at least one directory (like /tmp/cache.db)');
    }

    return true;
  };

  o = mainSection.taboption(
    'additional',
    widgets.DeviceSelect,
    'iface',
    _('Source Network Interface'),
    _('Select the network interface from which the traffic will originate'),
  );
  o.ucisection = 'main';
  o.default = 'br-lan';
  o.noaliases = true;
  o.nobridges = false;
  o.noinactive = false;
  o.multiple = true;
  o.filter = function (section_id, value) {
    // Block specific interface names from being selectable
    const blocked = ['wan', 'phy0-ap0', 'phy1-ap0', 'pppoe-wan'];
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
      type === 'wifi' || type === 'wireless' || type.includes('wlan');

    // Allow only non-wireless devices
    return !isWireless;
  };

  o = mainSection.taboption(
    'additional',
    form.Flag,
    'mon_restart_ifaces',
    _('Interface monitoring'),
    _('Interface monitoring for bad WAN'),
  );
  o.default = '0';
  o.rmempty = false;
  o.ucisection = 'main';

  o = mainSection.taboption(
    'additional',
    widgets.NetworkSelect,
    'restart_ifaces',
    _('Interface for monitoring'),
    _('Select the WAN interfaces to be monitored'),
  );
  o.ucisection = 'main';
  o.depends('mon_restart_ifaces', '1');
  o.multiple = true;
  o.filter = function (section_id, value) {
    // Reject if the value is in the blocked list ['lan', 'loopback']
    if (['lan', 'loopback'].includes(value)) {
      return false;
    }

    // Reject if the value starts with '@' (means it's an alias/reference)
    if (value.startsWith('@')) {
      return false;
    }

    // Otherwise allow it
    return true;
  };

  o = mainSection.taboption(
    'additional',
    form.Value,
    'procd_reload_delay',
    _('Interface Monitoring Delay'),
    _('Delay in milliseconds before reloading podkop after interface UP'),
  );
  o.ucisection = 'main';
  o.depends('mon_restart_ifaces', '1');
  o.default = '2000';
  o.rmempty = false;
  o.validate = function (section_id, value) {
    if (!value) {
      return _('Delay value cannot be empty');
    }
    return true;
  };

  o = mainSection.taboption(
    'additional',
    form.Flag,
    'dont_touch_dhcp',
    _('Dont touch my DHCP!'),
    _('Podkop will not change the DHCP config'),
  );
  o.default = '0';
  o.rmempty = false;
  o.ucisection = 'main';

  o = mainSection.taboption(
    'additional',
    form.Flag,
    'detour',
    _('Proxy download of lists'),
    _('Downloading all lists via main Proxy/VPN'),
  );
  o.default = '0';
  o.rmempty = false;
  o.ucisection = 'main';

  // Extra IPs and exclusions (main section)
  o = mainSection.taboption(
    'basic',
    form.Flag,
    'exclude_from_ip_enabled',
    _('IP for exclusion'),
    _('Specify local IP addresses that will never use the configured route'),
  );
  o.default = '0';
  o.rmempty = false;
  o.ucisection = 'main';

  o = mainSection.taboption(
    'basic',
    form.DynamicList,
    'exclude_traffic_ip',
    _('Local IPs'),
    _('Enter valid IPv4 addresses'),
  );
  o.placeholder = 'IP';
  o.depends('exclude_from_ip_enabled', '1');
  o.rmempty = false;
  o.ucisection = 'main';
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

  o = mainSection.taboption(
    'basic',
    form.Flag,
    'socks5',
    _('Mixed enable'),
    _('Browser port: 2080'),
  );
  o.default = '0';
  o.rmempty = false;
  o.ucisection = 'main';
}

return baseclass.extend({
  createAdditionalSection,
});
