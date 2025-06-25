'use strict';
'require form';
'require baseclass';
'require view.podkop.constants as constants';
'require tools.widgets as widgets';

function createAdditionalSection(mainSection, network) {
    let o = mainSection.tab('additional', _('Additional Settings'));

    o = mainSection.taboption('additional', form.Flag, 'yacd', _('Yacd enable'), _('<a href="http://openwrt.lan:9090/ui" target="_blank">openwrt.lan:9090/ui</a>'));
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
    Object.entries(constants.UPDATE_INTERVAL_OPTIONS).forEach(([key, label]) => {
        o.value(key, _(label));
    });
    o.default = '1d';
    o.rmempty = false;
    o.ucisection = 'main';

    o = mainSection.taboption('additional', form.ListValue, 'dns_type', _('DNS Protocol Type'), _('Select DNS protocol to use'));
    o.value('doh', _('DNS over HTTPS (DoH)'));
    o.value('dot', _('DNS over TLS (DoT)'));
    o.value('udp', _('UDP (Unprotected DNS)'));
    o.default = 'udp';
    o.rmempty = false;
    o.ucisection = 'main';

    o = mainSection.taboption('additional', form.Value, 'dns_server', _('DNS Server'), _('Select or enter DNS server address'));
    Object.entries(constants.DNS_SERVER_OPTIONS).forEach(([key, label]) => {
        o.value(key, _(label));
    });
    o.default = '8.8.8.8';
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

        const domainRegex = /^([a-zA-Z0-9-]+\.)*[a-zA-Z0-9-]+\.[a-zA-Z]{2,}(\/[^\s]*)?$/;
        if (!domainRegex.test(value)) {
            return _('Invalid DNS server format. Examples: 8.8.8.8 or dns.example.com or dns.example.com/nicedns for DoH');
        }

        return true;
    };

    o = mainSection.taboption('additional', form.Flag, 'split_dns_enabled', _('Split DNS'), _('DNS for the list via proxy'));
    o.default = '1';
    o.rmempty = false;
    o.ucisection = 'main';

    o = mainSection.taboption('additional', form.ListValue, 'split_dns_type', _('Split DNS Protocol Type'), _('Select DNS protocol for split'));
    o.value('doh', _('DNS over HTTPS (DoH)'));
    o.value('dot', _('DNS over TLS (DoT)'));
    o.value('udp', _('UDP (Unprotected DNS)'));
    o.default = 'udp';
    o.rmempty = false;
    o.depends('split_dns_enabled', '1');
    o.ucisection = 'main';

    o = mainSection.taboption('additional', form.Value, 'split_dns_server', _('Split DNS Server'), _('Select or enter DNS server address'));
    Object.entries(constants.DNS_SERVER_OPTIONS).forEach(([key, label]) => {
        o.value(key, _(label));
    });
    o.default = '1.1.1.1';
    o.rmempty = false;
    o.depends('split_dns_enabled', '1');
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

        const domainRegex = /^([a-zA-Z0-9-]+\.)*[a-zA-Z0-9-]+\.[a-zA-Z]{2,}(\/[^\s]*)?$/;
        if (!domainRegex.test(value)) {
            return _('Invalid DNS server format. Examples: 8.8.8.8 or dns.example.com or dns.example.com/nicedns for DoH');
        }

        return true;
    };

    o = mainSection.taboption('additional', form.Value, 'dns_rewrite_ttl', _('DNS Rewrite TTL'), _('Time in seconds for DNS record caching (default: 60)'));
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

    o = mainSection.taboption('additional', form.Value, 'cache_file', _('Cache File Path'), _('Select or enter path for sing-box cache file. Change this ONLY if you know what you are doing'));
    o.value('/tmp/cache.db', 'RAM (/tmp/cache.db)');
    o.value('/usr/share/sing-box/cache.db', 'Flash (/usr/share/sing-box/cache.db)');
    o.default = '/tmp/cache.db';
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

    o = mainSection.taboption('additional', widgets.DeviceSelect, 'iface', _('Source Network Interface'), _('Select the network interface from which the traffic will originate'));
    o.ucisection = 'main';
    o.default = 'br-lan';
    o.noaliases = true;
    o.nobridges = false;
    o.noinactive = false;
    o.multiple = true;
    o.filter = function (section_id, value) {
        if (['wan', 'phy0-ap0', 'phy1-ap0', 'pppoe-wan'].indexOf(value) !== -1) {
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

    o = mainSection.taboption('additional', form.Flag, 'mon_restart_ifaces', _('Interface monitoring'), _('Interface monitoring for bad WAN'));
    o.default = '0';
    o.rmempty = false;
    o.ucisection = 'main';

    o = mainSection.taboption('additional', widgets.NetworkSelect, 'restart_ifaces', _('Interface for monitoring'), _('Select the WAN interfaces to be monitored'));
    o.ucisection = 'main';
    o.depends('mon_restart_ifaces', '1');
    o.multiple = true;
    o.filter = function (section_id, value) {
        return ['lan', 'loopback'].indexOf(value) === -1 && !value.startsWith('@');
    };

    o = mainSection.taboption('additional', form.Flag, 'dont_touch_dhcp', _('Dont touch my DHCP!'), _('Podkop will not change the DHCP config'));
    o.default = '0';
    o.rmempty = false;
    o.ucisection = 'main';

    o = mainSection.taboption('additional', form.Flag, 'detour', _('Proxy download of lists'), _('Downloading all lists via main Proxy/VPN'));
    o.default = '0';
    o.rmempty = false;
    o.ucisection = 'main';

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
}

return baseclass.extend({
    createAdditionalSection
}); 