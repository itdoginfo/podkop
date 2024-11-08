'use strict';
'require view';
'require form';
'require ui';
'require network';

return view.extend({
    async render() {
        var m, s, o;

        m = new form.Map('podkop', _('Podkop configuration'));

        s = m.section(form.TypedSection, 'main');
        s.anonymous = true;

        o = s.tab('basic', _('Basic Settings'));

        o = s.taboption('basic', form.ListValue, 'mode', _('Connection Type'), _('Select between VPN and Proxy connection methods for traffic routing'));
        o.value('vpn', ('VPN'));
        o.value('proxy', ('Proxy'));

        o = s.taboption('basic', form.TextValue, 'proxy_string', _('Proxy Configuration URL'), _('Enter connection string starting with vless:// or ss:// for proxy configuration'));
        o.depends('mode', 'proxy');
        o.rows = 5;

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

        o = s.taboption('basic', form.Flag, 'domain_list_enabled', _('Predefined Domain Lists'), _('Enable routing based on predefined domain lists for specific regions'));
        o.default = '0';
        o.rmempty = false;

        o = s.taboption('basic', form.ListValue, 'domain_list', _('Domain List'), _('Select a predefined domain list'));
        o.placeholder = 'placeholder';
        o.value('ru_inside', 'Russia inside');
        o.value('ru_outside', 'Russia outside');
        o.value('ua', 'Ukraine');
        o.depends('domain_list_enabled', '1');
        o.rmempty = false;

        o = s.taboption('basic', form.Flag, 'subnets_list_enabled', _('Predefined Service Networks'), _('Enable routing for popular services like Twitter, Meta, and Discord'));
        o.default = '0';
        o.rmempty = false;

        o = s.taboption('basic', form.DynamicList, 'subnets', _('Service Networks'), _('Select predefined service networks for routing'));
        o.placeholder = 'Service network list';
        o.value('twitter', 'Twitter(x.com)');
        o.value('meta', 'Meta');
        o.value('discord', 'Discord(voice)');
        o.depends('subnets_list_enabled', '1');
        o.rmempty = false;

        o = s.tab('custom', _('User Settings'));

        o = s.taboption('custom', form.Flag, 'custom_domains_list_enabled', _('User Domain List'), _('Enable and manage your custom list of domains for selective routing'));
        o.default = '0';
        o.rmempty = false;

        o = s.taboption('custom', form.DynamicList, 'custom_domains', _('User Domains'), _('Enter domain names without protocols (example: sub.example.com or example.com)'));
        o.placeholder = 'Domains list';
        o.depends('custom_domains_list_enabled', '1');
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

        o = s.taboption('custom', form.Flag, 'custom_download_domains_list_enabled', _('Remote Domain Lists'), _('Download and use domain lists from remote URLs'));
        o.default = '0';
        o.rmempty = false;

        o = s.taboption('custom', form.DynamicList, 'custom_download_domains', _('Remote Domain URLs'), _('Enter full URLs starting with http:// or https://'));
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

        o = s.taboption('custom', form.Flag, 'custom_subnets_list_enabled', _('User Subnet List'), _('Enable and manage your custom list of IP subnets for selective routing'));
        o.default = '0';
        o.rmempty = false;

        o = s.taboption('custom', form.DynamicList, 'custom_subnets', _('User Subnets'), _('Enter subnet in CIDR notation (example: 192.168.1.0/24)'));
        o.placeholder = 'Subnets list';
        o.depends('custom_subnets_list_enabled', '1');
        o.rmempty = false;
        o.validate = function (section_id, value) {
            if (!value || value.length === 0) {
                return true;
            }

            const subnetRegex = /^(\d{1,3}\.){3}\d{1,3}\/\d{1,2}$/;

            if (!subnetRegex.test(value)) {
                return _('Invalid subnet format. Use format: X.X.X.X/Y (like 192.168.1.0/24)');
            }

            const [ip, cidr] = value.split('/');
            const ipParts = ip.split('.');
            const cidrNum = parseInt(cidr);

            for (const part of ipParts) {
                const num = parseInt(part);
                if (num < 0 || num > 255) {
                    return _('IP address parts must be between 0 and 255');
                }
            }

            if (cidrNum < 0 || cidrNum > 32) {
                return _('CIDR must be between 0 and 32');
            }

            return true;
        };

        o = s.taboption('custom', form.Flag, 'custom_download_subnets_list_enabled', _('Remote Subnet Lists'), _('Download and use subnet lists from remote URLs'));
        o.default = '0';
        o.rmempty = false;

        o = s.taboption('custom', form.DynamicList, 'custom_download_subnets', _('Remote Subnet URLs'), _('Enter full URLs starting with http:// or https://'));
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

        o = s.tab('additional', _('Additional Settings'));

        o = s.taboption('additional', form.Flag, 'delist_domains_enabled', _('Domain Exclusions'), _('Exclude specific domains from routing rules'));
        o.default = '0';
        o.rmempty = false;

        o = s.taboption('additional', form.DynamicList, 'delist_domains', _('Excluded Domains'), _('Domains to be excluded from routing'));
        o.placeholder = 'Delist domains';
        o.depends('delist_domains_enabled', '1');
        o.rmempty = false;

        o = s.taboption('additional', form.Flag, 'all_traffic_from_ip_enabled', _('Force Proxy IPs'), _('Specify local IP addresses whose traffic will always use the configured route'));
        o.default = '0';
        o.rmempty = false;

        o = s.taboption('additional', form.DynamicList, 'all_traffic_ip', _('Local IPs'), _('Enter valid IPv4 addresses'));
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

        o = s.taboption('additional', form.Flag, 'exclude_from_ip_enabled', _('Bypass Proxy IPs'), _('Specify local IP addresses that will never use the configured route'));
        o.default = '0';
        o.rmempty = false;

        o = s.taboption('additional', form.DynamicList, 'exclude_traffic_ip', _('Local IPs'), _('Enter valid IPv4 addresses'));
        o.placeholder = 'IP';
        o.depends('exclude_from_ip_enabled', '1');
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

        o = s.taboption('additional', form.Flag, 'yacd', _('Yacd enable'), _('http://openwrt.lan:9090/ui'));
        o.default = '0';
        o.depends('mode', 'proxy');
        o.rmempty = false;

        o = s.taboption('additional', form.Flag, 'socks5', _('Mixed enable'), _('Browser port: 2080'));
        o.default = '0';
        o.depends('mode', 'proxy');
        o.rmempty = false;

        o = s.taboption('additional', form.Flag, 'exclude_ntp', _('Exclude NTP'), _('For issues with open connections sing-box'));
        o.default = '0';
        o.depends('mode', 'proxy');
        o.rmempty = false;

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

        o = s.tab('second_settings', _('Alternative Route'));

        o = s.taboption('second_settings', form.Flag, 'second_enable', _('Alternative Route Enable'), _('Enable secondary routing configuration'));
        o.default = '0';
        o.rmempty = false;

        o = s.taboption('second_settings', form.ListValue, 'second_mode', _('Connection Type'), _('Select between VPN and Proxy for alternative route'));
        o.value('vpn', ('VPN'));
        o.value('proxy', ('Proxy'));
        o.depends('second_enable', '1');

        o = s.taboption('second_settings', form.Value, 'second_proxy_string', _('Proxy Configuration URL'), _('Enter connection string starting with vless:// or ss:// for proxy configuration'));
        o.depends('second_mode', 'proxy');

        o = s.taboption('second_settings', form.ListValue, 'second_interface', _('Network Interface'), _('Select network interface for VPN connection'));
        o.depends('second_mode', 'vpn');

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

        o = s.taboption('second_settings', form.Flag, 'domain_service_enabled', _('Service List Enable'), _('Enable predefined service lists for alternative routing'));
        o.default = '0';
        o.rmempty = false;
        o.depends('second_enable', '1');

        o = s.taboption('second_settings', form.ListValue, 'service_list', _('Service List'), _('Select predefined services for alternative routing'));
        o.placeholder = 'placeholder';
        o.value('youtube', 'Youtube');
        o.depends('domain_service_enabled', '1');
        o.rmempty = false;

        o = s.taboption('second_settings', form.Flag, 'second_custom_domains_list_enabled', _('Alternative Domain List'), _('Configure custom domains for alternative routing path'));
        o.default = '0';
        o.rmempty = false;
        o.depends('second_enable', '1');

        o = s.taboption('second_settings', form.DynamicList, 'second_custom_domains', _('Alternative Domains'), _('Enter domain names without protocols (example: sub.example.com or example.com)'));
        o.placeholder = 'Domains list';
        o.depends('second_custom_domains_list_enabled', '1');
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

        o = s.taboption('second_settings', form.Flag, 'second_custom_subnets_list_enabled', _('Alternative Subnet List'), _('Configure custom subnets for alternative routing path'));
        o.default = '0';
        o.rmempty = false;
        o.depends('second_enable', '1');

        o = s.taboption('second_settings', form.DynamicList, 'second_custom_subnets', _('Alternative Subnets'), _('Enter subnet in CIDR notation (example: 192.168.1.0/24)'));
        o.placeholder = 'Subnets list';
        o.depends('second_custom_subnets_list_enabled', '1');
        o.rmempty = false;
        o.validate = function (section_id, value) {
            if (!value || value.length === 0) {
                return true;
            }

            const subnetRegex = /^(\d{1,3}\.){3}\d{1,3}\/\d{1,2}$/;

            if (!subnetRegex.test(value)) {
                return _('Invalid subnet format. Use format: X.X.X.X/Y (like 192.168.1.0/24)');
            }

            const [ip, cidr] = value.split('/');
            const ipParts = ip.split('.');
            const cidrNum = parseInt(cidr);

            for (const part of ipParts) {
                const num = parseInt(part);
                if (num < 0 || num > 255) {
                    return _('IP address parts must be between 0 and 255');
                }
            }

            if (cidrNum < 0 || cidrNum > 32) {
                return _('CIDR must be between 0 and 32');
            }

            return true;
        };

        return m.render();
    }
});
