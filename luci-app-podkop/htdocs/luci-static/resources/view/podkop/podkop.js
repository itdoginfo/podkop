'use strict';
'require view';
'require form';
'require ui';
'require network';
'require fs';

return view.extend({
    async render() {
        document.getElementsByTagName('head')[0].insertAdjacentHTML('beforeend', `
            <meta http-equiv="Cache-Control" content="no-cache, no-store, must-revalidate">
            <meta http-equiv="Pragma" content="no-cache">
            <meta http-equiv="Expires" content="0">
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

                        const warningMsg = _('Warning: Russia inside can only be used with Meta, Twitter, Discord, and Telegram. %s have been removed from selection.').format(
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

        // Connection Checks Section
        o = s.taboption('diagnostics', form.Button, '_check_nft');
        o.title = _('NFT Rules');
        o.description = _('Show current nftables rules and statistics');
        o.inputtitle = _('Check Rules');
        o.inputstyle = 'apply';
        o.onclick = function () {
            return fs.exec('/etc/init.d/podkop', ['check_nft'])
                .then(function (res) {
                    const formattedOutput = formatDiagnosticOutput(res.stdout || _('No output'));
                    ui.showModal(_('NFT Rules'), [
                        E('div', {
                            style:
                                'max-height: 70vh;' +
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
                                'click': function () {
                                    const textarea = document.createElement('textarea');
                                    textarea.value = formattedOutput;
                                    document.body.appendChild(textarea);
                                    textarea.select();
                                    try {
                                        document.execCommand('copy');
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
        };



        // Logs Section
        o = s.taboption('diagnostics', form.Button, '_check_sing_box_logs');
        o.title = _('Sing-Box Logs');
        o.description = _('View recent sing-box logs from system journal');
        o.inputtitle = _('View Sing-Box Logs');
        o.inputstyle = 'apply';
        o.onclick = function () {
            return fs.exec('/etc/init.d/podkop', ['check_sing_box_logs'])
                .then(function (res) {
                    const formattedOutput = formatDiagnosticOutput(res.stdout || _('No output'));
                    ui.showModal(_('Sing-Box Logs'), [
                        E('div', {
                            style:
                                'max-height: 70vh;' +
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
                                'click': function () {
                                    const textarea = document.createElement('textarea');
                                    textarea.value = formattedOutput;
                                    document.body.appendChild(textarea);
                                    textarea.select();
                                    try {
                                        document.execCommand('copy');
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
        };

        o = s.taboption('diagnostics', form.Button, '_check_logs');
        o.title = _('Podkop Logs');
        o.description = _('View recent podkop logs from system journal');
        o.inputtitle = _('View Podkop Logs');
        o.inputstyle = 'apply';
        o.onclick = function () {
            return fs.exec('/etc/init.d/podkop', ['check_logs'])
                .then(function (res) {
                    const formattedOutput = formatDiagnosticOutput(res.stdout || _('No output'));
                    ui.showModal(_('Podkop Logs'), [
                        E('div', {
                            style:
                                'max-height: 70vh;' +
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
                                'click': function () {
                                    const textarea = document.createElement('textarea');
                                    textarea.value = formattedOutput;
                                    document.body.appendChild(textarea);
                                    textarea.select();
                                    try {
                                        document.execCommand('copy');
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
        };

        // Configurations Section
        o = s.taboption('diagnostics', form.Button, '_check_sing_box_connections');
        o.title = _('Active Connections');
        o.description = _('View active sing-box network connections');
        o.inputtitle = _('Check Connections');
        o.inputstyle = 'apply';
        o.onclick = function () {
            return fs.exec('/etc/init.d/podkop', ['check_sing_box_connections'])
                .then(function (res) {
                    const formattedOutput = formatDiagnosticOutput(res.stdout || _('No output'));
                    ui.showModal(_('Active Connections'), [
                        E('div', {
                            style:
                                'max-height: 70vh;' +
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
                                'click': function () {
                                    const textarea = document.createElement('textarea');
                                    textarea.value = formattedOutput;
                                    document.body.appendChild(textarea);
                                    textarea.select();
                                    try {
                                        document.execCommand('copy');
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
        };

        o = s.taboption('diagnostics', form.Button, '_check_dnsmasq');
        o.title = _('DNSMasq Configuration');
        o.description = _('View current DNSMasq configuration settings');
        o.inputtitle = _('Check DNSMasq');
        o.inputstyle = 'apply';
        o.onclick = function () {
            return fs.exec('/etc/init.d/podkop', ['check_dnsmasq'])
                .then(function (res) {
                    const formattedOutput = formatDiagnosticOutput(res.stdout || _('No output'));
                    ui.showModal(_('DNSMasq Configuration'), [
                        E('div', {
                            style:
                                'max-height: 70vh;' +
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
                                'click': function () {
                                    const textarea = document.createElement('textarea');
                                    textarea.value = formattedOutput;
                                    document.body.appendChild(textarea);
                                    textarea.select();
                                    try {
                                        document.execCommand('copy');
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
        };

        o = s.taboption('diagnostics', form.Button, '_show_sing_box_config');
        o.title = _('Sing-Box Configuration');
        o.description = _('Show current sing-box configuration');
        o.inputtitle = _('Show Sing-Box Config');
        o.inputstyle = 'apply';
        o.onclick = function () {
            return fs.exec('/etc/init.d/podkop', ['show_sing_box_config'])
                .then(function (res) {
                    const formattedOutput = formatDiagnosticOutput(res.stdout || _('No output'));
                    ui.showModal(_('Sing-Box Configuration'), [
                        E('div', {
                            style:
                                'max-height: 70vh;' +
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
                                'click': function () {
                                    const textarea = document.createElement('textarea');
                                    textarea.value = '```json\n' + formattedOutput + '\n```';
                                    document.body.appendChild(textarea);
                                    textarea.select();
                                    try {
                                        document.execCommand('copy');
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
        };

        o = s.taboption('diagnostics', form.Button, '_show_config');
        o.title = _('Podkop Configuration');
        o.description = _('Show current podkop configuration with masked sensitive data');
        o.inputtitle = _('Show Config');
        o.inputstyle = 'apply';
        o.onclick = function () {
            return fs.exec('/etc/init.d/podkop', ['show_config'])
                .then(function (res) {
                    const formattedOutput = formatDiagnosticOutput(res.stdout || _('No output'));
                    ui.showModal(_('Podkop Configuration'), [
                        E('div', {
                            style:
                                'max-height: 70vh;' +
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
                                'click': function () {
                                    const textarea = document.createElement('textarea');
                                    textarea.value = formattedOutput;
                                    document.body.appendChild(textarea);
                                    textarea.select();
                                    try {
                                        document.execCommand('copy');
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
        };

        o = s.taboption('diagnostics', form.Button, '_list_update');
        o.title = _('Update Lists');
        o.description = _('Update all lists in config');
        o.inputtitle = _('Update Lists');
        o.inputstyle = 'apply';
        o.onclick = function () {
            return fs.exec('/etc/init.d/podkop', ['list_update'])
                .then(function (res) {
                    const formattedOutput = formatDiagnosticOutput(res.stdout || _('No output'));
                    ui.showModal(_('Lists Update Results'), [
                        E('div', { style: 'white-space:pre-wrap;padding:5px' }, formattedOutput),
                        E('div', { class: 'right' }, E('button', {
                            class: 'btn',
                            click: ui.hideModal
                        }, _('Close')))
                    ]);
                });
        };

        return m.render();
    }
});