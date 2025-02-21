'use strict';
'require view';
'require form';
'require ui';
'require network';
'require fs';

function formatDiagnosticOutput(output) {
    if (typeof output !== 'string') return '';
    return output.trim()
        .replace(/\x1b\[[0-9;]*m/g, '')  // Remove ANSI color codes
        .replace(/\r\n/g, '\n')          // Normalize line endings
        .replace(/\r/g, '\n');
}

function getNetworkInterfaces(o) {
    const excludeInterfaces = ['br-lan', 'eth0', 'eth1', 'wan', 'phy0-ap0', 'phy1-ap0', 'pppoe-wan'];

    return network.getDevices().then(devices => {
        devices.forEach(device => {
            if (device.dev && device.dev.name) {
                const deviceName = device.dev.name;
                if (!excludeInterfaces.includes(deviceName) && !/^lan\d+$/.test(deviceName)) {
                    o.value(deviceName, deviceName);
                }
            }
        });
    }).catch(error => {
        console.error('Failed to get network devices:', error);
    });
}

// Общая функция для создания конфигурационных секций
function createConfigSection(section, map, network) {
    const s = section;

    let o = s.tab('basic', _('Basic Settings'));

    o = s.taboption('basic', form.ListValue, 'mode', _('Connection Type'), _('Select between VPN and Proxy connection methods for traffic routing'));
    o.value('proxy', ('Proxy'));
    o.value('vpn', ('VPN'));
    o.ucisection = s.section;

    o = s.taboption('basic', form.ListValue, 'proxy_config_type', _('Configuration Type'), _('Select how to configure the proxy'));
    o.value('url', _('Connection URL'));
    o.value('outbound', _('Outbound Config'));
    o.default = 'url';
    o.depends('mode', 'proxy');
    o.ucisection = s.section;

    o = s.taboption('basic', form.TextValue, 'proxy_string', _('Proxy Configuration URL'), _('Enter connection string starting with vless:// or ss:// for proxy configuration'));
    o.depends('proxy_config_type', 'url');
    o.rows = 5;
    o.ucisection = s.section;
    o.load = function (section_id) {
        return new Promise((resolve, reject) => {
            const timeout = setTimeout(() => {
                console.error('Label fetch timeout');
                resolve(this.super('load', section_id));
            }, 5000); // 5 second timeout

            fs.exec('/etc/init.d/podkop', ['get_proxy_label', section_id])
                .then(res => {
                    clearTimeout(timeout);
                    if (res.stdout) {
                        try {
                            const chunks = res.stdout.trim().split('\n');
                            const fullLabel = chunks.join('');
                            const decodedLabel = decodeURIComponent(fullLabel);
                            this.description = _('Current config: ') + decodedLabel;
                        } catch (e) {
                            console.error('Error processing label:', e);
                            // If decoding fails, try to display the raw chunks
                            const chunks = res.stdout.trim().split('\n');
                            const fullLabel = chunks.join('');
                            this.description = _('Current config: ') + fullLabel;
                        }
                    }
                    resolve(this.super('load', section_id));
                })
                .catch(error => {
                    clearTimeout(timeout);
                    console.error('Error fetching label:', error);
                    resolve(this.super('load', section_id));
                });
        });
    };
    o.validate = function (section_id, value) {
        if (!value || value.length === 0) {
            return true;
        }

        try {
            if (!value.startsWith('vless://') && !value.startsWith('ss://')) {
                return _('URL must start with vless:// or ss://');
            }

            if (value.startsWith('ss://')) {
                let encrypted_part;
                try {
                    let mainPart = value.includes('?') ? value.split('?')[0] : value.split('#')[0];
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
                    let serverPart = value.split('@')[1];
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

            if (value.startsWith('vless://')) {
                let uuid = value.split('/')[2].split('@')[0];
                if (!uuid || uuid.length === 0) return _('Invalid VLESS URL: missing UUID');

                try {
                    let serverPart = value.split('@')[1];
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

                let queryString = value.split('?')[1];
                if (!queryString) return _('Invalid VLESS URL: missing query parameters');

                let params = new URLSearchParams(queryString.split('#')[0]);
                let type = params.get('type');
                const validTypes = ['tcp', 'udp', 'grpc', 'http'];
                if (!type || !validTypes.includes(type)) {
                    return _('Invalid VLESS URL: type must be one of tcp, udp, grpc, http');
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

                if (security === 'tls' && type !== 'tcp' && !params.get('sni')) {
                    return _('Invalid VLESS URL: missing sni parameter for tls security');
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

    o = s.taboption('basic', form.ListValue, 'interface', _('Network Interface'), _('Select network interface for VPN connection'));
    o.depends('mode', 'vpn');
    o.ucisection = s.section;
    getNetworkInterfaces(o);

    o = s.taboption('basic', form.Flag, 'domain_list_enabled', _('Community Lists'));
    o.default = '0';
    o.rmempty = false;
    o.ucisection = s.section;

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

            const regionalOptions = ['russia_inside', 'russia_outside', 'ukraine_inside'];
            const selectedRegionalOptions = regionalOptions.filter(opt => newValues.includes(opt));

            if (selectedRegionalOptions.length > 1) {
                const lastSelected = selectedRegionalOptions[selectedRegionalOptions.length - 1];
                const removedRegions = selectedRegionalOptions.slice(0, -1);
                newValues = newValues.filter(v => v === lastSelected || !regionalOptions.includes(v));
                notifications.push(E('p', { class: 'alert-message warning' }, [
                    E('strong', {}, _('Regional options cannot be used together')), E('br'),
                    _('Warning: %s cannot be used together with %s. Previous selections have been removed.')
                        .format(removedRegions.join(', '), lastSelected)
                ]));
            }

            if (newValues.includes('russia_inside')) {
                const allowedWithRussiaInside = ['russia_inside', 'meta', 'twitter', 'discord', 'telegram'];
                const removedServices = newValues.filter(v => !allowedWithRussiaInside.includes(v));
                if (removedServices.length > 0) {
                    newValues = newValues.filter(v => allowedWithRussiaInside.includes(v));
                    notifications.push(E('p', { class: 'alert-message warning' }, [
                        E('strong', {}, _('Russia inside restrictions')), E('br'),
                        _('Warning: Russia inside can only be used with Meta, Twitter, Discord, and Telegram. %s already in Russia inside and have been removed from selection.')
                            .format(removedServices.join(', '))
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

    o = s.taboption('basic', form.TextValue, 'custom_domains_text', _('User Domains List'), _('Enter domain names separated by comma, space or newline'));
    o.placeholder = 'example.com, sub.example.com\ndomain.com test.com';
    o.depends('custom_domains_list_type', 'text');
    o.rows = 8;
    o.rmempty = false;
    o.ucisection = s.section;
    o.validate = function (section_id, value) {
        if (!value || value.length === 0) return true;
        const domains = value.split(/[,\s\n]/).map(d => d.trim()).filter(d => d.length > 0);
        const domainRegex = /^(?!-)[A-Za-z0-9-]+([-.][A-Za-z0-9-]+)*(\.[A-Za-z]{2,})?$/;
        for (const domain of domains) {
            if (!domainRegex.test(domain)) return _('Invalid domain format: %s. Enter domain without protocol').format(domain);
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
        try {
            const url = new URL(value);
            if (!['http:', 'https:'].includes(url.protocol)) return _('URL must use http:// or https:// protocol');
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

    o = s.taboption('basic', form.TextValue, 'custom_subnets_text', _('User Subnets List'), _('Enter subnets in CIDR notation or single IP addresses, separated by comma, space or newline'));
    o.placeholder = '103.21.244.0/22\n8.8.8.8\n1.1.1.1/32, 9.9.9.9';
    o.depends('custom_subnets_list_enabled', 'text');
    o.rows = 10;
    o.rmempty = false;
    o.ucisection = s.section;
    o.validate = function (section_id, value) {
        if (!value || value.length === 0) return true;
        const subnets = value.split(/[,\s\n]/).map(s => s.trim()).filter(s => s.length > 0);
        const subnetRegex = /^(\d{1,3}\.){3}\d{1,3}(\/\d{1,2})?$/;
        for (const subnet of subnets) {
            if (!subnetRegex.test(subnet)) return _('Invalid format: %s. Use format: X.X.X.X or X.X.X.X/Y').format(subnet);
            const [ip, cidr] = subnet.split('/');
            const ipParts = ip.split('.');
            for (const part of ipParts) {
                const num = parseInt(part);
                if (num < 0 || num > 255) return _('IP parts must be between 0 and 255 in: %s').format(subnet);
            }
            if (cidr !== undefined) {
                const cidrNum = parseInt(cidr);
                if (cidrNum < 0 || cidrNum > 32) return _('CIDR must be between 0 and 32 in: %s').format(subnet);
            }
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
        try {
            const url = new URL(value);
            if (!['http:', 'https:'].includes(url.protocol)) return _('URL must use http:// or https:// protocol');
            return true;
        } catch (e) {
            return _('Invalid URL format. URL must start with http:// or https://');
        }
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

        const m = new form.Map('podkop', _('Podkop configuration'), null, ['main', 'extra']);
        fs.exec('/etc/init.d/podkop', ['show_version']).then(res => {
            if (res.stdout) m.title = _('Podkop') + ' v' + res.stdout.trim();
        });

        // Main Section
        const mainSection = m.section(form.TypedSection, 'main');
        mainSection.anonymous = true;
        createConfigSection(mainSection, m, network);

        // Additional Settings Tab (main section)
        let o = mainSection.tab('additional', _('Additional Settings'));

        o = mainSection.taboption('additional', form.Flag, 'yacd', _('Yacd enable'), _('http://openwrt.lan:9090/ui'));
        o.default = '0';
        o.rmempty = false;
        o.ucisection = 'main';

        o = mainSection.taboption('additional', form.Flag, 'exclude_ntp', _('Exclude NTP'), _('For issues with open connections sing-box'));
        o.default = '0';
        o.rmempty = false;
        o.ucisection = 'main';

        o = mainSection.taboption('additional', form.Flag, 'quic_disable', _('QUIC disable'), _('For issues with the video stream'));
        o.default = '0';
        o.rmempty = false;
        o.ucisection = 'main';

        o = mainSection.taboption('additional', form.ListValue, 'update_interval', _('List Update Frequency'), _('Select how often the lists will be updated'));
        o.value('1h', _('Every hour'));
        o.value('3h', _('Every 3 hours'));
        o.value('12h', _('Every 12 hours'));
        o.value('1d', _('Every day'));
        o.value('3d', _('Every 3 days'));
        o.default = '1d';
        o.rmempty = false;
        o.ucisection = 'main';

        o = mainSection.taboption('additional', form.ListValue, 'dns_type', _('DNS Protocol Type'), _('Select DNS protocol to use'));
        o.value('doh', _('DNS over HTTPS (DoH)'));
        o.value('dot', _('DNS over TLS (DoT)'));
        o.value('udp', _('UDP (Unprotected DNS)'));
        o.default = 'doh';
        o.rmempty = false;
        o.ucisection = 'main';

        o = mainSection.taboption('additional', form.Value, 'dns_server', _('DNS Server'), _('Select or enter DNS server address'));
        o.value('1.1.1.1', 'Cloudflare (1.1.1.1)');
        o.value('8.8.8.8', 'Google (8.8.8.8)');
        o.value('9.9.9.9', 'Quad9 (9.9.9.9)');
        o.value('dns.adguard-dns.com', 'AdGuard Default');
        o.value('unfiltered.adguard-dns.com', 'AdGuard Unfiltered');
        o.value('family.adguard-dns.com', 'AdGuard Family');
        o.default = '1.1.1.1';
        o.rmempty = false;
        o.ucisection = 'main';
        o.validate = function (section_id, value) {
            if (!value) return _('DNS server address cannot be empty');
            const ipRegex = /^(\d{1,3}\.){3}\d{1,3}$/;
            if (ipRegex.test(value)) {
                const parts = value.split('.');
                for (const part of parts) {
                    const num = parseInt(part);
                    if (num < 0 || num > 255) return _('IP address parts must be between 0 and 255');
                }
                return true;
            }
            const domainRegex = /^([a-zA-Z0-9-]+\.)*[a-zA-Z0-9-]+\.[a-zA-Z]{2,}$/;
            if (!domainRegex.test(value)) return _('Invalid DNS server format. Examples: 8.8.8.8 or dns.example.com');
            return true;
        };

        // Extra IPs and exclusions (main section)
        o = mainSection.taboption('basic', form.Flag, 'exclude_from_ip_enabled', _('IP for exclusion'), _('Specify local IP addresses that will never use the configured route'));
        o.default = '0';
        o.rmempty = false;
        o.ucisection = 'main';

        o = mainSection.taboption('basic', form.DynamicList, 'exclude_traffic_ip', _('Local IPs'), _('Enter valid IPv4 addresses'));
        o.placeholder = 'IP';
        o.depends('exclude_from_ip_enabled', '1');
        o.rmempty = false;
        o.ucisection = 'main';
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

        o = mainSection.taboption('basic', form.Flag, 'socks5', _('Mixed enable'), _('Browser port: 2080'));
        o.default = '0';
        o.rmempty = false;
        o.ucisection = 'main';

        // Diagnostics Tab (main section)
        o = mainSection.tab('diagnostics', _('Diagnostics'));

        let createStatusSection = function (podkopStatus, singboxStatus, podkop, luci, singbox, system) {
            return E('div', { 'class': 'cbi-section' }, [
                E('h3', {}, _('Service Status')),
                E('div', { 'class': 'table', style: 'display: flex; gap: 20px;' }, [
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
                                    'click': () => fs.exec('/etc/init.d/podkop', ['stop']).then(() => location.reload())
                                }, _('Stop Podkop')) :
                                E('button', {
                                    'class': 'btn cbi-button-apply',
                                    'click': () => fs.exec('/etc/init.d/podkop', ['start']).then(() => location.reload())
                                }, _('Start Podkop')),
                            E('button', {
                                'class': 'btn cbi-button-apply',
                                'click': () => fs.exec('/etc/init.d/podkop', ['restart']).then(() => location.reload())
                            }, _('Restart Podkop')),
                            E('button', {
                                'class': 'btn cbi-button-' + (podkopStatus.enabled ? 'remove' : 'apply'),
                                'click': () => fs.exec('/etc/init.d/podkop', [podkopStatus.enabled ? 'disable' : 'enable']).then(() => location.reload())
                            }, podkopStatus.enabled ? _('Disable Podkop') : _('Enable Podkop')),
                            E('button', {
                                'class': 'btn',
                                'click': () => fs.exec('/etc/init.d/podkop', ['show_config']).then(res => {
                                    const formattedOutput = formatDiagnosticOutput(res.stdout || _('No output'));
                                    ui.showModal(_('Podkop Configuration'), [
                                        E('div', { style: 'max-height: 70vh; overflow-y: auto; margin: 1em 0; padding: 1.5em; background: #f8f9fa; border: 1px solid #e9ecef; border-radius: 4px; font-family: monospace; white-space: pre-wrap; word-wrap: break-word; line-height: 1.5; font-size: 14px;' }, [
                                            E('pre', { style: 'margin: 0;' }, formattedOutput)
                                        ]),
                                        E('div', { style: 'display: flex; justify-content: space-between; margin-top: 1em;' }, [
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
                                                        setTimeout(() => ev.target.textContent = _('Copy to Clipboard'), 1000);
                                                    } catch (err) {
                                                        ui.addNotification(null, E('p', {}, _('Failed to copy: ') + err.message));
                                                    }
                                                    document.body.removeChild(textarea);
                                                }
                                            }, _('Copy to Clipboard')),
                                            E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Close'))
                                        ])
                                    ]);
                                })
                            }, _('Show Config')),
                            E('button', {
                                'class': 'btn',
                                'click': () => fs.exec('/etc/init.d/podkop', ['check_logs']).then(res => {
                                    const formattedOutput = formatDiagnosticOutput(res.stdout || _('No output'));
                                    ui.showModal(_('Podkop Logs'), [
                                        E('div', { style: 'max-height: 70vh; overflow-y: auto; margin: 1em 0; padding: 1.5em; background: #f8f9fa; border: 1px solid #e9ecef; border-radius: 4px; font-family: monospace; white-space: pre-wrap; word-wrap: break-word; line-height: 1.5; font-size: 14px;' }, [
                                            E('pre', { style: 'margin: 0;' }, formattedOutput)
                                        ]),
                                        E('div', { style: 'display: flex; justify-content: space-between; margin-top: 1em;' }, [
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
                                                        setTimeout(() => ev.target.textContent = _('Copy to Clipboard'), 1000);
                                                    } catch (err) {
                                                        ui.addNotification(null, E('p', {}, _('Failed to copy: ') + err.message));
                                                    }
                                                    document.body.removeChild(textarea);
                                                }
                                            }, _('Copy to Clipboard')),
                                            E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Close'))
                                        ])
                                    ]);
                                })
                            }, _('View Logs'))
                        ])
                    ]),
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
                                'click': () => fs.exec('/etc/init.d/podkop', ['show_sing_box_config']).then(res => {
                                    const formattedOutput = formatDiagnosticOutput(res.stdout || _('No output'));
                                    ui.showModal(_('Sing-box Configuration'), [
                                        E('div', { style: 'max-height: 70vh; overflow-y: auto; margin: 1em 0; padding: 1.5em; background: #f8f9fa; border: 1px solid #e9ecef; border-radius: 4px; font-family: monospace; white-space: pre-wrap; word-wrap: break-word; line-height: 1.5; font-size: 14px;' }, [
                                            E('pre', { style: 'margin: 0;' }, formattedOutput)
                                        ]),
                                        E('div', { style: 'display: flex; justify-content: space-between; margin-top: 1em;' }, [
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
                                                        setTimeout(() => ev.target.textContent = _('Copy to Clipboard'), 1000);
                                                    } catch (err) {
                                                        ui.addNotification(null, E('p', {}, _('Failed to copy: ') + err.message));
                                                    }
                                                    document.body.removeChild(textarea);
                                                }
                                            }, _('Copy to Clipboard')),
                                            E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Close'))
                                        ])
                                    ]);
                                })
                            }, _('Show Config')),
                            E('button', {
                                'class': 'btn',
                                'click': () => fs.exec('/etc/init.d/podkop', ['check_sing_box_logs']).then(res => {
                                    const formattedOutput = formatDiagnosticOutput(res.stdout || _('No output'));
                                    ui.showModal(_('Sing-box Logs'), [
                                        E('div', { style: 'max-height: 70vh; overflow-y: auto; margin: 1em 0; padding: 1.5em; background: #f8f9fa; border: 1px solid #e9ecef; border-radius: 4px; font-family: monospace; white-space: pre-wrap; word-wrap: break-word; line-height: 1.5; font-size: 14px;' }, [
                                            E('pre', { style: 'margin: 0;' }, formattedOutput)
                                        ]),
                                        E('div', { style: 'display: flex; justify-content: space-between; margin-top: 1em;' }, [
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
                                                        setTimeout(() => ev.target.textContent = _('Copy to Clipboard'), 1000);
                                                    } catch (err) {
                                                        ui.addNotification(null, E('p', {}, _('Failed to copy: ') + err.message));
                                                    }
                                                    document.body.removeChild(textarea);
                                                }
                                            }, _('Copy to Clipboard')),
                                            E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Close'))
                                        ])
                                    ]);
                                })
                            }, _('View Logs')),
                            E('button', {
                                'class': 'btn',
                                'click': () => fs.exec('/etc/init.d/podkop', ['check_sing_box_connections']).then(res => {
                                    const formattedOutput = formatDiagnosticOutput(res.stdout || _('No output'));
                                    ui.showModal(_('Active Connections'), [
                                        E('div', { style: 'max-height: 70vh; overflow-y: auto; margin: 1em 0; padding: 1.5em; background: #f8f9fa; border: 1px solid #e9ecef; border-radius: 4px; font-family: monospace; white-space: pre-wrap; word-wrap: break-word; line-height: 1.5; font-size: 14px;' }, [
                                            E('pre', { style: 'margin: 0;' }, formattedOutput)
                                        ]),
                                        E('div', { style: 'display: flex; justify-content: space-between; margin-top: 1em;' }, [
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
                                                        setTimeout(() => ev.target.textContent = _('Copy to Clipboard'), 1000);
                                                    } catch (err) {
                                                        ui.addNotification(null, E('p', {}, _('Failed to copy: ') + err.message));
                                                    }
                                                    document.body.removeChild(textarea);
                                                }
                                            }, _('Copy to Clipboard')),
                                            E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Close'))
                                        ])
                                    ]);
                                })
                            }, _('Check Connections'))
                        ])
                    ]),
                    E('div', { 'style': 'flex: 1; padding: 15px; background: #f8f9fa; border-radius: 8px;' }, [
                        E('div', { 'style': 'margin-bottom: 15px;' }, [
                            E('strong', {}, _('FakeIP Status')),
                            E('div', { 'id': 'fakeip-status' }, [E('span', {}, _('Checking FakeIP...'))])
                        ]),
                        E('div', { 'class': 'btn-group', 'style': 'display: flex; flex-direction: column; gap: 8px;' }, [
                            E('button', {
                                'class': 'btn',
                                'click': () => fs.exec('/etc/init.d/podkop', ['check_nft']).then(res => {
                                    const formattedOutput = formatDiagnosticOutput(res.stdout || _('No output'));
                                    ui.showModal(_('NFT Rules'), [
                                        E('div', { style: 'max-height: 70vh; overflow-y: auto; margin: 1em 0; padding: 1.5em; background: #f8f9fa; border: 1px solid #e9ecef; border-radius: 4px; font-family: monospace; white-space: pre-wrap; word-wrap: break-word; line-height: 1.5; font-size: 14px;' }, [
                                            E('pre', { style: 'margin: 0;' }, formattedOutput)
                                        ]),
                                        E('div', { style: 'display: flex; justify-content: space-between; margin-top: 1em;' }, [
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
                                                        setTimeout(() => ev.target.textContent = _('Copy to Clipboard'), 1000);
                                                    } catch (err) {
                                                        ui.addNotification(null, E('p', {}, _('Failed to copy: ') + err.message));
                                                    }
                                                    document.body.removeChild(textarea);
                                                }
                                            }, _('Copy to Clipboard')),
                                            E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Close'))
                                        ])
                                    ]);
                                })
                            }, _('Check NFT Rules')),
                            E('button', {
                                'class': 'btn',
                                'click': () => fs.exec('/etc/init.d/podkop', ['check_dnsmasq']).then(res => {
                                    const formattedOutput = formatDiagnosticOutput(res.stdout || _('No output'));
                                    ui.showModal(_('DNSMasq Configuration'), [
                                        E('div', { style: 'max-height: 70vh; overflow-y: auto; margin: 1em 0; padding: 1.5em; background: #f8f9fa; border: 1px solid #e9ecef; border-radius: 4px; font-family: monospace; white-space: pre-wrap; word-wrap: break-word; line-height: 1.5; font-size: 14px;' }, [
                                            E('pre', { style: 'margin: 0;' }, formattedOutput)
                                        ]),
                                        E('div', { style: 'display: flex; justify-content: space-between; margin-top: 1em;' }, [
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
                                                        setTimeout(() => ev.target.textContent = _('Copy to Clipboard'), 1000);
                                                    } catch (err) {
                                                        ui.addNotification(null, E('p', {}, _('Failed to copy: ') + err.message));
                                                    }
                                                    document.body.removeChild(textarea);
                                                }
                                            }, _('Copy to Clipboard')),
                                            E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Close'))
                                        ])
                                    ]);
                                })
                            }, _('Check DNSMasq')),
                            E('button', {
                                'class': 'btn',
                                'click': () => fs.exec('/etc/init.d/podkop', ['list_update']).then(res => {
                                    const formattedOutput = formatDiagnosticOutput(res.stdout || _('No output'));
                                    ui.showModal(_('Lists Update Results'), [
                                        E('div', { style: 'max-height: 70vh; overflow-y: auto; margin: 1em 0; padding: 1.5em; background: #f8f9fa; border: 1px solid #e9ecef; border-radius: 4px; font-family: monospace; white-space: pre-wrap; word-wrap: break-word; line-height: 1.5; font-size: 14px;' }, [
                                            E('pre', { style: 'margin: 0;' }, formattedOutput)
                                        ]),
                                        E('div', { style: 'display: flex; justify-content: space-between; margin-top: 1em;' }, [
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
                                                        setTimeout(() => ev.target.textContent = _('Copy to Clipboard'), 1000);
                                                    } catch (err) {
                                                        ui.addNotification(null, E('p', {}, _('Failed to copy: ') + err.message));
                                                    }
                                                    document.body.removeChild(textarea);
                                                }
                                            }, _('Copy to Clipboard')),
                                            E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Close'))
                                        ])
                                    ]);
                                })
                            }, _('Update Lists'))
                        ])
                    ]),
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
                    ])
                ])
            ]);
        };

        o = mainSection.taboption('diagnostics', form.DummyValue, '_status');
        o.rawhtml = true;
        o.cfgvalue = () => E('div', { id: 'diagnostics-status' }, _('Loading diagnostics...'));

        function checkFakeIP() {
            return new Promise((resolve) => {
                const controller = new AbortController();
                const timeoutId = setTimeout(() => controller.abort(), 10000);

                fetch('http://httpbin.org/ip', { signal: controller.signal })
                    .then(response => response.text())
                    .then(text => {
                        clearTimeout(timeoutId);
                        let status = {
                            state: 'unknown',
                            message: '',
                            color: '#ff9800'
                        };

                        if (text.includes('Cannot GET /ip')) {
                            status.state = 'working';
                            status.message = _('working');
                            status.color = '#4caf50';
                        } else if (text.includes('"origin":')) {
                            status.state = 'not_working';
                            status.message = _('not working');
                            status.color = '#f44336';
                        } else {
                            status.state = 'error';
                            status.message = _('check error');
                        }
                        resolve(status);
                    })
                    .catch(error => {
                        clearTimeout(timeoutId);
                        resolve({
                            state: 'error',
                            message: error.name === 'AbortError' ? _('timeout') : _('check error'),
                            color: '#ff9800'
                        });
                    });
            });
        }

        async function updateDiagnostics() {
            try {
                const [
                    podkopStatus,
                    singboxStatus,
                    podkop,
                    luci,
                    singbox,
                    system,
                    fakeipStatus
                ] = await Promise.all([
                    fs.exec('/etc/init.d/podkop', ['get_status']),
                    fs.exec('/etc/init.d/podkop', ['get_sing_box_status']),
                    fs.exec('/etc/init.d/podkop', ['show_version']),
                    fs.exec('/etc/init.d/podkop', ['show_luci_version']),
                    fs.exec('/etc/init.d/podkop', ['show_sing_box_version']),
                    fs.exec('/etc/init.d/podkop', ['show_system_info']),
                    checkFakeIP()
                ]);

                const parsedPodkopStatus = JSON.parse(podkopStatus.stdout || '{"running":0,"enabled":0,"status":"unknown"}');
                const parsedSingboxStatus = JSON.parse(singboxStatus.stdout || '{"running":0,"enabled":0,"status":"unknown"}');

                const container = document.getElementById('diagnostics-status');
                if (!container) return;

                const statusSection = createStatusSection(parsedPodkopStatus, parsedSingboxStatus, podkop, luci, singbox, system);
                container.innerHTML = '';
                container.appendChild(statusSection);

                // Update FakeIP status
                const fakeipElement = document.getElementById('fakeip-status');
                if (fakeipElement) {
                    fakeipElement.innerHTML = E('span', { 'style': `color: ${fakeipStatus.color}` }, [
                        fakeipStatus.state === 'working' ? '✔ ' : fakeipStatus.state === 'not_working' ? '✘ ' : '! ',
                        fakeipStatus.message
                    ]).outerHTML;
                }
            } catch (e) {
                console.error('Error updating diagnostics:', e);
                const container = document.getElementById('diagnostics-status');
                if (container) {
                    container.innerHTML = E('div', { 'class': 'alert-message warning' }, [
                        E('strong', {}, _('Error loading diagnostics')),
                        E('br'),
                        E('pre', {}, e.toString())
                    ]).outerHTML;
                }
            }
        }

        // Start periodic updates
        function startPeriodicUpdates() {
            updateDiagnostics();
            const intervalId = setInterval(updateDiagnostics, 10000);
            window.addEventListener('unload', () => clearInterval(intervalId));
        }

        // Extra Section
        const extraSection = m.section(form.TypedSection, 'extra', _('Extra configurations'));
        extraSection.anonymous = false;
        extraSection.addremove = true;
        extraSection.addbtntitle = _('Add Section');
        extraSection.multiple = true;
        createConfigSection(extraSection, m, network);

        const map_promise = m.render();
        map_promise.then(node => {
            node.classList.add('fade-in');
            startPeriodicUpdates();
            return node;
        });

        return map_promise;
    }
});