'use strict';
'require view';
'require form';
'require ui';
'require network';

return view.extend({
    async render() {
        var m, s, o;

        m = new form.Map('podkop', _('Podkop configuration'));

        s = m.section(form.TypedSection, 'podkop');
        s.anonymous = true;

        o = s.option(form.ListValue, 'mode', _('Mode'), _('Select VPN or Proxy'))
        o.value('vpn', ('VPN'))
        o.value('proxy', ('Proxy'))

        o = s.option(form.Value, 'proxy_string', _('Proxy String'), _('String vless:// or ss://'));
        o.depends('mode', 'proxy');

        // Get all interface
        o = s.option(form.ListValue, 'interface', _('Interface'), _('Specify the interface'));
        o.depends('mode', 'vpn');

        try {
            const devices = await network.getDevices();

            const excludeInterfaces = ['br-lan', 'eth0', 'eth1'];

            devices.forEach(function (device) {
                if (device.dev && device.dev.name) {
                    if (!excludeInterfaces.includes(device.dev.name)) {
                        o.value(device.dev.name, device.dev.name);
                    }
                } else {
                    console.warn('Device name is undefined or empty');
                }
            });
        } catch (error) {
            console.error('Error fetching devices:', error);
        }

        o = s.option(form.Flag, 'domain_list_enabled', _('Domain list enable'), _('<a href="https://github.com/itdoginfo/allow-domains" target="_blank">github.com/itdoginfo/allow-domains</a>'));
        o.default = '0';
        o.rmempty = false;

        o = s.option(form.ListValue, 'domain_list', _('Domain list'), _('Select a list'));
        o.placeholder = 'placeholder';
        o.value('ru_inside', 'Russia inside');
        o.value('ru_outside', 'Russia outside');
        o.value('ua', 'Ukraine');
        o.depends('domain_list_enabled', '1');
        o.rmempty = false;

        o = s.option(form.Flag, 'delist_domains_enabled', _('Delist domains from main list enable'));
        o.default = '0';
        o.rmempty = false;

        o = s.option(form.DynamicList, 'delist_domains', _('Delist domains'), _('Domains to be excluded'));
        o.placeholder = 'Delist domains';
        o.depends('delist_domains_enabled', '1');
        o.rmempty = false;

        o = s.option(form.Flag, 'subnets_list_enabled', _('Subnets list enable'));
        o.default = '0';
        o.rmempty = false;

        o = s.option(form.DynamicList, 'subnets', _('Subnets specify option'));
        o.placeholder = 'Subnet list';
        o.value('twitter', 'Twitter(x.com)');
        o.value('meta', 'Meta');
        o.value('discord', 'Discord(voice)');
        o.depends('subnets_list_enabled', '1');
        o.rmempty = false;

        o = s.option(form.Flag, 'custom_domains_list_enabled', _('Custom domains enable'));
        o.default = '0';
        o.rmempty = false;

        o = s.option(form.DynamicList, 'custom_domains', _('Your domains'));
        o.placeholder = 'Domains list';
        o.depends('custom_domains_list_enabled', '1');
        o.rmempty = false;

        o = s.option(form.Flag, 'custom_subnets_list_enabled', _('Custom subnets enable'));
        o.default = '0';
        o.rmempty = false;

        o = s.option(form.DynamicList, 'custom_subnets', _('Your subnet'));
        o.placeholder = 'Subnets list';
        o.depends('custom_subnets_list_enabled', '1');
        o.rmempty = false;

        return m.render();
    }
});