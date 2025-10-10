'use strict';
'require form';
'require baseclass';
'require tools.widgets as widgets';
'require view.podkop.main as main';

function createSectionContent(section) {
    let o = section.option(
        form.ListValue,
        'mode',
        _('Connection Type'),
        _('Select between VPN and Proxy connection methods for traffic routing'),
    );
    o.value('proxy', 'Proxy');
    o.value('vpn', 'VPN');
    o.value('block', 'Block');


    o = section.option(
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

    o = section.option(
        form.TextValue,
        'proxy_string',
        _('Proxy Configuration URL'),
        '',
    );
    o.depends('proxy_config_type', 'url');
    o.rows = 5;
    // Enable soft wrapping for multi-line proxy URLs (e.g., for URLTest proxy links)
    o.wrap = 'soft';
    // Render as a textarea to allow multiple proxy URLs/configs
    o.textarea = true;
    o.rmempty = false;
    o.sectionDescriptions = new Map();
    o.placeholder =
        'vless://uuid@server:port?type=tcp&security=tls#main\n// backup ss://method:pass@server:port\n// backup2 vless://uuid@server:port?type=grpc&security=reality#alt\n// backup3 trojan://04agAQapcl@127.0.0.1:33641?type=tcp&security=none#trojan-tcp-none';
    o.validate = function (section_id, value) {
        // Optional
        if (!value || value.length === 0) {
            return true;
        }

        try {
            const activeConfigs = main.splitProxyString(value);

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

    o = section.option(
        form.TextValue,
        'outbound_json',
        _('Outbound Configuration'),
        _('Enter complete outbound configuration in JSON format'),
    );
    o.depends('proxy_config_type', 'outbound');
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

    o = section.option(
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

    o = section.option(
        form.Flag,
        'ss_uot',
        _('Shadowsocks UDP over TCP'),
        _('Apply for SS2022'),
    );
    o.default = '0';
    o.depends('mode', 'proxy');
    o.rmempty = false;

    o = section.option(
        widgets.DeviceSelect,
        'interface',
        _('Network Interface'),
        _('Select network interface for VPN connection'),
    );
    o.depends('mode', 'vpn');
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

    o = section.option(
        form.Flag,
        'domain_resolver_enabled',
        _('Domain Resolver'),
        _('Enable built-in DNS resolver for domains handled by this section'),
    );
    o.default = '0';
    o.rmempty = false;
    o.depends('mode', 'vpn');

    o = section.option(
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

    o = section.option(
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
    o.validate = function (section_id, value) {
        const validation = main.validateDNS(value);

        if (validation.valid) {
            return true;
        }

        return validation.message;
    };

    o = section.option(
        form.Flag,
        'community_lists_enabled',
        _('Community Lists'),
    );
    o.default = '0';
    o.rmempty = false;

    o = section.option(
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

    o = section.option(
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

    o = section.option(
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

    o = section.option(
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

        const {valid, results} = main.bulkValidate(domains, row => main.validateDomain(row, true));

        if (!valid) {
            const errors = results
                .filter((validation) => !validation.valid) // Leave only failed validations
                .map((validation) => _(`${validation.value}: ${validation.message}`)); // Collect validation errors

            return [_('Validation errors:'), ...errors].join('\n');
        }

        return true;
    };

    o = section.option(
        form.Flag,
        'local_domain_lists_enabled',
        _('Local Domain Lists'),
        _('Use the list from the router filesystem'),
    );
    o.default = '0';
    o.rmempty = false;

    o = section.option(
        form.DynamicList,
        'local_domain_lists',
        _('Local Domain List Paths'),
        _('Enter the list file path'),
    );
    o.placeholder = '/path/file.lst';
    o.depends('local_domain_lists_enabled', '1');
    o.rmempty = false;
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

    o = section.option(
        form.Flag,
        'remote_domain_lists_enabled',
        _('Remote Domain Lists'),
        _('Download and use domain lists from remote URLs'),
    );
    o.default = '0';
    o.rmempty = false;

    o = section.option(
        form.DynamicList,
        'remote_domain_lists',
        _('Remote Domain URLs'),
        _('Enter full URLs starting with http:// or https://'),
    );
    o.placeholder = 'URL';
    o.depends('remote_domain_lists_enabled', '1');
    o.rmempty = false;
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

    o = section.option(
        form.Flag,
        'local_subnet_lists_enabled',
        _('Local Subnet Lists'),
        _('Use the list from the router filesystem'),
    );
    o.default = '0';
    o.rmempty = false;

    o = section.option(
        form.DynamicList,
        'local_subnet_lists',
        _('Local Subnet List Paths'),
        _('Enter the list file path'),
    );
    o.placeholder = '/path/file.lst';
    o.depends('local_subnet_lists_enabled', '1');
    o.rmempty = false;
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

    o = section.option(
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

    o = section.option(
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

    o = section.option(
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

        const {valid, results} = main.bulkValidate(subnets, main.validateSubnet);

        if (!valid) {
            const errors = results
                .filter((validation) => !validation.valid) // Leave only failed validations
                .map((validation) => _(`${validation.value}: ${validation.message}`)); // Collect validation errors

            return [_('Validation errors:'), ...errors].join('\n');
        }

        return true;
    };

    o = section.option(
        form.Flag,
        'remote_subnet_lists_enabled',
        _('Remote Subnet Lists'),
        _('Download and use subnet lists from remote URLs'),
    );
    o.default = '0';
    o.rmempty = false;

    o = section.option(
        form.DynamicList,
        'remote_subnet_lists',
        _('Remote Subnet URLs'),
        _('Enter full URLs starting with http:// or https://'),
    );
    o.placeholder = 'URL';
    o.depends('remote_subnet_lists_enabled', '1');
    o.rmempty = false;
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

    o = section.option(
        form.Flag,
        'all_traffic_from_ip_enabled',
        _('IP for full redirection'),
        _(
            'Specify local IP addresses whose traffic will always use the configured route',
        ),
    );
    o.default = '0';
    o.rmempty = false;

    o = section.option(
        form.DynamicList,
        'all_traffic_ip',
        _('Local IPs'),
        _('Enter valid IPv4 addresses'),
    );
    o.placeholder = 'IP';
    o.depends('all_traffic_from_ip_enabled', '1');
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

    o = section.option(
        form.Flag,
        'mixed_proxy_enabled',
        _('Enable Mixed Proxy'),
        _('Enable the mixed proxy, allowing this section to route traffic through both HTTP and SOCKS proxies.'),
    );
    o.default = '0';
    o.rmempty = false;

    o = section.option(
        form.Value,
        'mixed_proxy_port',
        _('Mixed Proxy Port'),
        _(
            'Specify the port number on which the mixed proxy will run for this section. ' +
            'Make sure the selected port is not used by another service.'
        ),
    );
    o.rmempty = false;
    o.depends('mixed_proxy_enabled', '1');
}

const EntryPoint = {
    createSectionContent,
}

return baseclass.extend(EntryPoint);
