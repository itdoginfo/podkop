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

        o = s.tab('main', _('Main'));

        o = s.taboption('main', form.ListValue, 'mode', _('Mode'), _('Select VPN or Proxy'));
        o.value('vpn', ('VPN'));
        o.value('proxy', ('Proxy'));

        o = s.taboption('main', form.Value, 'proxy_string', _('Proxy String'), _('String vless:// or ss://'));
        o.depends('mode', 'proxy');

        // Get all interface
        o = s.taboption('main', form.ListValue, 'interface', _('Interface'), _('Specify the interface'));
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
                } else {
                    console.warn('Device name is undefined or empty');
                }
            });
        } catch (error) {
            console.error('Error fetching devices:', error);
        }

        o = s.taboption('main', form.Flag, 'domain_list_enabled', _('Domain list enable'), _('<a href="https://github.com/itdoginfo/allow-domains" target="_blank">github.com/itdoginfo/allow-domains</a>'));
        o.default = '0';
        o.rmempty = false;

        o = s.taboption('main', form.ListValue, 'domain_list', _('Domain list'), _('Select a list'));
        o.placeholder = 'placeholder';
        o.value('ru_inside', 'Russia inside');
        o.value('ru_outside', 'Russia outside');
        o.value('ua', 'Ukraine');
        o.depends('domain_list_enabled', '1');
        o.rmempty = false;

        o = s.taboption('main', form.Flag, 'delist_domains_enabled', _('Delist domains from main list enable'));
        o.default = '0';
        o.rmempty = false;

        o = s.taboption('main', form.DynamicList, 'delist_domains', _('Delist domains'), _('Domains to be excluded'));
        o.placeholder = 'Delist domains';
        o.depends('delist_domains_enabled', '1');
        o.rmempty = false;

        o = s.taboption('main', form.Flag, 'subnets_list_enabled', _('Subnets list enable'));
        o.default = '0';
        o.rmempty = false;

        o = s.taboption('main', form.DynamicList, 'subnets', _('Subnets specify option'));
        o.placeholder = 'Subnet list';
        o.value('twitter', 'Twitter(x.com)');
        o.value('meta', 'Meta');
        o.value('discord', 'Discord(voice)');
        o.depends('subnets_list_enabled', '1');
        o.rmempty = false;

        o = s.taboption('main', form.Flag, 'custom_domains_list_enabled', _('Custom domains enable'));
        o.default = '0';
        o.rmempty = false;

        o = s.taboption('main', form.DynamicList, 'custom_domains', _('Your domains'));
        o.placeholder = 'Domains list';
        o.depends('custom_domains_list_enabled', '1');
        o.rmempty = false;

        o = s.taboption('main', form.Flag, 'custom_download_domains_list_enabled', _('URL domains enable'));
        o.default = '0';
        o.rmempty = false;

        o = s.taboption('main', form.DynamicList, 'custom_download_domains', _('Your URL domains'));
        o.placeholder = 'URL';
        o.depends('custom_download_domains_list_enabled', '1');
        o.rmempty = false;

        o = s.taboption('main', form.Flag, 'custom_subnets_list_enabled', _('Custom subnets enable'));
        o.default = '0';
        o.rmempty = false;

        o = s.taboption('main', form.DynamicList, 'custom_subnets', _('Your subnet'));
        o.placeholder = 'Subnets list';
        o.depends('custom_subnets_list_enabled', '1');
        o.rmempty = false;

        o = s.taboption('main', form.Flag, 'custom_download_subnets_list_enabled', _('URL subnets enable'));
        o.default = '0';
        o.rmempty = false;

        o = s.taboption('main', form.DynamicList, 'custom_download_subnets', _('Your URL subnet'));
        o.placeholder = 'URL';
        o.depends('custom_download_subnets_list_enabled', '1');
        o.rmempty = false;

        o = s.taboption('main', form.Flag, 'all_traffic_from_ip_enabled', _('IP for full redirection'));
        o.default = '0';
        o.rmempty = false;

        o = s.taboption('main', form.DynamicList, 'all_traffic_ip', _('Local IPs'));
        o.placeholder = 'IP';
        o.depends('all_traffic_from_ip_enabled', '1');
        o.rmempty = false;

        o = s.taboption('main', form.Flag, 'exclude_from_ip_enabled', _('IP for full exclude'));
        o.default = '0';
        o.rmempty = false;

        o = s.taboption('main', form.DynamicList, 'exclude_traffic_ip', _('Local IPs'));
        o.placeholder = 'IP';
        o.depends('exclude_from_ip_enabled', '1');
        o.rmempty = false;

        o = s.taboption('main', form.Flag, 'yacd', _('Yacd enable'), _('http://openwrt.lan:9090/ui'));
        o.default = '0';
        o.depends('mode', 'proxy');
        o.rmempty = false;

        o = s.taboption('main', form.Flag, 'socks5', _('Mixed enable'), _('Browser port: 2080'));
        o.default = '0';
        o.depends('mode', 'proxy');
        o.rmempty = false;
    
        o = s.taboption('main', form.Flag, 'exclude_ntp', _('Exclude NTP'), _('For issues with open connections sing-box'));
        o.default = '0';
        o.depends('mode', 'proxy');
        o.rmempty = false;  

        // Second section
        s = m.section(form.TypedSection, 'second');
        s.anonymous = true;

        o = s.tab('second', _('Second'));

        o = s.taboption('second', form.Flag, 'second_enable', _('Second enable'));
        o.default = '0';
        o.rmempty = false;

        o = s.taboption('second', form.ListValue, 'mode', _('Mode'), _('Select VPN or Proxy'));
        o.value('vpn', ('VPN'));
        o.value('proxy', ('Proxy'));
        o.depends('second_enable', '1');

        o = s.taboption('second', form.Value, 'proxy_string', _('Proxy String'), _('String vless:// or ss://'));
        o.depends('mode', 'proxy');

        // Get all interface
        o = s.taboption('second', form.ListValue, 'interface', _('Interface'), _('Specify the interface'));
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
                } else {
                    console.warn('Device name is undefined or empty');
                }
            });
        } catch (error) {
            console.error('Error fetching devices:', error);
        }

        o = s.taboption('second', form.Flag, 'domain_service_enabled', _('Domain service enable'));
        o.default = '0';
        o.rmempty = false;
        o.depends('second_enable', '1');

        o = s.taboption('second', form.ListValue, 'service_list', _('Service list'), _('Select a list'));
        o.placeholder = 'placeholder';
        o.value('youtube', 'Youtube');
        o.depends('domain_service_enabled', '1');
        o.rmempty = false;

        o = s.taboption('second', form.Flag, 'custom_domains_list_enabled', _('Custom domains enable'));
        o.default = '0';
        o.rmempty = false;
        o.depends('second_enable', '1');

        o = s.taboption('second', form.DynamicList, 'custom_domains', _('Your domains'));
        o.placeholder = 'Domains list';
        o.depends('custom_domains_list_enabled', '1');
        o.rmempty = false;

        o = s.taboption('second', form.Flag, 'custom_subnets_list_enabled', _('Custom subnets enable'));
        o.default = '0';
        o.rmempty = false;
        o.depends('second_enable', '1');

        o = s.taboption('second', form.DynamicList, 'custom_subnets', _('Your subnet'));
        o.placeholder = 'Subnets list';
        o.depends('custom_subnets_list_enabled', '1');
        o.rmempty = false;

        return m.render();
    }
});