'use strict';
'require baseclass';
'require form';
'require ui';
'require network';
'require view.podkop.main as main';
'require tools.widgets as widgets';

function createConfigSection(section) {
  const s = section;

  let o = s.tab('basic', _('Basic Settings'));

  o = s.taboption(
    'basic',
    form.ListValue,
    'mode',
    _('Connection Type'),
    _('Select between VPN and Proxy connection methods for traffic routing'),
  );
  o.value('proxy', 'Proxy');
  o.value('vpn', 'VPN');
  o.value('block', 'Block');
  o.ucisection = s.section;

  o = s.taboption(
    'basic',
    form.ListValue,
    'proxy_config_type',
    _('Configuration Type'),
    _('Select how to configure the proxy'),
  );
  o.value('url', _('Connection URL'));
  o.value('outbound', _('Outbound Config'));
  o.value('urltest', _('URLTest'));
  o.default = 'url';
  o.depends('mode', 'proxy');
  o.ucisection = s.section;

  o = s.taboption(
    'basic',
    form.TextValue,
    'proxy_string',
    _('Proxy Configuration URL'),
    '',
  );
  o.depends('proxy_config_type', 'url');
  o.rows = 5;
  o.wrap = 'soft';
  o.textarea = true;
  o.rmempty = false;
  o.ucisection = s.section;
  o.sectionDescriptions = new Map();
  o.placeholder =
    'vless://uuid@server:port?type=tcp&security=tls#main\n// backup ss://method:pass@server:port\n// backup2 vless://uuid@server:port?type=grpc&security=reality#alt\n// backup3 trojan://04agAQapcl@127.0.0.1:33641?type=tcp&security=none#trojan-tcp-none';

  o.renderWidget = function (section_id, option_index, cfgvalue) {
    const original = form.TextValue.prototype.renderWidget.apply(this, [
      section_id,
      option_index,
      cfgvalue,
    ]);
    const container = E('div', {});
    container.appendChild(original);

    if (cfgvalue) {
      try {
        const activeConfig = cfgvalue
          .split('\n')
          .map((line) => line.trim())
          .find((line) => line && !line.startsWith('//'));

        if (activeConfig) {
          if (activeConfig.includes('#')) {
            const label = activeConfig.split('#').pop();
            if (label && label.trim()) {
              const decodedLabel = decodeURIComponent(label);
              const descDiv = E(
                'div',
                { class: 'cbi-value-description' },
                _('Current config: ') + decodedLabel,
              );
              container.appendChild(descDiv);
            } else {
              const descDiv = E(
                'div',
                { class: 'cbi-value-description' },
                _('Config without description'),
              );
              container.appendChild(descDiv);
            }
          } else {
            const descDiv = E(
              'div',
              { class: 'cbi-value-description' },
              _('Config without description'),
            );
            container.appendChild(descDiv);
          }
        }
      } catch (e) {
        console.error('Error parsing config label:', e);
        const descDiv = E(
          'div',
          { class: 'cbi-value-description' },
          _('Config without description'),
        );
        container.appendChild(descDiv);
      }
    } else {
      const defaultDesc = E(
        'div',
        { class: 'cbi-value-description' },
        _(
          'Enter connection string starting with vless:// or ss:// for proxy configuration. Add comments with // for backup configs',
        ),
      );
      container.appendChild(defaultDesc);
    }

    return container;
  };

  o.validate = function (section_id, value) {
    // Optional
    if (!value || value.length === 0) {
      return true;
    }

    try {
      const activeConfigs = value
        .split('\n')
        .map((line) => line.trim())
        .filter((line) => !line.startsWith('//'))
        .filter(Boolean);

      if (!activeConfigs.length) {
        return _(
          'No active configuration found. One configuration is required.',
        );
      }

      if (activeConfigs.length > 1) {
        return _(
          'Multiply active configurations found. Please leave one configuration.',
        );
      }

      const validation = main.validateProxyUrl(activeConfigs[0]);

      if (validation.valid) {
        return true;
      }

      return validation.message;
    } catch (e) {
      return `${_('Invalid URL format:')} ${e?.message}`;
    }
  };

  o = s.taboption(
    'basic',
    form.TextValue,
    'outbound_json',
    _('Outbound Configuration'),
    _('Enter complete outbound configuration in JSON format'),
  );
  o.depends('proxy_config_type', 'outbound');
  o.rows = 10;
  o.ucisection = s.section;
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

  o = s.taboption(
    'basic',
    form.DynamicList,
    'urltest_proxy_links',
    _('URLTest Proxy Links'),
  );
  o.depends('proxy_config_type', 'urltest');
  o.placeholder = 'vless://, ss://, trojan:// links';
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

  o = s.taboption(
    'basic',
    form.Flag,
    'ss_uot',
    _('Shadowsocks UDP over TCP'),
    _('Apply for SS2022'),
  );
  o.default = '0';
  o.depends('mode', 'proxy');
  o.rmempty = false;
  o.ucisection = s.section;

  o = s.taboption(
    'basic',
    widgets.DeviceSelect,
    'interface',
    _('Network Interface'),
    _('Select network interface for VPN connection'),
  );
  o.depends('mode', 'vpn');
  o.ucisection = s.section;
  o.noaliases = true;
  o.nobridges = false;
  o.noinactive = false;
  o.filter = function (section_id, value) {
    // Blocked interface names that should never be selectable
    const blockedInterfaces = [
      'br-lan',
      'eth0',
      'eth1',
      'wan',
      'phy0-ap0',
      'phy1-ap0',
      'pppoe-wan',
      'lan',
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
      type === 'wifi' || type === 'wireless' || type.includes('wlan');

    return !isWireless;
  };

  o = s.taboption(
    'basic',
    form.Flag,
    'domain_resolver_enabled',
    _('Domain Resolver'),
    _('Enable built-in DNS resolver for domains handled by this section'),
  );
  o.default = '0';
  o.rmempty = false;
  o.depends('mode', 'vpn');
  o.ucisection = s.section;

  o = s.taboption(
    'basic',
    form.ListValue,
    'domain_resolver_dns_type',
    _('DNS Protocol Type'),
    _('Select the DNS protocol type for the domain resolver'),
  );
  o.value('doh', _('DNS over HTTPS (DoH)'));
  o.value('dot', _('DNS over TLS (DoT)'));
  o.value('udp', _('UDP (Unprotected DNS)'));
  o.default = 'udp';
  o.rmempty = false;
  o.depends('domain_resolver_enabled', '1');
  o.ucisection = s.section;

  o = s.taboption(
    'basic',
    form.Value,
    'domain_resolver_dns_server',
    _('DNS Server'),
    _('Select or enter DNS server address'),
  );
  Object.entries(main.DNS_SERVER_OPTIONS).forEach(([key, label]) => {
    o.value(key, _(label));
  });
  o.default = '8.8.8.8';
  o.rmempty = false;
  o.depends('domain_resolver_enabled', '1');
  o.ucisection = s.section;
  o.validate = function (section_id, value) {
    const validation = main.validateDNS(value);

    if (validation.valid) {
      return true;
    }

    return validation.message;
  };

  o = s.taboption(
    'basic',
    form.Flag,
    'community_lists_enabled',
    _('Community Lists'),
  );
  o.default = '0';
  o.rmempty = false;
  o.ucisection = s.section;

  o = s.taboption(
    'basic',
    form.DynamicList,
    'community_lists',
    _('Service List'),
    _('Select predefined service for routing') +
      ' <a href="https://github.com/itdoginfo/allow-domains" target="_blank">github.com/itdoginfo/allow-domains</a>',
  );
  o.placeholder = 'Service list';
  Object.entries(main.DOMAIN_LIST_OPTIONS).forEach(([key, label]) => {
    o.value(key, _(label));
  });
  o.depends('community_lists_enabled', '1');
  o.rmempty = false;
  o.ucisection = s.section;

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
          E('p', { class: 'alert-message warning' }, [
            E('strong', {}, _('Regional options cannot be used together')),
            E('br'),
            _(
              'Warning: %s cannot be used together with %s. Previous selections have been removed.',
            ).format(removedRegions.join(', '), lastSelected),
          ]),
        );
      }

      if (newValues.includes('russia_inside')) {
        const removedServices = newValues.filter(
          (v) => !main.ALLOWED_WITH_RUSSIA_INSIDE.includes(v),
        );
        if (removedServices.length > 0) {
          newValues = newValues.filter((v) =>
            main.ALLOWED_WITH_RUSSIA_INSIDE.includes(v),
          );
          notifications.push(
            E('p', { class: 'alert-message warning' }, [
              E('strong', {}, _('Russia inside restrictions')),
              E('br'),
              _(
                'Warning: Russia inside can only be used with %s. %s already in Russia inside and have been removed from selection.',
              ).format(
                main.ALLOWED_WITH_RUSSIA_INSIDE.map(
                  (key) => main.DOMAIN_LIST_OPTIONS[key],
                )
                  .filter((label) => label !== 'Russia inside')
                  .join(', '),
                removedServices.join(', '),
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
      console.error('Error in onchange handler:', e);
    } finally {
      isProcessing = false;
    }
  };

  o = s.taboption(
    'basic',
    form.ListValue,
    'user_domain_list_type',
    _('User Domain List Type'),
    _('Select how to add your custom domains'),
  );
  o.value('disabled', _('Disabled'));
  o.value('dynamic', _('Dynamic List'));
  o.value('text', _('Text List'));
  o.default = 'disabled';
  o.rmempty = false;
  o.ucisection = s.section;

  o = s.taboption(
    'basic',
    form.DynamicList,
    'user_domains',
    _('User Domains'),
    _(
      'Enter domain names without protocols (example: sub.example.com or example.com)',
    ),
  );
  o.placeholder = 'Domains list';
  o.depends('user_domain_list_type', 'dynamic');
  o.rmempty = false;
  o.ucisection = s.section;
  o.validate = function (section_id, value) {
    // Optional
    if (!value || value.length === 0) {
      return true;
    }

    const validation = main.validateDomain(value);

    if (validation.valid) {
      return true;
    }

    return validation.message;
  };

  o = s.taboption(
    'basic',
    form.TextValue,
    'user_domains_text',
    _('User Domains List'),
    _(
      'Enter domain names separated by comma, space or newline. You can add comments after //',
    ),
  );
  o.placeholder =
    'example.com, sub.example.com\n// Social networks\ndomain.com test.com // personal domains';
  o.depends('user_domain_list_type', 'text');
  o.rows = 8;
  o.rmempty = false;
  o.ucisection = s.section;
  o.validate = function (section_id, value) {
    // Optional
    if (!value || value.length === 0) {
      return true;
    }

    const domains = main.parseValueList(value);

    if (!domains.length) {
      return _(
        'At least one valid domain must be specified. Comments-only content is not allowed.',
      );
    }

    const { valid, results } = main.bulkValidate(domains, main.validateDomain);

    if (!valid) {
      const errors = results
        .filter((validation) => !validation.valid) // Leave only failed validations
        .map((validation) => _(`${validation.value}: ${validation.message}`)); // Collect validation errors

      return [_('Validation errors:'), ...errors].join('\n');
    }

    return true;
  };

  o = s.taboption(
    'basic',
    form.Flag,
    'local_domain_lists_enabled',
    _('Local Domain Lists'),
    _('Use the list from the router filesystem'),
  );
  o.default = '0';
  o.rmempty = false;
  o.ucisection = s.section;

  o = s.taboption(
    'basic',
    form.DynamicList,
    'local_domain_lists',
    _('Local Domain List Paths'),
    _('Enter the list file path'),
  );
  o.placeholder = '/path/file.lst';
  o.depends('local_domain_lists_enabled', '1');
  o.rmempty = false;
  o.ucisection = s.section;
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

  o = s.taboption(
    'basic',
    form.Flag,
    'remote_domain_lists_enabled',
    _('Remote Domain Lists'),
    _('Download and use domain lists from remote URLs'),
  );
  o.default = '0';
  o.rmempty = false;
  o.ucisection = s.section;

  o = s.taboption(
    'basic',
    form.DynamicList,
    'remote_domain_lists',
    _('Remote Domain URLs'),
    _('Enter full URLs starting with http:// or https://'),
  );
  o.placeholder = 'URL';
  o.depends('remote_domain_lists_enabled', '1');
  o.rmempty = false;
  o.ucisection = s.section;
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

  o = s.taboption(
    'basic',
    form.Flag,
    'local_subnet_lists_enabled',
    _('Local Subnet Lists'),
    _('Use the list from the router filesystem'),
  );
  o.default = '0';
  o.rmempty = false;
  o.ucisection = s.section;

  o = s.taboption(
    'basic',
    form.DynamicList,
    'local_subnet_lists',
    _('Local Subnet List Paths'),
    _('Enter the list file path'),
  );
  o.placeholder = '/path/file.lst';
  o.depends('local_subnet_lists_enabled', '1');
  o.rmempty = false;
  o.ucisection = s.section;
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

  o = s.taboption(
    'basic',
    form.ListValue,
    'user_subnet_list_type',
    _('User Subnet List Type'),
    _('Select how to add your custom subnets'),
  );
  o.value('disabled', _('Disabled'));
  o.value('dynamic', _('Dynamic List'));
  o.value('text', _('Text List (comma/space/newline separated)'));
  o.default = 'disabled';
  o.rmempty = false;
  o.ucisection = s.section;

  o = s.taboption(
    'basic',
    form.DynamicList,
    'user_subnets',
    _('User Subnets'),
    _(
      'Enter subnets in CIDR notation (example: 103.21.244.0/22) or single IP addresses',
    ),
  );
  o.placeholder = 'IP or subnet';
  o.depends('user_subnet_list_type', 'dynamic');
  o.rmempty = false;
  o.ucisection = s.section;
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

  o = s.taboption(
    'basic',
    form.TextValue,
    'user_subnets_text',
    _('User Subnets List'),
    _(
      'Enter subnets in CIDR notation or single IP addresses, separated by comma, space or newline. You can add comments after //',
    ),
  );
  o.placeholder =
    '103.21.244.0/22\n// Google DNS\n8.8.8.8\n1.1.1.1/32, 9.9.9.9 // Cloudflare and Quad9';
  o.depends('user_subnet_list_type', 'text');
  o.rows = 10;
  o.rmempty = false;
  o.ucisection = s.section;
  o.validate = function (section_id, value) {
    // Optional
    if (!value || value.length === 0) {
      return true;
    }

    const subnets = main.parseValueList(value);

    if (!subnets.length) {
      return _(
        'At least one valid subnet or IP must be specified. Comments-only content is not allowed.',
      );
    }

    const { valid, results } = main.bulkValidate(subnets, main.validateSubnet);

    if (!valid) {
      const errors = results
        .filter((validation) => !validation.valid) // Leave only failed validations
        .map((validation) => _(`${validation.value}: ${validation.message}`)); // Collect validation errors

      return [_('Validation errors:'), ...errors].join('\n');
    }

    return true;
  };

  o = s.taboption(
    'basic',
    form.Flag,
    'remote_subnet_lists_enabled',
    _('Remote Subnet Lists'),
    _('Download and use subnet lists from remote URLs'),
  );
  o.default = '0';
  o.rmempty = false;
  o.ucisection = s.section;

  o = s.taboption(
    'basic',
    form.DynamicList,
    'remote_subnet_lists',
    _('Remote Subnet URLs'),
    _('Enter full URLs starting with http:// or https://'),
  );
  o.placeholder = 'URL';
  o.depends('remote_subnet_lists_enabled', '1');
  o.rmempty = false;
  o.ucisection = s.section;
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

  o = s.taboption(
    'basic',
    form.Flag,
    'all_traffic_from_ip_enabled',
    _('IP for full redirection'),
    _(
      'Specify local IP addresses whose traffic will always use the configured route',
    ),
  );
  o.default = '0';
  o.rmempty = false;
  o.ucisection = s.section;

  o = s.taboption(
    'basic',
    form.DynamicList,
    'all_traffic_ip',
    _('Local IPs'),
    _('Enter valid IPv4 addresses'),
  );
  o.placeholder = 'IP';
  o.depends('all_traffic_from_ip_enabled', '1');
  o.rmempty = false;
  o.ucisection = s.section;
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

return baseclass.extend({
  createConfigSection,
});
