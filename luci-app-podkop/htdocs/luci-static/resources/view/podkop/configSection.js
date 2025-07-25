'use strict';
'require baseclass';
'require form';
'require ui';
'require network';
'require view.podkop.constants as constants';
'require tools.widgets as widgets';

function validateUrl(url, protocols = ['http:', 'https:']) {
    try {
        const parsedUrl = new URL(url);
        if (!protocols.includes(parsedUrl.protocol)) {
            return _('URL must use one of the following protocols: ') + protocols.join(', ');
        }
        return true;
    } catch (e) {
        return _('Invalid URL format');
    }
}

function createConfigSection(section, map, network) {
    const s = section;

    let o = s.tab('basic', _('Basic Settings'));

    o = s.taboption('basic', form.ListValue, 'mode', _('Connection Type'), _('Select between VPN and Proxy connection methods for traffic routing'));
    o.value('proxy', ('Proxy'));
    o.value('vpn', ('VPN'));
    o.value('block', ('Block'));
    o.ucisection = s.section;

    o = s.taboption('basic', form.ListValue, 'proxy_config_type', _('Configuration Type'), _('Select how to configure the proxy'));
    o.value('url', _('Connection URL'));
    o.value('outbound', _('Outbound Config'));
    o.default = 'url';
    o.depends('mode', 'proxy');
    o.ucisection = s.section;

    o = s.taboption('basic', form.TextValue, 'proxy_string', _('Proxy Configuration URL'), _(''));
    o.depends('proxy_config_type', 'url');
    o.rows = 5;
    o.rmempty = false;
    o.ucisection = s.section;
    o.sectionDescriptions = new Map();
    o.placeholder = 'vless://uuid@server:port?type=tcp&security=tls#main\n// backup ss://method:pass@server:port\n// backup2 vless://uuid@server:port?type=grpc&security=reality#alt';

    o.renderWidget = function (section_id, option_index, cfgvalue) {
        const original = form.TextValue.prototype.renderWidget.apply(this, [section_id, option_index, cfgvalue]);
        const container = E('div', {});
        container.appendChild(original);

        if (cfgvalue) {
            try {
                const activeConfig = cfgvalue.split('\n')
                    .map(line => line.trim())
                    .find(line => line && !line.startsWith('//'));

                if (activeConfig) {
                    if (activeConfig.includes('#')) {
                        const label = activeConfig.split('#').pop();
                        if (label && label.trim()) {
                            const decodedLabel = decodeURIComponent(label);
                            const descDiv = E('div', { 'class': 'cbi-value-description' }, _('Current config: ') + decodedLabel);
                            container.appendChild(descDiv);
                        } else {
                            const descDiv = E('div', { 'class': 'cbi-value-description' }, _('Config without description'));
                            container.appendChild(descDiv);
                        }
                    } else {
                        const descDiv = E('div', { 'class': 'cbi-value-description' }, _('Config without description'));
                        container.appendChild(descDiv);
                    }
                }
            } catch (e) {
                console.error('Error parsing config label:', e);
                const descDiv = E('div', { 'class': 'cbi-value-description' }, _('Config without description'));
                container.appendChild(descDiv);
            }
        } else {
            const defaultDesc = E('div', { 'class': 'cbi-value-description' },
                _('Enter connection string starting with vless:// or ss:// for proxy configuration. Add comments with // for backup configs'));
            container.appendChild(defaultDesc);
        }

        return container;
    };

    o.validate = function (section_id, value) {
        if (!value || value.length === 0) {
            return true;
        }

        try {
            const activeConfig = value.split('\n')
                .map(line => line.trim())
                .find(line => line && !line.startsWith('//'));

            if (!activeConfig) {
                return _('No active configuration found. At least one non-commented line is required.');
            }

            if (!activeConfig.startsWith('vless://') && !activeConfig.startsWith('ss://')) {
                return _('URL must start with vless:// or ss://');
            }

            if (activeConfig.startsWith('ss://')) {
                let encrypted_part;
                try {
                    let mainPart = activeConfig.includes('?') ? activeConfig.split('?')[0] : activeConfig.split('#')[0];
                    encrypted_part = mainPart.split('/')[2].split('@')[0];
                    try {
                        let decoded = atob(encrypted_part);
                        if (!decoded.includes(':')) {
                            if (!encrypted_part.includes(':') && !encrypted_part.includes('-')) {
                                return _('Invalid Shadowsocks URL format: missing method and password separator ":"');
                            }
                        }
                    } catch (e) {
                        if (!encrypted_part.includes(':') && !encrypted_part.includes('-')) {
                            return _('Invalid Shadowsocks URL format: missing method and password separator ":"');
                        }
                    }
                } catch (e) {
                    return _('Invalid Shadowsocks URL format');
                }

                try {
                    let serverPart = activeConfig.split('@')[1];
                    if (!serverPart) return _('Invalid Shadowsocks URL: missing server address');
                    let [server, portAndRest] = serverPart.split(':');
                    if (!server) return _('Invalid Shadowsocks URL: missing server');
                    let port = portAndRest ? portAndRest.split(/[?#]/)[0] : null;
                    if (!port) return _('Invalid Shadowsocks URL: missing port');
                    let portNum = parseInt(port);
                    if (isNaN(portNum) || portNum < 1 || portNum > 65535) {
                        return _('Invalid port number. Must be between 1 and 65535');
                    }
                } catch (e) {
                    return _('Invalid Shadowsocks URL: missing or invalid server/port format');
                }
            }

            if (activeConfig.startsWith('vless://')) {
                let uuid = activeConfig.split('/')[2].split('@')[0];
                if (!uuid || uuid.length === 0) return _('Invalid VLESS URL: missing UUID');

                try {
                    let serverPart = activeConfig.split('@')[1];
                    if (!serverPart) return _('Invalid VLESS URL: missing server address');
                    let [server, portAndRest] = serverPart.split(':');
                    if (!server) return _('Invalid VLESS URL: missing server');
                    let port = portAndRest ? portAndRest.split(/[/?#]/)[0] : null;
                    if (!port) return _('Invalid VLESS URL: missing port');
                    let portNum = parseInt(port);
                    if (isNaN(portNum) || portNum < 1 || portNum > 65535) {
                        return _('Invalid port number. Must be between 1 and 65535');
                    }
                } catch (e) {
                    return _('Invalid VLESS URL: missing or invalid server/port format');
                }

                let queryString = activeConfig.split('?')[1];
                if (!queryString) return _('Invalid VLESS URL: missing query parameters');

                let params = new URLSearchParams(queryString.split('#')[0]);
                let type = params.get('type');
                const validTypes = ['tcp', 'raw', 'udp', 'grpc', 'http', 'ws'];
                if (!type || !validTypes.includes(type)) {
                    return _('Invalid VLESS URL: type must be one of tcp, raw, udp, grpc, http, ws');
                }

                let security = params.get('security');
                const validSecurities = ['tls', 'reality', 'none'];
                if (!security || !validSecurities.includes(security)) {
                    return _('Invalid VLESS URL: security must be one of tls, reality, none');
                }

                if (security === 'reality') {
                    if (!params.get('pbk')) return _('Invalid VLESS URL: missing pbk parameter for reality security');
                    if (!params.get('fp')) return _('Invalid VLESS URL: missing fp parameter for reality security');
                }
            }

            return true;
        } catch (e) {
            console.error('Validation error:', e);
            return _('Invalid URL format: ') + e.message;
        }
    };

    o = s.taboption('basic', form.TextValue, 'outbound_json', _('Outbound Configuration'), _('Enter complete outbound configuration in JSON format'));
    o.depends('proxy_config_type', 'outbound');
    o.rows = 10;
    o.ucisection = s.section;
    o.validate = function (section_id, value) {
        if (!value || value.length === 0) return true;
        try {
            const parsed = JSON.parse(value);
            if (!parsed.type || !parsed.server || !parsed.server_port) {
                return _('JSON must contain at least type, server and server_port fields');
            }
            return true;
        } catch (e) {
            return _('Invalid JSON format');
        }
    };

    o = s.taboption('basic', form.Flag, 'ss_uot', _('Shadowsocks UDP over TCP'), _('Apply for SS2022'));
    o.default = '0';
    o.depends('mode', 'proxy');
    o.rmempty = false;
    o.ucisection = 'main';

    o = s.taboption('basic', widgets.DeviceSelect, 'interface', _('Network Interface'), _('Select network interface for VPN connection'));
    o.depends('mode', 'vpn');
    o.ucisection = s.section;
    o.noaliases = true;
    o.nobridges = false;
    o.noinactive = false;
    o.filter = function (section_id, value) {
        if (['br-lan', 'eth0', 'eth1', 'wan', 'phy0-ap0', 'phy1-ap0', 'pppoe-wan', 'lan'].indexOf(value) !== -1) {
            return false;
        }

        var device = this.devices.filter(function (dev) {
            return dev.getName() === value;
        })[0];

        if (device) {
            var type = device.getType();
            return type !== 'wifi' && type !== 'wireless' && !type.includes('wlan');
        }

        return true;
    };

    o = s.taboption('basic', form.Flag, 'domain_list_enabled', _('Community Lists'));
    o.default = '0';
    o.rmempty = false;
    o.ucisection = s.section;

    o = s.taboption('basic', form.DynamicList, 'domain_list', _('Service List'), _('Select predefined service for routing') + ' <a href="https://github.com/itdoginfo/allow-domains" target="_blank">github.com/itdoginfo/allow-domains</a>');
    o.placeholder = 'Service list';
    Object.entries(constants.DOMAIN_LIST_OPTIONS).forEach(([key, label]) => {
        o.value(key, _(label));
    });

    o.depends('domain_list_enabled', '1');
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

            const selectedRegionalOptions = constants.REGIONAL_OPTIONS.filter(opt => newValues.includes(opt));

            if (selectedRegionalOptions.length > 1) {
                const lastSelected = selectedRegionalOptions[selectedRegionalOptions.length - 1];
                const removedRegions = selectedRegionalOptions.slice(0, -1);
                newValues = newValues.filter(v => v === lastSelected || !constants.REGIONAL_OPTIONS.includes(v));
                notifications.push(E('p', { class: 'alert-message warning' }, [
                    E('strong', {}, _('Regional options cannot be used together')), E('br'),
                    _('Warning: %s cannot be used together with %s. Previous selections have been removed.')
                        .format(removedRegions.join(', '), lastSelected)
                ]));
            }

            if (newValues.includes('russia_inside')) {
                const removedServices = newValues.filter(v => !constants.ALLOWED_WITH_RUSSIA_INSIDE.includes(v));
                if (removedServices.length > 0) {
                    newValues = newValues.filter(v => constants.ALLOWED_WITH_RUSSIA_INSIDE.includes(v));
                    notifications.push(E('p', { class: 'alert-message warning' }, [
                        E('strong', {}, _('Russia inside restrictions')), E('br'),
                        _('Warning: Russia inside can only be used with %s. %s already in Russia inside and have been removed from selection.')
                            .format(
                                constants.ALLOWED_WITH_RUSSIA_INSIDE.map(key => constants.DOMAIN_LIST_OPTIONS[key]).filter(label => label !== 'Russia inside').join(', '),
                                removedServices.join(', ')
                            )
                    ]));
                }
            }

            if (JSON.stringify(newValues.sort()) !== JSON.stringify(values.sort())) {
                this.getUIElement(section_id).setValue(newValues);
            }

            notifications.forEach(notification => ui.addNotification(null, notification));
            lastValues = newValues;
        } catch (e) {
            console.error('Error in onchange handler:', e);
        } finally {
            isProcessing = false;
        }
    };

    o = s.taboption('basic', form.ListValue, 'custom_domains_list_type', _('User Domain List Type'), _('Select how to add your custom domains'));
    o.value('disabled', _('Disabled'));
    o.value('dynamic', _('Dynamic List'));
    o.value('text', _('Text List'));
    o.default = 'disabled';
    o.rmempty = false;
    o.ucisection = s.section;

    o = s.taboption('basic', form.DynamicList, 'custom_domains', _('User Domains'), _('Enter domain names without protocols (example: sub.example.com or example.com)'));
    o.placeholder = 'Domains list';
    o.depends('custom_domains_list_type', 'dynamic');
    o.rmempty = false;
    o.ucisection = s.section;
    o.validate = function (section_id, value) {
        if (!value || value.length === 0) return true;
        const domainRegex = /^(?!-)[A-Za-z0-9-]+([-.][A-Za-z0-9-]+)*(\.[A-Za-z]{2,})?$/;
        if (!domainRegex.test(value)) {
            return _('Invalid domain format. Enter domain without protocol (example: sub.example.com or ru)');
        }
        return true;
    };

    o = s.taboption('basic', form.TextValue, 'custom_domains_text', _('User Domains List'), _('Enter domain names separated by comma, space or newline. You can add comments after //'));
    o.placeholder = 'example.com, sub.example.com\n// Social networks\ndomain.com test.com // personal domains';
    o.depends('custom_domains_list_type', 'text');
    o.rows = 8;
    o.rmempty = false;
    o.ucisection = s.section;
    o.validate = function (section_id, value) {
        if (!value || value.length === 0) return true;

        const domainRegex = /^(?!-)[A-Za-z0-9-]+([-.][A-Za-z0-9-]+)*(\.[A-Za-z]{2,})?$/;
        const lines = value.split(/\n/).map(line => line.trim());
        let hasValidDomain = false;

        for (const line of lines) {
            // Skip empty lines
            if (!line) continue;

            // Extract domain part (before any //)
            const domainPart = line.split('//')[0].trim();

            // Skip if line is empty after removing comments
            if (!domainPart) continue;

            // Process each domain in the line (separated by comma or space)
            const domains = domainPart.split(/[,\s]+/).map(d => d.trim()).filter(d => d.length > 0);

            for (const domain of domains) {
                if (!domainRegex.test(domain)) {
                    return _('Invalid domain format: %s. Enter domain without protocol').format(domain);
                }
                hasValidDomain = true;
            }
        }

        if (!hasValidDomain) {
            return _('At least one valid domain must be specified. Comments-only content is not allowed.');
        }

        return true;
    };

    o = s.taboption('basic', form.Flag, 'custom_local_domains_list_enabled', _('Local Domain Lists'), _('Use the list from the router filesystem'));
    o.default = '0';
    o.rmempty = false;
    o.ucisection = s.section;

    o = s.taboption('basic', form.DynamicList, 'custom_local_domains', _('Local Domain Lists Path'), _('Enter the list file path'));
    o.placeholder = '/path/file.lst';
    o.depends('custom_local_domains_list_enabled', '1');
    o.rmempty = false;
    o.ucisection = s.section;
    o.validate = function (section_id, value) {
        if (!value || value.length === 0) return true;
        const pathRegex = /^\/[a-zA-Z0-9_\-\/\.]+$/;
        if (!pathRegex.test(value)) {
            return _('Invalid path format. Path must start with "/" and contain valid characters');
        }
        return true;
    };

    o = s.taboption('basic', form.Flag, 'custom_download_domains_list_enabled', _('Remote Domain Lists'), _('Download and use domain lists from remote URLs'));
    o.default = '0';
    o.rmempty = false;
    o.ucisection = s.section;

    o = s.taboption('basic', form.DynamicList, 'custom_download_domains', _('Remote Domain URLs'), _('Enter full URLs starting with http:// or https://'));
    o.placeholder = 'URL';
    o.depends('custom_download_domains_list_enabled', '1');
    o.rmempty = false;
    o.ucisection = s.section;
    o.validate = function (section_id, value) {
        if (!value || value.length === 0) return true;
        return validateUrl(value);
    };

    o = s.taboption('basic', form.ListValue, 'custom_subnets_list_enabled', _('User Subnet List Type'), _('Select how to add your custom subnets'));
    o.value('disabled', _('Disabled'));
    o.value('dynamic', _('Dynamic List'));
    o.value('text', _('Text List (comma/space/newline separated)'));
    o.default = 'disabled';
    o.rmempty = false;
    o.ucisection = s.section;

    o = s.taboption('basic', form.DynamicList, 'custom_subnets', _('User Subnets'), _('Enter subnets in CIDR notation (example: 103.21.244.0/22) or single IP addresses'));
    o.placeholder = 'IP or subnet';
    o.depends('custom_subnets_list_enabled', 'dynamic');
    o.rmempty = false;
    o.ucisection = s.section;
    o.validate = function (section_id, value) {
        if (!value || value.length === 0) return true;
        const subnetRegex = /^(\d{1,3}\.){3}\d{1,3}(\/\d{1,2})?$/;
        if (!subnetRegex.test(value)) return _('Invalid format. Use format: X.X.X.X or X.X.X.X/Y');
        const [ip, cidr] = value.split('/');
        if (ip === "0.0.0.0") {
             return _('IP address 0.0.0.0 is not allowed');
        }
        const ipParts = ip.split('.');
        for (const part of ipParts) {
            const num = parseInt(part);
            if (num < 0 || num > 255) return _('IP address parts must be between 0 and 255');
        }
        if (cidr !== undefined) {
            const cidrNum = parseInt(cidr);
            if (cidrNum < 0 || cidrNum > 32) return _('CIDR must be between 0 and 32');
        }
        return true;
    };

    o = s.taboption('basic', form.TextValue, 'custom_subnets_text', _('User Subnets List'), _('Enter subnets in CIDR notation or single IP addresses, separated by comma, space or newline. You can add comments after //'));
    o.placeholder = '103.21.244.0/22\n// Google DNS\n8.8.8.8\n1.1.1.1/32, 9.9.9.9 // Cloudflare and Quad9';
    o.depends('custom_subnets_list_enabled', 'text');
    o.rows = 10;
    o.rmempty = false;
    o.ucisection = s.section;
    o.validate = function (section_id, value) {
        if (!value || value.length === 0) return true;

        const subnetRegex = /^(\d{1,3}\.){3}\d{1,3}(\/\d{1,2})?$/;
        const lines = value.split(/\n/).map(line => line.trim());
        let hasValidSubnet = false;

        for (const line of lines) {
            // Skip empty lines
            if (!line) continue;

            // Extract subnet part (before any //)
            const subnetPart = line.split('//')[0].trim();

            // Skip if line is empty after removing comments
            if (!subnetPart) continue;

            // Process each subnet in the line (separated by comma or space)
            const subnets = subnetPart.split(/[,\s]+/).map(s => s.trim()).filter(s => s.length > 0);

            for (const subnet of subnets) {
                if (!subnetRegex.test(subnet)) {
                    return _('Invalid format: %s. Use format: X.X.X.X or X.X.X.X/Y').format(subnet);
                }

                const [ip, cidr] = subnet.split('/');
                const ipParts = ip.split('.');
                for (const part of ipParts) {
                    const num = parseInt(part);
                    if (num < 0 || num > 255) {
                        return _('IP parts must be between 0 and 255 in: %s').format(subnet);
                    }
                }

                if (cidr !== undefined) {
                    const cidrNum = parseInt(cidr);
                    if (cidrNum < 0 || cidrNum > 32) {
                        return _('CIDR must be between 0 and 32 in: %s').format(subnet);
                    }
                }
                hasValidSubnet = true;
            }
        }

        if (!hasValidSubnet) {
            return _('At least one valid subnet or IP must be specified. Comments-only content is not allowed.');
        }

        return true;
    };

    o = s.taboption('basic', form.Flag, 'custom_download_subnets_list_enabled', _('Remote Subnet Lists'), _('Download and use subnet lists from remote URLs'));
    o.default = '0';
    o.rmempty = false;
    o.ucisection = s.section;

    o = s.taboption('basic', form.DynamicList, 'custom_download_subnets', _('Remote Subnet URLs'), _('Enter full URLs starting with http:// or https://'));
    o.placeholder = 'URL';
    o.depends('custom_download_subnets_list_enabled', '1');
    o.rmempty = false;
    o.ucisection = s.section;
    o.validate = function (section_id, value) {
        if (!value || value.length === 0) return true;
        return validateUrl(value);
    };

    o = s.taboption('basic', form.Flag, 'all_traffic_from_ip_enabled', _('IP for full redirection'), _('Specify local IP addresses whose traffic will always use the configured route'));
    o.default = '0';
    o.rmempty = false;
    o.ucisection = s.section;

    o = s.taboption('basic', form.DynamicList, 'all_traffic_ip', _('Local IPs'), _('Enter valid IPv4 addresses'));
    o.placeholder = 'IP';
    o.depends('all_traffic_from_ip_enabled', '1');
    o.rmempty = false;
    o.ucisection = s.section;
    o.validate = function (section_id, value) {
        if (!value || value.length === 0) return true;
        const ipRegex = /^(\d{1,3}\.){3}\d{1,3}$/;
        if (!ipRegex.test(value)) return _('Invalid IP format. Use format: X.X.X.X (like 192.168.1.1)');
        const ipParts = value.split('.');
        for (const part of ipParts) {
            const num = parseInt(part);
            if (num < 0 || num > 255) return _('IP address parts must be between 0 and 255');
        }
        return true;
    };
}

return baseclass.extend({
    createConfigSection
});