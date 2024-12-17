'use strict';
'require view';
'require form';
'require ui';
'require network';
'require fs';

return view.extend({
    async render() {
        let m, s, o;

        m = new form.Map('podkop', _('Podkop'), null, ['main', 'second']);

        L.uci.load('podkop').then(() => {
            const version = L.uci.get('podkop', 'main', 'version') || '';
            if (version) {
                m.title = _('Podkop') + ' v' + version;
                if (!window.location.search.includes('v=')) {
                    const newUrl = window.location.pathname + '?v=' + version;
                    window.history.replaceState(null, '', newUrl);
                }
            }
        });

        s = m.section(form.TypedSection, 'main');
        s.anonymous = true;

        // Basic Settings Tab
        o = s.tab('basic', _('Basic Settings'));

        o = s.taboption('basic', form.ListValue, 'mode', _('Connection Type'), _('Select between VPN and Proxy connection methods for traffic routing'));
        o.value('vpn', ('VPN'));
        o.value('proxy', ('Proxy'));
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

        o = s.taboption('basic', form.Flag, 'domain_list_enabled', _('Community Domain Lists'));
        o.default = '0';
        o.rmempty = false;
        o.ucisection = 'main';

        o = s.taboption('basic', form.ListValue, 'domain_list', _('Domain List'), _('Select a list') + ' <a href="https://github.com/itdoginfo/allow-domains" target="_blank">github.com/itdoginfo/allow-domains</a>');
        o.placeholder = 'placeholder';
        o.value('ru_inside', 'Russia inside');
        o.value('ru_outside', 'Russia outside');
        o.value('ua', 'Ukraine');
        o.depends('domain_list_enabled', '1');
        o.rmempty = false;
        o.ucisection = 'main';

        o = s.taboption('basic', form.Flag, 'delist_domains_enabled', _('Domain Exclusions'), _('Exclude specific domains from routing rules'));
        o.default = '0';
        o.rmempty = false;
        o.ucisection = 'main';
        o.depends('domain_list_enabled', '1');

        o = s.taboption('basic', form.DynamicList, 'delist_domains', _('Excluded Domains'), _('Domains to be excluded from routing'));
        o.placeholder = 'Delist domains';
        o.depends('delist_domains_enabled', '1');
        o.rmempty = false;
        o.ucisection = 'main';

        o = s.taboption('basic', form.Flag, 'subnets_list_enabled', _('Community Subnet Lists'), _('Enable routing for popular services like Twitter, Meta, and Discord'));
        o.default = '0';
        o.rmempty = false;
        o.ucisection = 'main';

        o = s.taboption('basic', form.DynamicList, 'subnets', _('Service Networks'), _('Select predefined service networks for routing'));
        o.placeholder = 'Service network list';
        o.value('twitter', 'Twitter(x.com)');
        o.value('meta', 'Meta');
        o.value('discord', 'Discord(voice)');
        o.depends('subnets_list_enabled', '1');
        o.rmempty = false;
        o.ucisection = 'main';

        o = s.taboption('basic', form.ListValue, 'custom_domains_list_enabled', _('User Domain List Type'), _('Select how to add your custom domains'));
        o.value('disabled', _('Disabled'));
        o.value('dynamic', _('Dynamic List'));
        o.value('text', _('Text List'));
        o.default = 'disabled';
        o.rmempty = false;
        o.ucisection = 'main';

        o = s.taboption('basic', form.DynamicList, 'custom_domains', _('User Domains'), _('Enter domain names without protocols (example: sub.example.com or example.com)'));
        o.placeholder = 'Domains list';
        o.depends('custom_domains_list_enabled', 'dynamic');
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
        o.depends('custom_domains_list_enabled', 'text');
        o.rows = 10;
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

            // Разбираем IP и маску
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

        // Additional Settings Tab

        o = s.tab('additional', _('Additional Settings'));

        o = s.taboption('additional', form.Flag, 'yacd', _('Yacd enable'), _('http://openwrt.lan:9090/ui'));
        o.default = '0';
        o.depends('mode', 'proxy');
        o.rmempty = false;
        o.ucisection = 'main';

        o = s.taboption('additional', form.Flag, 'socks5', _('Mixed enable'), _('Browser port: 2080'));
        o.default = '0';
        o.depends('mode', 'proxy');
        o.rmempty = false;
        o.ucisection = 'main';

        o = s.taboption('additional', form.Flag, 'exclude_ntp', _('Exclude NTP'), _('For issues with open connections sing-box'));
        o.default = '0';
        o.depends('mode', 'proxy');
        o.rmempty = false;
        o.ucisection = 'main';

        o = s.taboption('additional', form.ListValue, 'update_interval', _('List Update Frequency'), _('Select how often the lists will be updated'));
        o.value('0 */1 * * *', _('Every hour'));
        o.value('0 */2 * * *', _('Every 2 hours'));
        o.value('0 */4 * * *', _('Every 4 hours'));
        o.value('0 */6 * * *', _('Every 6 hours'));
        o.value('0 */12 * * *', _('Every 12 hours'));
        o.value('0 4 * * *', _('Once a day at 04:00'));
        o.value('0 4 * * 0', _('Once a week on Sunday at 04:00'));
        o.default = '0 4 * * *';
        o.rmempty = false;
        o.ucisection = 'main';

        // Secondary Settings Tab

        o = s.tab('secondary_config', _('Secondary Config'));

        o = s.taboption('secondary_config', form.Flag, 'second_enable', _('Secondary VPN/Proxy Enable'), _('Enable secondary VPN/Proxy configuration'));
        o.default = '0';
        o.rmempty = false;
        o.ucisection = 'second';

        o = s.taboption('secondary_config', form.ListValue, 'second_mode', _('Connection Type'), _('Select between VPN and Proxy connection methods for traffic routing'));
        o.value('vpn', ('VPN'));
        o.value('proxy', ('Proxy'));
        o.depends('second_enable', '1');
        o.ucisection = 'second';

        o = s.taboption('secondary_config', form.ListValue, 'second_proxy_config_type', _('Configuration Type'), _('Select how to configure the proxy'));
        o.value('url', _('Connection URL'));
        o.value('outbound', _('Outbound Config'));
        o.default = 'url';
        o.depends('second_mode', 'proxy');
        o.ucisection = 'second';

        o = s.taboption('secondary_config', form.TextValue, 'second_proxy_string', _('Proxy Configuration URL'), _('Enter connection string starting with vless:// or ss:// for proxy configuration'));
        o.depends('second_proxy_config_type', 'url');
        o.rows = 5;
        o.ucisection = 'second';

        o = s.taboption('secondary_config', form.TextValue, 'second_outbound_json', _('Outbound Configuration'), _('Enter complete outbound configuration in JSON format'));
        o.depends('second_proxy_config_type', 'outbound');
        o.rows = 10;
        o.ucisection = 'second';
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

        o = s.taboption('secondary_config', form.ListValue, 'second_interface', _('Network Interface'), _('Select network interface for VPN connection'));
        o.depends('second_mode', 'vpn');
        o.ucisection = 'second';

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

        o = s.taboption('secondary_config', form.Flag, 'second_domain_service_enabled', _('Service Domain List Enable'), _('Enable predefined service domain lists for routing'));
        o.default = '0';
        o.rmempty = false;
        o.depends('second_enable', '1');
        o.ucisection = 'second';

        o = s.taboption('secondary_config', form.ListValue, 'second_service_list', _('Service List'), _('Select predefined services for routing'));
        o.placeholder = 'placeholder';
        o.value('youtube', 'Youtube');
        o.depends('second_domain_service_enabled', '1');
        o.rmempty = false;
        o.ucisection = 'second';

        o = s.taboption('secondary_config', form.ListValue, 'second_custom_domains_list_enabled', _('User Domain List Type'), _('Select how to add your custom domains'));
        o.value('disabled', _('Disabled'));
        o.value('dynamic', _('Dynamic List'));
        o.value('text', _('Text List'));
        o.default = 'disabled';
        o.rmempty = false;
        o.depends('second_enable', '1');
        o.ucisection = 'second';

        o = s.taboption('secondary_config', form.DynamicList, 'second_custom_domains', _('User Domains'), _('Enter domain names without protocols (example: sub.example.com or example.com)'));
        o.placeholder = 'Domains list';
        o.depends('second_custom_domains_list_enabled', 'dynamic');
        o.rmempty = false;
        o.ucisection = 'second';
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

        o = s.taboption('secondary_config', form.TextValue, 'second_custom_domains_text', _('User Domains List'), _('Enter domain names separated by comma, space or newline (example: sub.example.com, example.com or one domain per line)'));
        o.placeholder = 'example.com, sub.example.com\ndomain.com test.com\nsubdomain.domain.com another.com, third.com';
        o.depends('second_custom_domains_list_enabled', 'text');
        o.rows = 10;
        o.rmempty = false;
        o.ucisection = 'second';
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

        o = s.taboption('secondary_config', form.ListValue, 'second_custom_subnets_list_enabled', _('User Subnet List Type'), _('Select how to add your custom subnets'));
        o.value('disabled', _('Disabled'));
        o.value('dynamic', _('Dynamic List'));
        o.value('text', _('Text List'));
        o.default = 'disabled';
        o.rmempty = false;
        o.depends('second_enable', '1');
        o.ucisection = 'second';

        o = s.taboption('secondary_config', form.DynamicList, 'second_custom_subnets', _('User Subnets'), _('Enter subnets in CIDR notation (example: 103.21.244.0/22) or single IP addresses'));
        o.placeholder = 'IP or subnet';
        o.depends('second_custom_subnets_list_enabled', 'dynamic');
        o.rmempty = false;
        o.ucisection = 'second';
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

        o = s.taboption('secondary_config', form.TextValue, 'second_custom_subnets_text', _('User Subnets List'), _('Enter subnets in CIDR notation or single IP addresses, separated by comma, space or newline'));
        o.placeholder = '103.21.244.0/22\n8.8.8.8\n1.1.1.1/32, 9.9.9.9 10.10.10.10';
        o.depends('second_custom_subnets_list_enabled', 'text');
        o.rows = 10;
        o.rmempty = false;
        o.ucisection = 'second';
        o.validate = function (section_id, value) {
            if (!value || value.length === 0) {
                return true;
            }

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

        o = s.tab('diagnostics', _('Diagnostics'));

        function formatDiagnosticOutput(output) {
            if (!output) return '';

            return output
                .replace(/\x1B\[[0-9;]*[mK]/g, '')
                .replace(/\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\] /g, '')
                .replace(/\n{3,}/g, '\n\n')
                .replace(/===\s+(.*?)\s+===/g, (_, title) => `\n${title}\n${'─'.repeat(title.length)}`)
                .replace(/^Checking\s+(.+)\.{3}/gm, '► Checking $1...')
                .replace(/:\s+(available|not found)$/gm, (_, status) =>
                    `: ${status === 'available' ? '✓' : '✗'}`);
        }

        // Check All - полная диагностика
        o = s.taboption('diagnostics', form.Button, '_check_all');
        o.title = _('Main Check');
        o.description = _('Run a comprehensive diagnostic check of all components');
        o.inputtitle = _('Run Check');
        o.inputstyle = 'apply';
        o.onclick = function () {
            return fs.exec('/etc/init.d/podkop', ['check_three'])
                .then(function (res) {
                    const formattedOutput = formatDiagnosticOutput(res.stdout || _('No output'));

                    const modalElement = ui.showModal(_('Full Diagnostic Results'), [
                        E('div', { style: 'max-height: 70vh; overflow-y: auto;' }, [
                            E('pre', { class: 'cbi-value-field' }, formattedOutput)
                        ]),
                        E('div', { style: 'display: flex; justify-content: space-between; margin-top: 1em;' }, [
                            E('button', {
                                'class': 'btn cbi-button-save',
                                'click': function () {
                                    const textarea = document.createElement('textarea');
                                    textarea.value = '```txt\n' + formattedOutput + '\n```';
                                    document.body.appendChild(textarea);
                                    textarea.select();
                                    try {
                                        document.execCommand('copy');
                                        ui.hideModal();
                                    } catch (err) {
                                        ui.addNotification(null, E('p', {}, _('Failed to copy: ') + err.message));
                                    }
                                    document.body.removeChild(textarea);
                                }
                            }, _('Copy to Clipboard')),
                            E('button', {
                                'class': 'btn cbi-button-neutral',
                                'click': ui.hideModal
                            }, _('Close'))
                        ])
                    ], 'large');

                    if (modalElement && modalElement.parentElement) {
                        modalElement.parentElement.classList.add('modal-overlay-large');
                    }
                });
        };

        o = s.taboption('diagnostics', form.Button, '_check_logs');
        o.title = _('System Logs');
        o.description = _('View recent system logs related to Podkop');
        o.inputtitle = _('View Logs');
        o.inputstyle = 'apply';
        o.onclick = function () {
            return fs.exec('/etc/init.d/podkop', ['check_logs'])
                .then(function (res) {
                    const formattedOutput = formatDiagnosticOutput(res.stdout || _('No output'));

                    const modalElement = ui.showModal(_('System Logs'), [
                        E('div', { style: 'max-height: 70vh; overflow-y: auto;' }, [
                            E('pre', { class: 'cbi-value-field' }, formattedOutput)
                        ]),
                        E('div', { style: 'display: flex; justify-content: space-between; margin-top: 1em;' }, [
                            E('button', {
                                'class': 'btn cbi-button-save',
                                'click': function () {
                                    const textarea = document.createElement('textarea');
                                    textarea.value = '```txt\n' + formattedOutput + '\n```';
                                    document.body.appendChild(textarea);
                                    textarea.select();
                                    try {
                                        document.execCommand('copy');
                                        ui.hideModal();
                                    } catch (err) {
                                        ui.addNotification(null, E('p', {}, _('Failed to copy: ') + err.message));
                                    }
                                    document.body.removeChild(textarea);
                                }
                            }, _('Copy to Clipboard')),
                            E('button', {
                                'class': 'btn cbi-button-neutral',
                                'click': ui.hideModal
                            }, _('Close'))
                        ])
                    ], 'large');

                    if (modalElement && modalElement.parentElement) {
                        modalElement.parentElement.classList.add('modal-overlay-large');
                    }
                });
        };

        o = s.taboption('diagnostics', form.Button, '_list_update');
        o.title = _('Update lists');
        o.description = _('Update all lists in config');
        o.inputtitle = _('Update lists');
        o.inputstyle = 'apply';
        o.onclick = function () {
            fs.exec('/etc/init.d/podkop', ['list_update']);

            ui.showModal(_('List Update'), [
                E('p', {}, _('Lists will be updated in background. You can check the progress in system logs.')),
                E('div', { class: 'right' }, [
                    E('button', {
                        'class': 'btn',
                        'click': ui.hideModal
                    }, _('Close'))
                ])
            ]);
        };

        o = s.taboption('diagnostics', form.Button, '_show_config');
        o.title = _('Show Config');
        o.description = _('Show current podkop configuration with masked sensitive data');
        o.inputtitle = _('Show Config');
        o.inputstyle = 'apply';
        o.onclick = function () {
            return fs.exec('/etc/init.d/podkop', ['show_config'])
                .then(function (res) {
                    const formattedOutput = formatDiagnosticOutput(res.stdout || _('No output'));

                    const modalElement = ui.showModal(_('Podkop Configuration'), [
                        E('div', { class: 'cbi-section' }, [
                            E('pre', { class: 'cbi-value-field' }, formattedOutput)
                        ]),
                        E('div', { style: 'display: flex; justify-content: space-between; margin-top: 1em;' }, [
                            E('button', {
                                'class': 'btn cbi-button-save',
                                'click': function () {
                                    const textarea = document.createElement('textarea');
                                    textarea.value = '```\n' + formattedOutput + '\n```';
                                    document.body.appendChild(textarea);
                                    textarea.select();
                                    try {
                                        document.execCommand('copy');
                                        ui.hideModal();
                                    } catch (err) {
                                        ui.addNotification(null, E('p', {}, _('Failed to copy: ') + err.message));
                                    }
                                    document.body.removeChild(textarea);
                                }
                            }, _('Copy to Clipboard')),
                            E('button', {
                                'class': 'btn cbi-button-neutral',
                                'click': ui.hideModal
                            }, _('Close'))
                        ])
                    ], 'large');

                    if (modalElement && modalElement.parentElement) {
                        modalElement.parentElement.classList.add('modal-overlay-large');
                    }
                });
        };

        return m.render();
    }
});