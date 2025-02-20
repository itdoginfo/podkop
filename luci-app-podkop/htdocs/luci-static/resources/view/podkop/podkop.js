'use strict';
'require view';
'require form';
'require ui';
'require network';
'require fs';

function formatDiagnosticOutput(output) {
    if (!output) return '';
    return output.trim()
        .replace(/\x1b\[[0-9;]*m/g, '')  // Remove ANSI color codes
        .replace(/\r\n/g, '\n')          // Normalize line endings
        .replace(/\r/g, '\n');
}

return view.extend({
    async render() {
        document.getElementsByTagName('head')[0].insertAdjacentHTML('beforeend', `
            <meta http-equiv="Cache-Control" content="no-cache, no-store, must-revalidate">
            <meta http-equiv="Pragma" content="no-cache">
            <meta http-equiv="Expires" content="0">
            <style>
                .cbi-value {
                    margin-bottom: 10px !important;
                }
            </style>
        `);

        var m, s, o;

        m = new form.Map('podkop', _('Podkop configuration'), null, ['main', 'second']);
        fs.exec('/etc/init.d/podkop', ['show_version']).then(function (res) {
            if (res.stdout) {
                m.title = _('Podkop') + ' v' + res.stdout.trim();
            }
        });

        s = m.section(form.TypedSection, 'main');
        s.anonymous = true;

        // Basic Settings Tab
        o = s.tab('basic', _('Basic Settings'));

        o = s.taboption('basic', form.ListValue, 'mode', _('Connection Type'), _('Select between VPN and Proxy connection methods for traffic routing'));
        o.value('proxy', ('Proxy'));
        o.value('vpn', ('VPN'));
        o.ucisection = 'main';

        o = s.taboption('basic', form.ListValue, 'proxy_config_type', _('Configuration Type'), _('Select how to configure the proxy'));
        o.value('url', _('Connection URL'));
        o.value('outbound', _('Outbound Config'));
        o.default = 'url';
        o.depends('mode', 'proxy');
        o.ucisection = 'main';

        o = s.taboption('basic', form.TextValue, 'proxy_string', _('Proxy Configuration URL'), _('Enter connection string starting with vless:// or ss:// for proxy configuration'));
        o.depends('proxy_config_type', 'url');
        o.rows = 5;
        o.ucisection = 'main';
        o.validate = function (section_id, value) {
            if (!value || value.length === 0) {
                return true;
            }

            try {
                // Check if it's a valid URL format
                if (!value.startsWith('vless://') && !value.startsWith('ss://')) {
                    return _('URL must start with vless:// or ss://');
                }

                // For Shadowsocks
                if (value.startsWith('ss://')) {
                    let encrypted_part;
                    try {
                        // Split URL properly handling both old and new formats
                        let mainPart = value.includes('?') ? value.split('?')[0] : value.split('#')[0];
                        encrypted_part = mainPart.split('/')[2].split('@')[0];

                        // Try base64 decode first (for old format)
                        try {
                            let decoded = atob(encrypted_part);
                            if (!decoded.includes(':')) {
                                // Not old format, check if it's 2022 format
                                if (!encrypted_part.includes(':') && !encrypted_part.includes('-')) {
                                    return _('Invalid Shadowsocks URL format: missing method and password separator ":"');
                                }
                            }
                        } catch (e) {
                            // If base64 decode fails, check if it's 2022 format
                            if (!encrypted_part.includes(':') && !encrypted_part.includes('-')) {
                                return _('Invalid Shadowsocks URL format: missing method and password separator ":"');
                            }
                        }
                    } catch (e) {
                        return _('Invalid Shadowsocks URL format');
                    }

                    // Check server and port
                    try {
                        let serverPart = value.split('@')[1];
                        if (!serverPart) {
                            return _('Invalid Shadowsocks URL: missing server address');
                        }
                        let [server, portAndRest] = serverPart.split(':');
                        if (!server) {
                            return _('Invalid Shadowsocks URL: missing server');
                        }
                        let port = portAndRest ? portAndRest.split(/[?#]/)[0] : null;
                        if (!port) {
                            return _('Invalid Shadowsocks URL: missing port');
                        }
                        let portNum = parseInt(port);
                        if (isNaN(portNum) || portNum < 1 || portNum > 65535) {
                            return _('Invalid port number. Must be between 1 and 65535');
                        }
                    } catch (e) {
                        return _('Invalid Shadowsocks URL: missing or invalid server/port format');
                    }
                }

                // For VLESS
                if (value.startsWith('vless://')) {
                    // Check UUID
                    let uuid = value.split('/')[2].split('@')[0];
                    if (!uuid || uuid.length === 0) {
                        return _('Invalid VLESS URL: missing UUID');
                    }

                    // Check server and port
                    try {
                        let serverPart = value.split('@')[1];
                        if (!serverPart) {
                            return _('Invalid VLESS URL: missing server address');
                        }
                        let [server, portAndRest] = serverPart.split(':');
                        if (!server) {
                            return _('Invalid VLESS URL: missing server');
                        }
                        // Handle cases where port might be followed by / or ? or #
                        let port = portAndRest ? portAndRest.split(/[/?#]/)[0] : null;
                        if (!port && port !== '') { // Allow empty port for specific cases
                            return _('Invalid VLESS URL: missing port');
                        }
                        if (port !== '') { // Only validate port if it's not empty
                            let portNum = parseInt(port);
                            if (isNaN(portNum) || portNum < 1 || portNum > 65535) {
                                return _('Invalid port number. Must be between 1 and 65535');
                            }
                        }
                    } catch (e) {
                        return _('Invalid VLESS URL: missing or invalid server/port format');
                    }

                    // Parse query parameters
                    let queryString = value.split('?')[1];
                    if (!queryString) {
                        return _('Invalid VLESS URL: missing query parameters');
                    }

                    let params = new URLSearchParams(queryString.split('#')[0]);

                    // Check type parameter
                    let type = params.get('type');
                    if (!type) {
                        return _('Invalid VLESS URL: missing type parameter');
                    }

                    // Check security parameter
                    let security = params.get('security');
                    if (!security) {
                        return _('Invalid VLESS URL: missing security parameter');
                    }

                    // If security is "reality", check required reality parameters
                    if (security === 'reality') {
                        if (!params.get('pbk')) {
                            return _('Invalid VLESS URL: missing pbk parameter for reality security');
                        }
                        if (!params.get('fp')) {
                            return _('Invalid VLESS URL: missing fp parameter for reality security');
                        }
                    }

                    // If security is "tls", check required TLS parameters
                    if (security === 'tls') {
                        if (!params.get('sni') && type !== 'tcp') {
                            return _('Invalid VLESS URL: missing sni parameter for tls security');
                        }
                    }
                }

                return true;
            } catch (e) {
                console.error('Validation error:', e);
                return _('Invalid URL format: ' + e.message);
            }
        };

        o = s.taboption('basic', form.TextValue, 'outbound_json', _('Outbound Configuration'), _('Enter complete outbound configuration in JSON format'));
        o.depends('proxy_config_type', 'outbound');
        o.rows = 10;
        o.ucisection = 'main';
        o.validate = function (section_id, value) {
            if (!value || value.length === 0) {
                return true;
            }

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

        o = s.taboption('basic', form.ListValue, 'interface', _('Network Interface'), _('Select network interface for VPN connection'));
        o.depends('mode', 'vpn');
        o.ucisection = 'main';

        try {
            const devices = await network.getDevices();
            const excludeInterfaces = ['br-lan', 'eth0', 'eth1', 'wan', 'phy0-ap0', 'phy1-ap0'];

            devices.forEach(function (device) {
                if (device.dev && device.dev.name) {
                    const deviceName = device.dev.name;
                    const isExcluded = excludeInterfaces.includes(deviceName) || /^lan\d+$/.test(deviceName);

                    if (!isExcluded) {
                        o.value(deviceName, deviceName);
                    }
                }
            });
        } catch (error) {
            console.error('Error fetching devices:', error);
        }

        o = s.taboption('basic', form.Flag, 'domain_list_enabled', _('Community Lists'));
        o.default = '0';
        o.rmempty = false;
        o.ucisection = 'main';

        o = s.taboption('basic', form.DynamicList, 'domain_list', _('Service List'), _('Select predefined service for routing') + ' <a href="https://github.com/itdoginfo/allow-domains" target="_blank">github.com/itdoginfo/allow-domains</a>');
        o.placeholder = 'Service list';
        o.value('russia_inside', 'Russia inside');
        o.value('russia_outside', 'Russia outside');
        o.value('ukraine_inside', 'Ukraine');
        o.value('geoblock', 'GEO Block');
        o.value('block', 'Block');
        o.value('porn', 'Porn');
        o.value('news', 'News');
        o.value('anime', 'Anime');
        o.value('youtube', 'Youtube');
        o.value('discord', 'Discord');
        o.value('meta', 'Meta');
        o.value('twitter', 'Twitter (X)');
        o.value('hdrezka', 'HDRezka');
        o.value('tiktok', 'Tik-Tok');
        o.value('telegram', 'Telegram');
        o.depends('domain_list_enabled', '1');
        o.rmempty = false;
        o.ucisection = 'main';

        let lastValues = [];
        let isProcessing = false;

        o.onchange = function (ev, section_id, value) {
            if (isProcessing) return;
            isProcessing = true;

            try {
                const values = Array.isArray(value) ? value : [value];
                let newValues = [...values];
                let notifications = [];

                // Проверка взаимоисключающих региональных опций
                const regionalOptions = ['russia_inside', 'russia_outside', 'ukraine_inside'];
                const selectedRegionalOptions = regionalOptions.filter(opt => newValues.includes(opt));

                if (selectedRegionalOptions.length > 1) {
                    // Оставляем только последний выбранный региональный вариант
                    const lastSelected = selectedRegionalOptions[selectedRegionalOptions.length - 1];
                    const removedRegions = selectedRegionalOptions.slice(0, -1);
                    newValues = newValues.filter(v => v === lastSelected || !regionalOptions.includes(v));

                    const warningMsg = _('Warning: %s cannot be used together with %s. Previous selections have been removed.').format(
                        removedRegions.join(', '),
                        lastSelected
                    );

                    notifications.push(E('p', { class: 'alert-message warning' }, [
                        E('strong', {}, _('Regional options cannot be used together')), E('br'),
                        warningMsg
                    ]));
                }

                // Специальная обработка для russia_inside
                if (newValues.includes('russia_inside')) {
                    const allowedWithRussiaInside = ['russia_inside', 'meta', 'twitter', 'discord', 'telegram'];
                    const removedServices = newValues.filter(v => !allowedWithRussiaInside.includes(v));

                    if (removedServices.length > 0) {
                        newValues = newValues.filter(v => allowedWithRussiaInside.includes(v));

                        const warningMsg = _('Warning: Russia inside can only be used with Meta, Twitter, Discord, and Telegram. %s already in Russia inside and have been removed from selection.').format(
                            removedServices.join(', ')
                        );

                        notifications.push(E('p', { class: 'alert-message warning' }, [
                            E('strong', {}, _('Russia inside restrictions')), E('br'),
                            warningMsg
                        ]));
                    }
                }

                // Если были изменения, обновляем значения
                if (JSON.stringify(newValues.sort()) !== JSON.stringify(values.sort())) {
                    this.getUIElement(section_id).setValue(newValues);
                }

                // Показываем все накопленные уведомления
                notifications.forEach(notification => {
                    ui.addNotification(null, notification);
                });

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
        o.ucisection = 'main';

        o = s.taboption('basic', form.DynamicList, 'custom_domains', _('User Domains'), _('Enter domain names without protocols (example: sub.example.com or example.com)'));
        o.placeholder = 'Domains list';
        o.depends('custom_domains_list_type', 'dynamic');
        o.rmempty = false;
        o.ucisection = 'main';
        o.validate = function (section_id, value) {
            if (!value || value.length === 0) {
                return true;
            }

            const domainRegex = /^(?!-)[A-Za-z0-9-]+([-.][A-Za-z0-9-]+)*\.[A-Za-z]{2,}$/;

            if (!domainRegex.test(value)) {
                return _('Invalid domain format. Enter domain without protocol (example: sub.example.com)');
            }
            return true;
        };

        o = s.taboption('basic', form.TextValue, 'custom_domains_text', _('User Domains List'), _('Enter domain names separated by comma, space or newline (example: sub.example.com, example.com or one domain per line)'));
        o.placeholder = 'example.com, sub.example.com\ndomain.com test.com\nsubdomain.domain.com another.com, third.com';
        o.depends('custom_domains_list_type', 'text');
        o.rows = 8;
        o.rmempty = false;
        o.ucisection = 'main';
        o.validate = function (section_id, value) {
            if (!value || value.length === 0) {
                return true;
            }

            const domains = value.split(/[,\s\n]/)
                .map(d => d.trim())
                .filter(d => d.length > 0);

            const domainRegex = /^(?!-)[A-Za-z0-9-]+([-.][A-Za-z0-9-]+)*\.[A-Za-z]{2,}$/;

            for (const domain of domains) {
                if (!domainRegex.test(domain)) {
                    return _('Invalid domain format: ' + domain + '. Enter domain without protocol');
                }
            }
            return true;
        };

        o = s.taboption('basic', form.Flag, 'custom_local_domains_list_enabled', _('Local Domain Lists'), _('Use the list from the router filesystem'));
        o.default = '0';
        o.rmempty = false;
        o.ucisection = 'main';

        o = s.taboption('basic', form.DynamicList, 'custom_local_domains', _('Local Domain Lists Path'), _('Enter to the list file path'));
        o.placeholder = '/path/file.lst';
        o.depends('custom_local_domains_list_enabled', '1');
        o.rmempty = false;
        o.ucisection = 'main';
        o.validate = function (section_id, value) {
            if (!value || value.length === 0) {
                return true;
            }

            try {
                const pathRegex = /^\/[a-zA-Z0-9_\-\/\.]+$/;
                if (!pathRegex.test(value)) {
                    throw new Error(_('Invalid path format. Path must start with "/" and contain only valid characters (letters, numbers, "-", "_", "/", ".")'));
                }
                return true;
            } catch (e) {
                return _('Invalid path format');
            }
        };

        o = s.taboption('basic', form.Flag, 'custom_download_domains_list_enabled', _('Remote Domain Lists'), _('Download and use domain lists from remote URLs'));
        o.default = '0';
        o.rmempty = false;
        o.ucisection = 'main';

        o = s.taboption('basic', form.DynamicList, 'custom_download_domains', _('Remote Domain URLs'), _('Enter full URLs starting with http:// or https://'));
        o.placeholder = 'URL';
        o.depends('custom_download_domains_list_enabled', '1');
        o.rmempty = false;
        o.ucisection = 'main';
        o.validate = function (section_id, value) {
            if (!value || value.length === 0) {
                return true;
            }

            try {
                const url = new URL(value);
                if (!['http:', 'https:'].includes(url.protocol)) {
                    return _('URL must use http:// or https:// protocol');
                }
                return true;
            } catch (e) {
                return _('Invalid URL format. URL must start with http:// or https://');
            }
        };


        o = s.taboption('basic', form.ListValue, 'custom_subnets_list_enabled', _('User Subnet List Type'), _('Select how to add your custom subnets'));
        o.value('disabled', _('Disabled'));
        o.value('dynamic', _('Dynamic List'));
        o.value('text', _('Text List (comma/space/newline separated)'));
        o.default = 'disabled';
        o.rmempty = false;
        o.ucisection = 'main';

        o = s.taboption('basic', form.DynamicList, 'custom_subnets', _('User Subnets'), _('Enter subnets in CIDR notation (example: 103.21.244.0/22) or single IP addresses'));
        o.placeholder = 'IP or subnet';
        o.depends('custom_subnets_list_enabled', 'dynamic');
        o.rmempty = false;
        o.ucisection = 'main';
        o.validate = function (section_id, value) {
            if (!value || value.length === 0) {
                return true;
            }

            const subnetRegex = /^(\d{1,3}\.){3}\d{1,3}(\/\d{1,2})?$/;

            if (!subnetRegex.test(value)) {
                return _('Invalid format. Use format: X.X.X.X or X.X.X.X/Y');
            }

            const [ip, cidr] = value.split('/');
            const ipParts = ip.split('.');

            for (const part of ipParts) {
                const num = parseInt(part);
                if (num < 0 || num > 255) {
                    return _('IP address parts must be between 0 and 255');
                }
            }

            if (cidr !== undefined) {
                const cidrNum = parseInt(cidr);
                if (cidrNum < 0 || cidrNum > 32) {
                    return _('CIDR must be between 0 and 32');
                }
            }

            return true;
        };

        o = s.taboption('basic', form.TextValue, 'custom_subnets_text', _('User Subnets List'), _('Enter subnets in CIDR notation or single IP addresses, separated by comma, space or newline'));
        o.placeholder = '103.21.244.0/22\n8.8.8.8\n1.1.1.1/32, 9.9.9.9 10.10.10.10';
        o.depends('custom_subnets_list_enabled', 'text');
        o.rows = 10;
        o.rmempty = false;
        o.ucisection = 'main';
        o.validate = function (section_id, value) {
            if (!value || value.length === 0) {
                return true;
            }

            // Split by commas, spaces and newlines
            const subnets = value.split(/[,\s\n]/)
                .map(s => s.trim())
                .filter(s => s.length > 0);

            const subnetRegex = /^(\d{1,3}\.){3}\d{1,3}(\/\d{1,2})?$/;

            for (const subnet of subnets) {
                if (!subnetRegex.test(subnet)) {
                    return _('Invalid format: ' + subnet + '. Use format: X.X.X.X or X.X.X.X/Y');
                }

                const [ip, cidr] = subnet.split('/');
                const ipParts = ip.split('.');

                for (const part of ipParts) {
                    const num = parseInt(part);
                    if (num < 0 || num > 255) {
                        return _('IP parts must be between 0 and 255 in: ' + subnet);
                    }
                }

                if (cidr !== undefined) {
                    const cidrNum = parseInt(cidr);
                    if (cidrNum < 0 || cidrNum > 32) {
                        return _('CIDR must be between 0 and 32 in: ' + subnet);
                    }
                }
            }
            return true;
        };

        o = s.taboption('basic', form.Flag, 'custom_download_subnets_list_enabled', _('Remote Subnet Lists'), _('Download and use subnet lists from remote URLs'));
        o.default = '0';
        o.rmempty = false;
        o.ucisection = 'main';

        o = s.taboption('basic', form.DynamicList, 'custom_download_subnets', _('Remote Subnet URLs'), _('Enter full URLs starting with http:// or https://'));
        o.placeholder = 'URL';
        o.depends('custom_download_subnets_list_enabled', '1');
        o.rmempty = false;
        o.ucisection = 'main';
        o.validate = function (section_id, value) {
            if (!value || value.length === 0) {
                return true;
            }

            try {
                const url = new URL(value);
                if (!['http:', 'https:'].includes(url.protocol)) {
                    return _('URL must use http:// or https:// protocol');
                }
                return true;
            } catch (e) {
                return _('Invalid URL format. URL must start with http:// or https://');
            }
        };

        o = s.taboption('basic', form.Flag, 'all_traffic_from_ip_enabled', _('IP for full redirection'), _('Specify local IP addresses whose traffic will always use the configured route'));
        o.default = '0';
        o.rmempty = false;
        o.ucisection = 'main';

        o = s.taboption('basic', form.DynamicList, 'all_traffic_ip', _('Local IPs'), _('Enter valid IPv4 addresses'));
        o.placeholder = 'IP';
        o.depends('all_traffic_from_ip_enabled', '1');
        o.rmempty = false;
        o.ucisection = 'main';
        o.validate = function (section_id, value) {
            if (!value || value.length === 0) {
                return true;
            }

            const ipRegex = /^(\d{1,3}\.){3}\d{1,3}$/;

            if (!ipRegex.test(value)) {
                return _('Invalid IP format. Use format: X.X.X.X (like 192.168.1.1)');
            }

            const ipParts = value.split('.');
            for (const part of ipParts) {
                const num = parseInt(part);
                if (num < 0 || num > 255) {
                    return _('IP address parts must be between 0 and 255');
                }
            }

            return true;
        };

        o = s.taboption('basic', form.Flag, 'exclude_from_ip_enabled', _('IP for exclusion'), _('Specify local IP addresses that will never use the configured route'));
        o.default = '0';
        o.rmempty = false;
        o.ucisection = 'main';

        o = s.taboption('basic', form.DynamicList, 'exclude_traffic_ip', _('Local IPs'), _('Enter valid IPv4 addresses'));
        o.placeholder = 'IP';
        o.depends('exclude_from_ip_enabled', '1');
        o.rmempty = false;
        o.ucisection = 'main';
        o.validate = function (section_id, value) {
            if (!value || value.length === 0) {
                return true;
            }

            const ipRegex = /^(\d{1,3}\.){3}\d{1,3}$/;

            if (!ipRegex.test(value)) {
                return _('Invalid IP format. Use format: X.X.X.X (like 192.168.1.1)');
            }

            const ipParts = value.split('.');
            for (const part of ipParts) {
                const num = parseInt(part);
                if (num < 0 || num > 255) {
                    return _('IP address parts must be between 0 and 255');
                }
            }

            return true;
        };

        o = s.taboption('basic', form.Flag, 'socks5', _('Mixed enable'), _('Browser port: 2080'));
        o.default = '0';
        o.rmempty = false;
        o.ucisection = 'main';

        // Additional Settings Tab
        o = s.tab('additional', _('Additional Settings'));

        o = s.taboption('additional', form.Flag, 'yacd', _('Yacd enable'), _('http://openwrt.lan:9090/ui'));
        o.default = '0';
        o.rmempty = false;
        o.ucisection = 'main';

        // o = s.taboption('additional', form.Flag, 'dont_touch_dhcp', _('Dont touch my DHCP!'), _('Podkop will not change the DHCP config'));
        // o.default = '0';
        // o.rmempty = false;
        // o.ucisection = 'main';

        o = s.taboption('additional', form.Flag, 'exclude_ntp', _('Exclude NTP'), _('For issues with open connections sing-box'));
        o.default = '0';
        o.rmempty = false;
        o.ucisection = 'main';

        o = s.taboption('additional', form.Flag, 'quic_disable', _('QUIC disable'), _('For issues with the video stream'));
        o.default = '0';
        o.rmempty = false;
        o.ucisection = 'main';

        o = s.taboption('additional', form.ListValue, 'update_interval', _('List Update Frequency'), _('Select how often the lists will be updated'));
        o.value('1h', _('Every hour'));
        o.value('3h', _('Every 3 hours'));
        o.value('12h', _('Every 12 hours'));
        o.value('1d', _('Every day'));
        o.value('3d', _('Every 3 days'));
        o.default = '1d';
        o.rmempty = false;
        o.ucisection = 'main';

        o = s.taboption('additional', form.ListValue, 'dns_type', _('DNS Protocol Type'), _('Select DNS protocol to use'));
        o.value('doh', _('DNS over HTTPS (DoH)'));
        o.value('dot', _('DNS over TLS (DoT)'));
        o.value('udp', _('UDP (Unprotected DNS)'));
        o.default = 'doh';
        o.rmempty = false;
        o.ucisection = 'main';

        o = s.taboption('additional', form.Value, 'dns_server', _('DNS Server'), _('Select or enter DNS server address'));
        o.value('1.1.1.1', 'Cloudflare (1.1.1.1)');
        o.value('8.8.8.8', 'Google (8.8.8.8)');
        o.value('9.9.9.9', 'Quad9 (9.9.9.9)');
        o.value('dns.adguard-dns.com', 'AdGuard Default (dns.adguard-dns.com)');
        o.value('unfiltered.adguard-dns.com', 'AdGuard Unfiltered (unfiltered.adguard-dns.com)');
        o.value('family.adguard-dns.com', 'AdGuard Family (family.adguard-dns.com)');
        o.default = '1.1.1.1';
        o.rmempty = false;
        o.ucisection = 'main';

        o.validate = function (section_id, value) {
            if (!value) {
                return _('DNS server address cannot be empty');
            }

            const ipRegex = /^(\d{1,3}\.){3}\d{1,3}$/;
            if (ipRegex.test(value)) {
                const parts = value.split('.');
                for (const part of parts) {
                    const num = parseInt(part);
                    if (num < 0 || num > 255) {
                        return _('IP address parts must be between 0 and 255');
                    }
                }
                return true;
            }

            const domainRegex = /^([a-zA-Z0-9-]+\.)*[a-zA-Z0-9-]+\.[a-zA-Z]{2,}$/;
            if (!domainRegex.test(value)) {
                return _('Invalid DNS server format. Examples: 8.8.8.8 or dns.example.com');
            }

            return true;
        };

        // Diagnostics tab
        o = s.tab('diagnostics', _('Diagnostics'));

        // Service Status Section
        let createStatusSection = function (podkopStatus, singboxStatus, podkop, luci, singbox, system) {
            return E('div', { 'class': 'cbi-section' }, [
                E('h3', {}, _('Service Status')),
                E('div', { 'class': 'table', style: 'display: flex; gap: 20px;' }, [
                    // Podkop Column
                    E('div', { 'style': 'flex: 1; padding: 15px; background: #f8f9fa; border-radius: 8px;' }, [
                        E('div', { 'style': 'margin-bottom: 15px;' }, [
                            E('strong', {}, _('Podkop Status')),
                            E('br'),
                            E('span', { 'style': `color: ${podkopStatus.running ? '#4caf50' : '#f44336'}` }, [
                                podkopStatus.running ? '✔' : '✘',
                                ' ',
                                podkopStatus.status
                            ])
                        ]),
                        E('div', { 'class': 'btn-group', 'style': 'display: flex; flex-direction: column; gap: 8px;' }, [
                            podkopStatus.running ?
                                E('button', {
                                    'class': 'btn cbi-button-remove',
                                    'click': function () {
                                        return fs.exec('/etc/init.d/podkop', ['stop'])
                                            .then(() => location.reload());
                                    }
                                }, _('Stop Podkop')) :
                                E('button', {
                                    'class': 'btn cbi-button-apply',
                                    'click': function () {
                                        return fs.exec('/etc/init.d/podkop', ['start'])
                                            .then(() => location.reload());
                                    }
                                }, _('Start Podkop')),
                            E('button', {
                                'class': 'btn cbi-button-apply',
                                'click': function () {
                                    return fs.exec('/etc/init.d/podkop', ['restart'])
                                        .then(() => location.reload());
                                }
                            }, _('Restart Podkop')),
                            E('button', {
                                'class': 'btn cbi-button-' + (podkopStatus.enabled ? 'remove' : 'apply'),
                                'click': function () {
                                    return fs.exec('/etc/init.d/podkop', [podkopStatus.enabled ? 'disable' : 'enable'])
                                        .then(() => location.reload());
                                }
                            }, podkopStatus.enabled ? _('Disable Podkop') : _('Enable Podkop')),
                            E('button', {
                                'class': 'btn',
                                'click': function () {
                                    return fs.exec('/etc/init.d/podkop', ['show_config'])
                                        .then(function (res) {
                                            const formattedOutput = formatDiagnosticOutput(res.stdout || _('No output'));
                                            ui.showModal(_('Podkop Configuration'), [
                                                E('div', {
                                                    style: 'max-height: 70vh;' +
                                                        'overflow-y: auto;' +
                                                        'margin: 1em 0;' +
                                                        'padding: 1.5em;' +
                                                        'background: #f8f9fa;' +
                                                        'border: 1px solid #e9ecef;' +
                                                        'border-radius: 4px;' +
                                                        'font-family: monospace;' +
                                                        'white-space: pre-wrap;' +
                                                        'word-wrap: break-word;' +
                                                        'line-height: 1.5;' +
                                                        'font-size: 14px;'
                                                }, [
                                                    E('pre', { style: 'margin: 0;' }, formattedOutput)
                                                ]),
                                                E('div', {
                                                    style: 'display: flex; justify-content: space-between; margin-top: 1em;'
                                                }, [
                                                    E('button', {
                                                        'class': 'btn',
                                                        'click': function (ev) {
                                                            const textarea = document.createElement('textarea');
                                                            textarea.value = '```txt\n' + formattedOutput + '\n```';
                                                            document.body.appendChild(textarea);
                                                            textarea.select();
                                                            try {
                                                                document.execCommand('copy');
                                                                ev.target.textContent = _('Copied!');
                                                                setTimeout(() => {
                                                                    ev.target.textContent = _('Copy to Clipboard');
                                                                }, 1000);
                                                            } catch (err) {
                                                                ui.addNotification(null, E('p', {}, _('Failed to copy: ') + err.message));
                                                            }
                                                            document.body.removeChild(textarea);
                                                        }
                                                    }, _('Copy to Clipboard')),
                                                    E('button', {
                                                        'class': 'btn',
                                                        'click': ui.hideModal
                                                    }, _('Close'))
                                                ])
                                            ]);
                                        });
                                }
                            }, _('Show Config')),
                            E('button', {
                                'class': 'btn',
                                'click': function () {
                                    return fs.exec('/etc/init.d/podkop', ['check_logs'])
                                        .then(function (res) {
                                            const formattedOutput = formatDiagnosticOutput(res.stdout || _('No output'));
                                            ui.showModal(_('Podkop Logs'), [
                                                E('div', {
                                                    style: 'max-height: 70vh;' +
                                                        'overflow-y: auto;' +
                                                        'margin: 1em 0;' +
                                                        'padding: 1.5em;' +
                                                        'background: #f8f9fa;' +
                                                        'border: 1px solid #e9ecef;' +
                                                        'border-radius: 4px;' +
                                                        'font-family: monospace;' +
                                                        'white-space: pre-wrap;' +
                                                        'word-wrap: break-word;' +
                                                        'line-height: 1.5;' +
                                                        'font-size: 14px;'
                                                }, [
                                                    E('pre', { style: 'margin: 0;' }, formattedOutput)
                                                ]),
                                                E('div', {
                                                    style: 'display: flex; justify-content: space-between; margin-top: 1em;'
                                                }, [
                                                    E('button', {
                                                        'class': 'btn',
                                                        'click': function (ev) {
                                                            const textarea = document.createElement('textarea');
                                                            textarea.value = '```txt\n' + formattedOutput + '\n```';
                                                            document.body.appendChild(textarea);
                                                            textarea.select();
                                                            try {
                                                                document.execCommand('copy');
                                                                ev.target.textContent = _('Copied!');
                                                                setTimeout(() => {
                                                                    ev.target.textContent = _('Copy to Clipboard');
                                                                }, 1000);
                                                            } catch (err) {
                                                                ui.addNotification(null, E('p', {}, _('Failed to copy: ') + err.message));
                                                            }
                                                            document.body.removeChild(textarea);
                                                        }
                                                    }, _('Copy to Clipboard')),
                                                    E('button', {
                                                        'class': 'btn',
                                                        'click': ui.hideModal
                                                    }, _('Close'))
                                                ])
                                            ]);
                                        });
                                }
                            }, _('View Logs'))
                        ])
                    ]),
                    // Sing-box Column
                    E('div', { 'style': 'flex: 1; padding: 15px; background: #f8f9fa; border-radius: 8px;' }, [
                        E('div', { 'style': 'margin-bottom: 15px;' }, [
                            E('strong', {}, _('Sing-box Status')),
                            E('br'),
                            E('span', { 'style': `color: ${singboxStatus.running ? '#4caf50' : '#f44336'}` }, [
                                singboxStatus.running ? '✔' : '✘',
                                ' ',
                                `${singboxStatus.status}`
                            ])
                        ]),
                        E('div', { 'class': 'btn-group', 'style': 'display: flex; flex-direction: column; gap: 8px;' }, [
                            E('button', {
                                'class': 'btn',
                                'click': function () {
                                    return fs.exec('/etc/init.d/podkop', ['show_sing_box_config'])
                                        .then(function (res) {
                                            const formattedOutput = formatDiagnosticOutput(res.stdout || _('No output'));
                                            ui.showModal(_('Sing-box Configuration'), [
                                                E('div', {
                                                    style: 'max-height: 70vh;' +
                                                        'overflow-y: auto;' +
                                                        'margin: 1em 0;' +
                                                        'padding: 1.5em;' +
                                                        'background: #f8f9fa;' +
                                                        'border: 1px solid #e9ecef;' +
                                                        'border-radius: 4px;' +
                                                        'font-family: monospace;' +
                                                        'white-space: pre-wrap;' +
                                                        'word-wrap: break-word;' +
                                                        'line-height: 1.5;' +
                                                        'font-size: 14px;'
                                                }, [
                                                    E('pre', { style: 'margin: 0;' }, formattedOutput)
                                                ]),
                                                E('div', {
                                                    style: 'display: flex; justify-content: space-between; margin-top: 1em;'
                                                }, [
                                                    E('button', {
                                                        'class': 'btn',
                                                        'click': function (ev) {
                                                            const textarea = document.createElement('textarea');
                                                            textarea.value = '```txt\n' + formattedOutput + '\n```';
                                                            document.body.appendChild(textarea);
                                                            textarea.select();
                                                            try {
                                                                document.execCommand('copy');
                                                                ev.target.textContent = _('Copied!');
                                                                setTimeout(() => {
                                                                    ev.target.textContent = _('Copy to Clipboard');
                                                                }, 1000);
                                                            } catch (err) {
                                                                ui.addNotification(null, E('p', {}, _('Failed to copy: ') + err.message));
                                                            }
                                                            document.body.removeChild(textarea);
                                                        }
                                                    }, _('Copy to Clipboard')),
                                                    E('button', {
                                                        'class': 'btn',
                                                        'click': ui.hideModal
                                                    }, _('Close'))
                                                ])
                                            ]);
                                        });
                                }
                            }, _('Show Config')),
                            E('button', {
                                'class': 'btn',
                                'click': function () {
                                    return fs.exec('/etc/init.d/podkop', ['check_sing_box_logs'])
                                        .then(function (res) {
                                            const formattedOutput = formatDiagnosticOutput(res.stdout || _('No output'));
                                            ui.showModal(_('Sing-box Logs'), [
                                                E('div', {
                                                    style: 'max-height: 70vh;' +
                                                        'overflow-y: auto;' +
                                                        'margin: 1em 0;' +
                                                        'padding: 1.5em;' +
                                                        'background: #f8f9fa;' +
                                                        'border: 1px solid #e9ecef;' +
                                                        'border-radius: 4px;' +
                                                        'font-family: monospace;' +
                                                        'white-space: pre-wrap;' +
                                                        'word-wrap: break-word;' +
                                                        'line-height: 1.5;' +
                                                        'font-size: 14px;'
                                                }, [
                                                    E('pre', { style: 'margin: 0;' }, formattedOutput)
                                                ]),
                                                E('div', {
                                                    style: 'display: flex; justify-content: space-between; margin-top: 1em;'
                                                }, [
                                                    E('button', {
                                                        'class': 'btn',
                                                        'click': function (ev) {
                                                            const textarea = document.createElement('textarea');
                                                            textarea.value = '```txt\n' + formattedOutput + '\n```';
                                                            document.body.appendChild(textarea);
                                                            textarea.select();
                                                            try {
                                                                document.execCommand('copy');
                                                                ev.target.textContent = _('Copied!');
                                                                setTimeout(() => {
                                                                    ev.target.textContent = _('Copy to Clipboard');
                                                                }, 1000);
                                                            } catch (err) {
                                                                ui.addNotification(null, E('p', {}, _('Failed to copy: ') + err.message));
                                                            }
                                                            document.body.removeChild(textarea);
                                                        }
                                                    }, _('Copy to Clipboard')),
                                                    E('button', {
                                                        'class': 'btn',
                                                        'click': ui.hideModal
                                                    }, _('Close'))
                                                ])
                                            ]);
                                        });
                                }
                            }, _('View Logs')),
                            E('button', {
                                'class': 'btn',
                                'click': function () {
                                    return fs.exec('/etc/init.d/podkop', ['check_sing_box_connections'])
                                        .then(function (res) {
                                            const formattedOutput = formatDiagnosticOutput(res.stdout || _('No output'));
                                            ui.showModal(_('Active Connections'), [
                                                E('div', {
                                                    style: 'max-height: 70vh;' +
                                                        'overflow-y: auto;' +
                                                        'margin: 1em 0;' +
                                                        'padding: 1.5em;' +
                                                        'background: #f8f9fa;' +
                                                        'border: 1px solid #e9ecef;' +
                                                        'border-radius: 4px;' +
                                                        'font-family: monospace;' +
                                                        'white-space: pre-wrap;' +
                                                        'word-wrap: break-word;' +
                                                        'line-height: 1.5;' +
                                                        'font-size: 14px;'
                                                }, [
                                                    E('pre', { style: 'margin: 0;' }, formattedOutput)
                                                ]),
                                                E('div', {
                                                    style: 'display: flex; justify-content: space-between; margin-top: 1em;'
                                                }, [
                                                    E('button', {
                                                        'class': 'btn',
                                                        'click': function (ev) {
                                                            const textarea = document.createElement('textarea');
                                                            textarea.value = '```txt\n' + formattedOutput + '\n```';
                                                            document.body.appendChild(textarea);
                                                            textarea.select();
                                                            try {
                                                                document.execCommand('copy');
                                                                ev.target.textContent = _('Copied!');
                                                                setTimeout(() => {
                                                                    ev.target.textContent = _('Copy to Clipboard');
                                                                }, 1000);
                                                            } catch (err) {
                                                                ui.addNotification(null, E('p', {}, _('Failed to copy: ') + err.message));
                                                            }
                                                            document.body.removeChild(textarea);
                                                        }
                                                    }, _('Copy to Clipboard')),
                                                    E('button', {
                                                        'class': 'btn',
                                                        'click': ui.hideModal
                                                    }, _('Close'))
                                                ])
                                            ]);
                                        });
                                }
                            }, _('Check Connections'))
                        ])
                    ]),
                    // Diagnostics Column
                    E('div', { 'style': 'flex: 1; padding: 15px; background: #f8f9fa; border-radius: 8px;' }, [
                        E('div', { 'style': 'margin-bottom: 15px;' }, [
                            E('strong', {}, _('FakeIP Status')),
                            E('div', { 'id': 'fakeip-status' }, [
                                E('span', {}, _('Checking FakeIP...'))
                            ])
                        ]),
                        E('div', { 'class': 'btn-group', 'style': 'display: flex; flex-direction: column; gap: 8px;' }, [
                            E('button', {
                                'class': 'btn',
                                'click': function () {
                                    return fs.exec('/etc/init.d/podkop', ['check_nft'])
                                        .then(function (res) {
                                            const formattedOutput = formatDiagnosticOutput(res.stdout || _('No output'));
                                            ui.showModal(_('NFT Rules'), [
                                                E('div', {
                                                    style: 'max-height: 70vh;' +
                                                        'overflow-y: auto;' +
                                                        'margin: 1em 0;' +
                                                        'padding: 1.5em;' +
                                                        'background: #f8f9fa;' +
                                                        'border: 1px solid #e9ecef;' +
                                                        'border-radius: 4px;' +
                                                        'font-family: monospace;' +
                                                        'white-space: pre-wrap;' +
                                                        'word-wrap: break-word;' +
                                                        'line-height: 1.5;' +
                                                        'font-size: 14px;'
                                                }, [
                                                    E('pre', { style: 'margin: 0;' }, formattedOutput)
                                                ]),
                                                E('div', {
                                                    style: 'display: flex; justify-content: space-between; margin-top: 1em;'
                                                }, [
                                                    E('button', {
                                                        'class': 'btn',
                                                        'click': function (ev) {
                                                            const textarea = document.createElement('textarea');
                                                            textarea.value = '```txt\n' + formattedOutput + '\n```';
                                                            document.body.appendChild(textarea);
                                                            textarea.select();
                                                            try {
                                                                document.execCommand('copy');
                                                                ev.target.textContent = _('Copied!');
                                                                setTimeout(() => {
                                                                    ev.target.textContent = _('Copy to Clipboard');
                                                                }, 1000);
                                                            } catch (err) {
                                                                ui.addNotification(null, E('p', {}, _('Failed to copy: ') + err.message));
                                                            }
                                                            document.body.removeChild(textarea);
                                                        }
                                                    }, _('Copy to Clipboard')),
                                                    E('button', {
                                                        'class': 'btn',
                                                        'click': ui.hideModal
                                                    }, _('Close'))
                                                ])
                                            ]);
                                        });
                                }
                            }, _('Check NFT Rules')),
                            E('button', {
                                'class': 'btn',
                                'click': function () {
                                    return fs.exec('/etc/init.d/podkop', ['check_dnsmasq'])
                                        .then(function (res) {
                                            const formattedOutput = formatDiagnosticOutput(res.stdout || _('No output'));
                                            ui.showModal(_('DNSMasq Configuration'), [
                                                E('div', {
                                                    style: 'max-height: 70vh;' +
                                                        'overflow-y: auto;' +
                                                        'margin: 1em 0;' +
                                                        'padding: 1.5em;' +
                                                        'background: #f8f9fa;' +
                                                        'border: 1px solid #e9ecef;' +
                                                        'border-radius: 4px;' +
                                                        'font-family: monospace;' +
                                                        'white-space: pre-wrap;' +
                                                        'word-wrap: break-word;' +
                                                        'line-height: 1.5;' +
                                                        'font-size: 14px;'
                                                }, [
                                                    E('pre', { style: 'margin: 0;' }, formattedOutput)
                                                ]),
                                                E('div', {
                                                    style: 'display: flex; justify-content: space-between; margin-top: 1em;'
                                                }, [
                                                    E('button', {
                                                        'class': 'btn',
                                                        'click': function (ev) {
                                                            const textarea = document.createElement('textarea');
                                                            textarea.value = '```txt\n' + formattedOutput + '\n```';
                                                            document.body.appendChild(textarea);
                                                            textarea.select();
                                                            try {
                                                                document.execCommand('copy');
                                                                ev.target.textContent = _('Copied!');
                                                                setTimeout(() => {
                                                                    ev.target.textContent = _('Copy to Clipboard');
                                                                }, 1000);
                                                            } catch (err) {
                                                                ui.addNotification(null, E('p', {}, _('Failed to copy: ') + err.message));
                                                            }
                                                            document.body.removeChild(textarea);
                                                        }
                                                    }, _('Copy to Clipboard')),
                                                    E('button', {
                                                        'class': 'btn',
                                                        'click': ui.hideModal
                                                    }, _('Close'))
                                                ])
                                            ]);
                                        });
                                }
                            }, _('Check DNSMasq')),
                            E('button', {
                                'class': 'btn',
                                'click': function () {
                                    return fs.exec('/etc/init.d/podkop', ['list_update'])
                                        .then(function (res) {
                                            const formattedOutput = formatDiagnosticOutput(res.stdout || _('No output'));
                                            ui.showModal(_('Lists Update Results'), [
                                                E('div', {
                                                    style: 'max-height: 70vh;' +
                                                        'overflow-y: auto;' +
                                                        'margin: 1em 0;' +
                                                        'padding: 1.5em;' +
                                                        'background: #f8f9fa;' +
                                                        'border: 1px solid #e9ecef;' +
                                                        'border-radius: 4px;' +
                                                        'font-family: monospace;' +
                                                        'white-space: pre-wrap;' +
                                                        'word-wrap: break-word;' +
                                                        'line-height: 1.5;' +
                                                        'font-size: 14px;'
                                                }, [
                                                    E('pre', { style: 'margin: 0;' }, formattedOutput)
                                                ]),
                                                E('div', {
                                                    style: 'display: flex; justify-content: space-between; margin-top: 1em;'
                                                }, [
                                                    E('button', {
                                                        'class': 'btn',
                                                        'click': function (ev) {
                                                            const textarea = document.createElement('textarea');
                                                            textarea.value = '```txt\n' + formattedOutput + '\n```';
                                                            document.body.appendChild(textarea);
                                                            textarea.select();
                                                            try {
                                                                document.execCommand('copy');
                                                                ev.target.textContent = _('Copied!');
                                                                setTimeout(() => {
                                                                    ev.target.textContent = _('Copy to Clipboard');
                                                                }, 1000);
                                                            } catch (err) {
                                                                ui.addNotification(null, E('p', {}, _('Failed to copy: ') + err.message));
                                                            }
                                                            document.body.removeChild(textarea);
                                                        }
                                                    }, _('Copy to Clipboard')),
                                                    E('button', {
                                                        'class': 'btn',
                                                        'click': ui.hideModal
                                                    }, _('Close'))
                                                ])
                                            ]);
                                        });
                                }
                            }, _('Update Lists'))
                        ])
                    ]),
                    // Version Information Column
                    E('div', { 'style': 'flex: 1; padding: 15px; background: #f8f9fa; border-radius: 8px;' }, [
                        E('div', { 'style': 'margin-bottom: 15px;' }, [
                            E('strong', {}, _('Version Information')),
                            E('br'),
                            E('div', { 'style': 'margin-top: 10px; font-family: monospace; white-space: pre-wrap;' }, [
                                E('strong', {}, 'Podkop: '), podkop.stdout ? podkop.stdout.trim() : _('Unknown'), '\n',
                                E('strong', {}, 'LuCI App: '), luci.stdout ? luci.stdout.trim() : _('Unknown'), '\n',
                                E('strong', {}, 'Sing-box: '), singbox.stdout ? singbox.stdout.trim() : _('Unknown'), '\n',
                                E('strong', {}, 'OpenWrt Version: '), system.stdout ? system.stdout.split('\n')[1].trim() : _('Unknown'), '\n',
                                E('strong', {}, 'Device Model: '), system.stdout ? system.stdout.split('\n')[4].trim() : _('Unknown')
                            ])
                        ])
                    ]),
                ])
            ]);
        };

        o = s.taboption('diagnostics', form.DummyValue, '_status');
        o.rawhtml = true;
        o.cfgvalue = function () {
            return E('div', { id: 'diagnostics-status' }, _('Loading diagnostics...'));
        };

        function checkFakeIP() {
            let lastStatus = null;
            let statusElement = document.getElementById('fakeip-status');

            function updateFakeIPStatus() {
                const controller = new AbortController();
                const timeoutId = setTimeout(() => controller.abort(), 10000);

                fetch('http://httpbin.org/ip', {
                    signal: controller.signal
                })
                    .then(response => response.text())
                    .then(text => {
                        clearTimeout(timeoutId);
                        if (!statusElement) {
                            statusElement = document.getElementById('fakeip-status');
                            if (!statusElement) return;
                        }

                        console.log('FakeIP check response:', text);

                        let currentStatus;
                        let statusHTML;

                        if (text.includes('Cannot GET /ip')) {
                            console.log('FakeIP status: working (Cannot GET /ip)');
                            currentStatus = 'working';
                            statusHTML = E('span', { 'style': 'color: #4caf50' }, [
                                '✔ ',
                                _('working')
                            ]).outerHTML;
                        } else if (text.includes('"origin":')) {
                            console.log('FakeIP status: not working (got IP response)');
                            currentStatus = 'not_working';
                            statusHTML = E('span', { 'style': 'color: #f44336' }, [
                                '✘ ',
                                _('not working')
                            ]).outerHTML;
                        } else {
                            console.log('FakeIP status: check error (unexpected response)');
                            currentStatus = 'error';
                            statusHTML = E('span', { 'style': 'color: #ff9800' }, [
                                '! ',
                                _('check error')
                            ]).outerHTML;
                        }

                        if (currentStatus !== lastStatus) {
                            lastStatus = currentStatus;
                            statusElement.innerHTML = statusHTML;
                        }
                    })
                    .catch(error => {
                        clearTimeout(timeoutId);
                        console.log('FakeIP check error:', error.message);
                        const errorStatus = 'error';
                        if (errorStatus !== lastStatus) {
                            lastStatus = errorStatus;
                            if (statusElement) {
                                statusElement.innerHTML = E('span', { 'style': 'color: #ff9800' }, [
                                    '! ',
                                    error.name === 'AbortError' ? _('timeout') : _('check error')
                                ]).outerHTML;
                            }
                        }
                    });
            }

            updateFakeIPStatus();

            // Set up periodic checks every 10 seconds
            const intervalId = setInterval(updateFakeIPStatus, 10000);

            window.addEventListener('unload', () => {
                clearInterval(intervalId);
            });
        }

        function updateDiagnostics() {
            Promise.all([
                fs.exec('/etc/init.d/podkop', ['get_status']),
                fs.exec('/etc/init.d/podkop', ['get_sing_box_status']),
                fs.exec('/etc/init.d/podkop', ['show_version']),
                fs.exec('/etc/init.d/podkop', ['show_luci_version']),
                fs.exec('/etc/init.d/podkop', ['show_sing_box_version']),
                fs.exec('/etc/init.d/podkop', ['show_system_info'])
            ]).then(function ([podkopStatus, singboxStatus, podkop, luci, singbox, system]) {
                try {
                    const parsedPodkopStatus = JSON.parse(podkopStatus.stdout || '{"running":0,"enabled":0,"status":"unknown"}');
                    const parsedSingboxStatus = JSON.parse(singboxStatus.stdout || '{"running":0,"enabled":0,"status":"unknown"}');
                    var newContent = createStatusSection(parsedPodkopStatus, parsedSingboxStatus, podkop, luci, singbox, system);
                    var container = document.getElementById('diagnostics-status');
                    if (container) {
                        container.innerHTML = '';
                        container.appendChild(newContent);
                        checkFakeIP();
                    }
                } catch (e) {
                    console.error('Error parsing diagnostics status:', e);
                    var container = document.getElementById('diagnostics-status');
                    if (container) {
                        container.innerHTML = '<div class="alert-message warning"><strong>' + _('Error loading diagnostics') + '</strong><br><pre>' + e.toString() + '</pre></div>';
                    }
                }
            });
        }

        // Add new section 'extra'
        var s = m.section(form.TypedSection, 'extra', _('Extra configurations'));
        s.anonymous = false;
        s.addremove = true;
        s.addbtntitle = _('Add Section');

        o = s.tab('basic', _('Extra configuration'));

        o = s.taboption('basic', form.ListValue, 'mode', _('Connection Type'), _('Select between VPN and Proxy connection methods for traffic routing'));
        o.value('proxy', ('Proxy'));
        o.value('vpn', ('VPN'));

        o = s.taboption('basic', form.ListValue, 'proxy_config_type', _('Configuration Type'), _('Select how to configure the proxy'));
        o.value('url', _('Connection URL'));
        o.value('outbound', _('Outbound Config'));
        o.default = 'url';
        o.depends('mode', 'proxy');

        o = s.taboption('basic', form.TextValue, 'proxy_string', _('Proxy Configuration URL'), _('Enter connection string starting with vless:// or ss:// for proxy configuration'));
        o.depends('proxy_config_type', 'url');
        o.rows = 5;

        o = s.taboption('basic', form.TextValue, 'outbound_json', _('Outbound Configuration'), _('Enter complete outbound configuration in JSON format'));
        o.depends('proxy_config_type', 'outbound');
        o.rows = 10;
        o.validate = function (section_id, value) {
            if (!value || value.length === 0) {
                return true;
            }

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

        o = s.taboption('basic', form.ListValue, 'interface', _('Network Interface'), _('Select network interface for VPN connection'));
        o.depends('mode', 'vpn');

        try {
            const devices = await network.getDevices();
            const excludeInterfaces = ['br-lan', 'eth0', 'eth1', 'wan', 'phy0-ap0', 'phy1-ap0'];

            devices.forEach(function (device) {
                if (device.dev && device.dev.name) {
                    const deviceName = device.dev.name;
                    const isExcluded = excludeInterfaces.includes(deviceName) || /^lan\d+$/.test(deviceName);

                    if (!isExcluded) {
                        o.value(deviceName, deviceName);
                    }
                }
            });
        } catch (error) {
            console.error('Error fetching devices:', error);
        }

        o = s.taboption('basic', form.Flag, 'domain_list_enabled', _('Community Lists'));
        o.default = '0';
        o.rmempty = false;

        o = s.taboption('basic', form.DynamicList, 'domain_list', _('Service List'), _('Select predefined service networks for routing') + ' <a href="https://github.com/itdoginfo/allow-domains" target="_blank">github.com/itdoginfo/allow-domains</a>');
        o.placeholder = 'Service list';
        o.value('russia_inside', 'Russia inside');
        o.value('russia_outside', 'Russia outside');
        o.value('ukraine_inside', 'Ukraine');
        o.value('geoblock', 'GEO Block');
        o.value('block', 'Block');
        o.value('porn', 'Porn');
        o.value('news', 'News');
        o.value('anime', 'Anime');
        o.value('youtube', 'Youtube');
        o.value('discord', 'Discord');
        o.value('meta', 'Meta');
        o.value('twitter', 'Twitter (X)');
        o.value('hdrezka', 'HDRezka');
        o.value('tiktok', 'Tik-Tok');
        o.value('telegram', 'Telegram');
        o.depends('domain_list_enabled', '1');
        o.rmempty = false;

        o = s.taboption('basic', form.ListValue, 'custom_domains_list_type', _('User Domain List Type'), _('Select how to add your custom domains'));
        o.value('disabled', _('Disabled'));
        o.value('dynamic', _('Dynamic List'));
        o.value('text', _('Text List'));
        o.default = 'disabled';
        o.rmempty = false;

        o = s.taboption('basic', form.DynamicList, 'custom_domains', _('User Domains'), _('Enter domain names without protocols (example: sub.example.com or example.com)'));
        o.placeholder = 'Domains list';
        o.depends('custom_domains_list_type', 'dynamic');
        o.rmempty = false;
        o.validate = function (section_id, value) {
            if (!value || value.length === 0) {
                return true;
            }

            const domainRegex = /^(?!-)[A-Za-z0-9-]+([-.][A-Za-z0-9-]+)*\.[A-Za-z]{2,}$/;

            if (!domainRegex.test(value)) {
                return _('Invalid domain format. Enter domain without protocol (example: sub.example.com)');
            }
            return true;
        };

        o = s.taboption('basic', form.TextValue, 'custom_domains_text', _('User Domains List'), _('Enter domain names separated by comma, space or newline (example: sub.example.com, example.com or one domain per line)'));
        o.placeholder = 'example.com, sub.example.com\ndomain.com test.com\nsubdomain.domain.com another.com, third.com';
        o.depends('custom_domains_list_type', 'text');
        o.rows = 10;
        o.rmempty = false;
        o.validate = function (section_id, value) {
            if (!value || value.length === 0) {
                return true;
            }

            const domains = value.split(/[,\s\n]/)
                .map(d => d.trim())
                .filter(d => d.length > 0);

            const domainRegex = /^(?!-)[A-Za-z0-9-]+([-.][A-Za-z0-9-]+)*\.[A-Za-z]{2,}$/;

            for (const domain of domains) {
                if (!domainRegex.test(domain)) {
                    return _('Invalid domain format: ' + domain + '. Enter domain without protocol');
                }
            }
            return true;
        };

        o = s.taboption('basic', form.Flag, 'custom_local_domains_list_enabled', _('Local Domain Lists'), _('Use the list from the router filesystem'));
        o.default = '0';
        o.rmempty = false;

        o = s.taboption('basic', form.DynamicList, 'custom_local_domains', _('Local Domain Lists Path'), _('Enter to the list file path'));
        o.placeholder = '/path/file.lst';
        o.depends('custom_local_domains_list_enabled', '1');
        o.rmempty = false;
        o.validate = function (section_id, value) {
            if (!value || value.length === 0) {
                return true;
            }

            try {
                const pathRegex = /^\/[a-zA-Z0-9_\-\/\.]+$/;
                if (!pathRegex.test(value)) {
                    throw new Error(_('Invalid path format. Path must start with "/" and contain only valid characters (letters, numbers, "-", "_", "/", ".")'));
                }
                return true;
            } catch (e) {
                return _('Invalid path format');
            }
        };

        o = s.taboption('basic', form.Flag, 'custom_download_domains_list_enabled', _('Remote Domain Lists'), _('Download and use domain lists from remote URLs'));
        o.default = '0';
        o.rmempty = false;

        o = s.taboption('basic', form.DynamicList, 'custom_download_domains', _('Remote Domain URLs'), _('Enter full URLs starting with http:// or https://'));
        o.placeholder = 'URL';
        o.depends('custom_download_domains_list_enabled', '1');
        o.rmempty = false;
        o.validate = function (section_id, value) {
            if (!value || value.length === 0) {
                return true;
            }

            try {
                const url = new URL(value);
                if (!['http:', 'https:'].includes(url.protocol)) {
                    return _('URL must use http:// or https:// protocol');
                }
                return true;
            } catch (e) {
                return _('Invalid URL format. URL must start with http:// or https://');
            }
        };


        o = s.taboption('basic', form.ListValue, 'custom_subnets_list_enabled', _('User Subnet List Type'), _('Select how to add your custom subnets'));
        o.value('disabled', _('Disabled'));
        o.value('dynamic', _('Dynamic List'));
        o.value('text', _('Text List (comma/space/newline separated)'));
        o.default = 'disabled';
        o.rmempty = false;

        o = s.taboption('basic', form.DynamicList, 'custom_subnets', _('User Subnets'), _('Enter subnets in CIDR notation (example: 103.21.244.0/22) or single IP addresses'));
        o.placeholder = 'IP or subnet';
        o.depends('custom_subnets_list_enabled', 'dynamic');
        o.rmempty = false;
        o.validate = function (section_id, value) {
            if (!value || value.length === 0) {
                return true;
            }

            const subnetRegex = /^(\d{1,3}\.){3}\d{1,3}(\/\d{1,2})?$/;

            if (!subnetRegex.test(value)) {
                return _('Invalid format. Use format: X.X.X.X or X.X.X.X/Y');
            }

            const [ip, cidr] = value.split('/');
            const ipParts = ip.split('.');

            for (const part of ipParts) {
                const num = parseInt(part);
                if (num < 0 || num > 255) {
                    return _('IP address parts must be between 0 and 255');
                }
            }

            if (cidr !== undefined) {
                const cidrNum = parseInt(cidr);
                if (cidrNum < 0 || cidrNum > 32) {
                    return _('CIDR must be between 0 and 32');
                }
            }

            return true;
        };

        o = s.taboption('basic', form.TextValue, 'custom_subnets_text', _('User Subnets List'), _('Enter subnets in CIDR notation or single IP addresses, separated by comma, space or newline'));
        o.placeholder = '103.21.244.0/22\n8.8.8.8\n1.1.1.1/32, 9.9.9.9 10.10.10.10';
        o.depends('custom_subnets_list_enabled', 'text');
        o.rows = 10;
        o.rmempty = false;
        o.validate = function (section_id, value) {
            if (!value || value.length === 0) {
                return true;
            }

            // Split by commas, spaces and newlines
            const subnets = value.split(/[,\s\n]/)
                .map(s => s.trim())
                .filter(s => s.length > 0);

            const subnetRegex = /^(\d{1,3}\.){3}\d{1,3}(\/\d{1,2})?$/;

            for (const subnet of subnets) {
                if (!subnetRegex.test(subnet)) {
                    return _('Invalid format: ' + subnet + '. Use format: X.X.X.X or X.X.X.X/Y');
                }

                const [ip, cidr] = subnet.split('/');
                const ipParts = ip.split('.');

                for (const part of ipParts) {
                    const num = parseInt(part);
                    if (num < 0 || num > 255) {
                        return _('IP parts must be between 0 and 255 in: ' + subnet);
                    }
                }

                if (cidr !== undefined) {
                    const cidrNum = parseInt(cidr);
                    if (cidrNum < 0 || cidrNum > 32) {
                        return _('CIDR must be between 0 and 32 in: ' + subnet);
                    }
                }
            }
            return true;
        };

        o = s.taboption('basic', form.Flag, 'custom_download_subnets_list_enabled', _('Remote Subnet Lists'), _('Download and use subnet lists from remote URLs'));
        o.default = '0';
        o.rmempty = false;

        o = s.taboption('basic', form.DynamicList, 'custom_download_subnets', _('Remote Subnet URLs'), _('Enter full URLs starting with http:// or https://'));
        o.placeholder = 'URL';
        o.depends('custom_download_subnets_list_enabled', '1');
        o.rmempty = false;
        o.validate = function (section_id, value) {
            if (!value || value.length === 0) {
                return true;
            }

            try {
                const url = new URL(value);
                if (!['http:', 'https:'].includes(url.protocol)) {
                    return _('URL must use http:// or https:// protocol');
                }
                return true;
            } catch (e) {
                return _('Invalid URL format. URL must start with http:// or https://');
            }
        };

        o = s.taboption('basic', form.Flag, 'all_traffic_from_ip_enabled', _('IP for full redirection'), _('Specify local IP addresses whose traffic will always use the configured route'));
        o.default = '0';
        o.rmempty = false;

        o = s.taboption('basic', form.DynamicList, 'all_traffic_ip', _('Local IPs'), _('Enter valid IPv4 addresses'));
        o.placeholder = 'IP';
        o.depends('all_traffic_from_ip_enabled', '1');
        o.rmempty = false;
        o.validate = function (section_id, value) {
            if (!value || value.length === 0) {
                return true;
            }

            const ipRegex = /^(\d{1,3}\.){3}\d{1,3}$/;

            if (!ipRegex.test(value)) {
                return _('Invalid IP format. Use format: X.X.X.X (like 192.168.1.1)');
            }

            const ipParts = value.split('.');
            for (const part of ipParts) {
                const num = parseInt(part);
                if (num < 0 || num > 255) {
                    return _('IP address parts must be between 0 and 255');
                }
            }

            return true;
        };

        // For future
        // o = s.taboption('basic', form.Flag, 'socks5', _('Mixed enable'), _('Browser port: 2080 (extra +1)'));
        // o.default = '0';
        // o.rmempty = false;

        let map_promise = m.render();

        map_promise.then(node => {
            node.classList.add('fade-in');
            updateDiagnostics();
            return node;
        });

        return map_promise;
    }
});