'use strict';
'require view';
'require form';
'require ui';
'require network';
'require fs';

const STATUS_COLORS = {
    SUCCESS: '#4caf50',
    ERROR: '#f44336',
    WARNING: '#ff9800'
};

async function safeExec(command, args = [], timeout = 3000) {
    try {
        const controller = new AbortController();
        const timeoutId = setTimeout(() => controller.abort(), timeout);

        const result = await Promise.race([
            fs.exec(command, args),
            new Promise((_, reject) => {
                controller.signal.addEventListener('abort', () => {
                    reject(new Error('Command execution timed out'));
                });
            })
        ]);

        clearTimeout(timeoutId);
        return result;
    } catch (error) {
        console.warn(`Command execution failed or timed out: ${command} ${args.join(' ')}`);
        return { stdout: '', stderr: error.message };
    }
}

function formatDiagnosticOutput(output) {
    if (typeof output !== 'string') return '';
    return output.trim()
        .replace(/\x1b\[[0-9;]*m/g, '')
        .replace(/\r\n/g, '\n')
        .replace(/\r/g, '\n');
}

function getNetworkInterfaces(o, section_id) {
    const excludeInterfaces = ['br-lan', 'eth0', 'eth1', 'wan', 'phy0-ap0', 'phy1-ap0', 'pppoe-wan'];

    return network.getDevices().then(devices => {
        // Reset the options by creating a new keylist
        o.keylist = [];
        o.vallist = [];

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

    o = s.taboption('basic', form.TextValue, 'proxy_string', _('Proxy Configuration URL'), '');
    o.depends('proxy_config_type', 'url');
    o.rows = 5;
    o.ucisection = s.section;
    o.sectionDescriptions = new Map();

    o.renderWidget = function (section_id, option_index, cfgvalue) {
        const original = form.TextValue.prototype.renderWidget.apply(this, [section_id, option_index, cfgvalue]);
        const container = E('div', {});
        container.appendChild(original);

        if (cfgvalue) {
            try {
                const label = cfgvalue.split('#').pop() || 'unnamed';
                const decodedLabel = decodeURIComponent(label);
                const descDiv = E('div', { 'class': 'cbi-value-description' }, _('Current config: ') + decodedLabel);
                container.appendChild(descDiv);
            } catch (e) {
                console.error('Error parsing config label:', e);
                const descDiv = E('div', { 'class': 'cbi-value-description' }, _('Current config: ') + (cfgvalue.split('#').pop() || 'unnamed'));
                container.appendChild(descDiv);
            }
        } else {
            const defaultDesc = E('div', { 'class': 'cbi-value-description' },
                _('Enter connection string starting with vless:// or ss:// for proxy configuration'));
            container.appendChild(defaultDesc);
        }

        return container;
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
    o.load = function (section_id) {
        return getNetworkInterfaces(this, section_id).then(() => {
            return this.super('load', section_id);
        });
    };

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

// Utility functions
const copyToClipboard = (text, button) => {
    const textarea = document.createElement('textarea');
    textarea.value = text;
    document.body.appendChild(textarea);
    textarea.select();
    try {
        document.execCommand('copy');
        const originalText = button.textContent;
        button.textContent = _('Copied!');
        setTimeout(() => button.textContent = originalText, 1000);
    } catch (err) {
        ui.addNotification(null, E('p', {}, _('Failed to copy: ') + err.message));
    }
    document.body.removeChild(textarea);
};

const validateUrl = (url, protocols = ['http:', 'https:']) => {
    try {
        const parsedUrl = new URL(url);
        if (!protocols.includes(parsedUrl.protocol)) {
            return _('URL must use one of the following protocols: ') + protocols.join(', ');
        }
        return true;
    } catch (e) {
        return _('Invalid URL format');
    }
};

// UI Helper functions
const createModalContent = (title, content) => {
    return [
        E('div', {
            'class': 'panel-body',
            style: 'max-height: 70vh; overflow-y: auto; margin: 1em 0; padding: 1.5em; ' +
                'font-family: monospace; white-space: pre-wrap; word-wrap: break-word; ' +
                'line-height: 1.5; font-size: 14px;'
        }, [
            E('pre', { style: 'margin: 0;' }, content)
        ]),
        E('div', {
            'class': 'right',
            style: 'margin-top: 1em;'
        }, [
            E('button', {
                'class': 'btn',
                'click': ev => copyToClipboard('```txt\n' + content + '\n```', ev.target)
            }, _('Copy to Clipboard')),
            E('button', {
                'class': 'btn',
                'click': ui.hideModal
            }, _('Close'))
        ])
    ];
};

const showConfigModal = async (command, title) => {
    const res = await safeExec('/etc/init.d/podkop', [command]);
    const formattedOutput = formatDiagnosticOutput(res.stdout || _('No output'));
    ui.showModal(_(title), createModalContent(title, formattedOutput));
};

// Button Factory
const ButtonFactory = {
    createButton: function (config) {
        return E('button', {
            'class': `btn ${config.additionalClass || ''}`.trim(),
            'click': config.onClick,
            'style': config.style || ''
        }, _(config.label));
    },

    createActionButton: function (config) {
        return this.createButton({
            label: config.label,
            additionalClass: `cbi-button-${config.type || ''}`,
            onClick: () => safeExec('/etc/init.d/podkop', [config.action])
                .then(() => config.reload && location.reload()),
            style: config.style
        });
    },

    createModalButton: function (config) {
        return this.createButton({
            label: config.label,
            onClick: () => showConfigModal(config.command, config.title),
            style: config.style
        });
    }
};

// Status Panel Factory
const createStatusPanel = (title, status, buttons) => {
    const headerContent = [
        E('strong', {}, _(title)),
        status && E('br'),
        status && E('span', {
            'style': `color: ${status.running ? STATUS_COLORS.SUCCESS : STATUS_COLORS.ERROR}`
        }, [
            status.running ? '✔' : '✘',
            ' ',
            status.status
        ])
    ].filter(Boolean);

    return E('div', {
        'class': 'panel',
        'style': 'flex: 1; padding: 15px;'
    }, [
        E('div', { 'class': 'panel-heading' }, headerContent),
        E('div', {
            'class': 'panel-body',
            'style': 'display: flex; flex-direction: column; gap: 8px;'
        }, buttons)
    ]);
};

// Update the status section creation
let createStatusSection = function (podkopStatus, singboxStatus, podkop, luci, singbox, system, fakeipStatus) {
    return E('div', { 'class': 'cbi-section' }, [
        E('h3', {}, _('Service Status')),
        E('div', { 'class': 'table', style: 'display: flex; gap: 20px;' }, [
            // Podkop Status Panel
            createStatusPanel('Podkop Status', podkopStatus, [
                podkopStatus.running ?
                    ButtonFactory.createActionButton({
                        label: 'Stop Podkop',
                        type: 'remove',
                        action: 'stop',
                        reload: true
                    }) :
                    ButtonFactory.createActionButton({
                        label: 'Start Podkop',
                        type: 'apply',
                        action: 'start',
                        reload: true
                    }),
                ButtonFactory.createActionButton({
                    label: 'Restart Podkop',
                    type: 'apply',
                    action: 'restart',
                    reload: true
                }),
                ButtonFactory.createActionButton({
                    label: podkopStatus.enabled ? 'Disable Podkop' : 'Enable Podkop',
                    type: podkopStatus.enabled ? 'remove' : 'apply',
                    action: podkopStatus.enabled ? 'disable' : 'enable',
                    reload: true
                }),
                ButtonFactory.createModalButton({
                    label: 'Show Config',
                    command: 'show_config',
                    title: 'Podkop Configuration'
                }),
                ButtonFactory.createModalButton({
                    label: 'View Logs',
                    command: 'check_logs',
                    title: 'Podkop Logs'
                })
            ]),

            // Sing-box Status Panel
            createStatusPanel('Sing-box Status', singboxStatus, [
                ButtonFactory.createModalButton({
                    label: 'Show Config',
                    command: 'show_sing_box_config',
                    title: 'Sing-box Configuration'
                }),
                ButtonFactory.createModalButton({
                    label: 'View Logs',
                    command: 'check_sing_box_logs',
                    title: 'Sing-box Logs'
                }),
                ButtonFactory.createModalButton({
                    label: 'Check Connections',
                    command: 'check_sing_box_connections',
                    title: 'Active Connections'
                })
            ]),

            // FakeIP Status Panel with dynamic status
            createStatusPanel('FakeIP Status', {
                running: fakeipStatus.state === 'working',
                status: fakeipStatus.message
            }, [
                ButtonFactory.createModalButton({
                    label: 'Check NFT Rules',
                    command: 'check_nft',
                    title: 'NFT Rules'
                }),
                ButtonFactory.createModalButton({
                    label: 'Check DNSMasq',
                    command: 'check_dnsmasq',
                    title: 'DNSMasq Configuration'
                }),
                ButtonFactory.createModalButton({
                    label: 'Update Lists',
                    command: 'list_update',
                    title: 'Lists Update Results'
                })
            ]),

            // Version Information Panel
            createStatusPanel('Version Information', null, [
                E('div', { 'style': 'margin-top: 10px; font-family: monospace; white-space: pre-wrap;' }, [
                    E('strong', {}, 'Podkop: '), podkop.stdout ? podkop.stdout.trim() : _('Unknown'), '\n',
                    E('strong', {}, 'LuCI App: '), luci.stdout ? luci.stdout.trim() : _('Unknown'), '\n',
                    E('strong', {}, 'Sing-box: '), singbox.stdout ? singbox.stdout.trim() : _('Unknown'), '\n',
                    E('strong', {}, 'OpenWrt Version: '), system.stdout ? system.stdout.split('\n')[1].trim() : _('Unknown'), '\n',
                    E('strong', {}, 'Device Model: '), system.stdout ? system.stdout.split('\n')[4].trim() : _('Unknown')
                ])
            ])
        ])
    ]);
};

return view.extend({
    async render() {
        document.head.insertAdjacentHTML('beforeend', `
            <meta http-equiv="Cache-Control" content="no-cache, no-store, must-revalidate">
            <meta http-equiv="Pragma" content="no-cache">
            <meta http-equiv="Expires" content="0">
            <style>
                .cbi-value {
                    margin-bottom: 10px !important;
                }

                #diagnostics-status .table > div {
                    background: var(--background-color-primary);
                    border: 1px solid var(--border-color-medium);
                    border-radius: var(--border-radius);
                }

                #diagnostics-status .table > div pre,
                #diagnostics-status .table > div div[style*="monospace"] {
                    color: var(--color-text-primary);
                }

                #diagnostics-status .alert-message {
                    background: var(--background-color-primary);
                    border-color: var(--border-color-medium);
                }
            </style>
        `);

        const m = new form.Map('podkop', _(''), null, ['main', 'extra']);

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

        o = mainSection.taboption('additional', form.Value, 'dns_rewrite_ttl', _('DNS Rewrite TTL'), _('Time in seconds for DNS record caching (default: 600)'));
        o.default = '600';
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

        o = mainSection.taboption('diagnostics', form.DummyValue, '_status');
        o.rawhtml = true;
        o.cfgvalue = () => E('div', { id: 'diagnostics-status' }, _('Loading diagnostics...'));

        function checkFakeIP() {
            const createStatus = (state, message, color) => ({
                state,
                message: _(message),
                color: STATUS_COLORS[color]
            });

            return new Promise(async (resolve) => {
                try {
                    const singboxStatusResult = await safeExec('/etc/init.d/podkop', ['get_sing_box_status']);
                    const singboxStatus = JSON.parse(singboxStatusResult.stdout || '{"running":0,"dns_configured":0}');

                    if (!singboxStatus.running) {
                        return resolve(createStatus('not_working', 'sing-box not running', 'ERROR'));
                    }
                    if (!singboxStatus.dns_configured) {
                        return resolve(createStatus('not_working', 'DNS not configured', 'ERROR'));
                    }

                    const controller = new AbortController();
                    const timeoutId = setTimeout(() => controller.abort(), 10000);

                    try {
                        const response = await fetch('http://httpbin.org/ip', { signal: controller.signal });
                        const text = await response.text();
                        clearTimeout(timeoutId);

                        if (text.includes('Cannot GET /ip')) {
                            return resolve(createStatus('working', 'working', 'SUCCESS'));
                        }
                        if (text.includes('"origin":')) {
                            return resolve(createStatus('not_working', 'not working', 'ERROR'));
                        }
                        return resolve(createStatus('error', 'check error', 'WARNING'));
                    } catch (fetchError) {
                        clearTimeout(timeoutId);
                        const message = fetchError.name === 'AbortError' ? 'timeout' : 'check error';
                        return resolve(createStatus('error', message, 'WARNING'));
                    }
                } catch (error) {
                    console.error('Error in checkFakeIP:', error);
                    return resolve(createStatus('error', 'check error', 'WARNING'));
                }
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
                    safeExec('/etc/init.d/podkop', ['get_status']),
                    safeExec('/etc/init.d/podkop', ['get_sing_box_status']),
                    safeExec('/etc/init.d/podkop', ['show_version']),
                    safeExec('/etc/init.d/podkop', ['show_luci_version']),
                    safeExec('/etc/init.d/podkop', ['show_sing_box_version']),
                    safeExec('/etc/init.d/podkop', ['show_system_info']),
                    checkFakeIP()
                ]);

                const parsedPodkopStatus = JSON.parse(podkopStatus.stdout || '{"running":0,"enabled":0,"status":"unknown"}');
                const parsedSingboxStatus = JSON.parse(singboxStatus.stdout || '{"running":0,"enabled":0,"status":"unknown"}');

                const container = document.getElementById('diagnostics-status');
                if (!container) return;

                const statusSection = createStatusSection(parsedPodkopStatus, parsedSingboxStatus, podkop, luci, singbox, system, fakeipStatus);
                container.innerHTML = '';
                container.appendChild(statusSection);

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

        function startPeriodicUpdates(titleDiv) {
            let updateTimer = null;
            let isVisible = !document.hidden;
            let versionText = _('Podkop');
            let versionReceived = false;

            const updateStatus = async () => {
                try {
                    if (!versionReceived) {
                        const version = await safeExec('/etc/init.d/podkop', ['show_version'], 2000);
                        if (version.stdout) {
                            versionText = _('Podkop') + ' v' + version.stdout.trim();
                            versionReceived = true;
                        }
                    }

                    const singboxStatusResult = await safeExec('/etc/init.d/podkop', ['get_sing_box_status']);
                    const singboxStatus = JSON.parse(singboxStatusResult.stdout || '{"running":0,"dns_configured":0}');
                    const fakeipStatus = await checkFakeIP();

                    titleDiv.textContent = versionText + (!singboxStatus.running || !singboxStatus.dns_configured === 'not_working' ? ' (not working)' : '');

                    await updateDiagnostics();
                } catch (error) {
                    console.warn('Failed to update status:', error);
                    titleDiv.textContent = versionText + ' (not working)';
                }
            };

            const toggleUpdates = (visible) => {
                if (visible) {
                    updateStatus();
                    if (!updateTimer) {
                        updateTimer = setInterval(updateStatus, 10000);
                    }
                } else if (updateTimer) {
                    clearInterval(updateTimer);
                    updateTimer = null;
                }
            };

            document.addEventListener('visibilitychange', () => {
                isVisible = !document.hidden;
                toggleUpdates(isVisible);
            });

            toggleUpdates(isVisible);

            window.addEventListener('unload', () => {
                if (updateTimer) {
                    clearInterval(updateTimer);
                }
            });
        }

        // Extra Section
        const extraSection = m.section(form.TypedSection, 'extra', _('Extra configurations'));
        extraSection.anonymous = false;
        extraSection.addremove = true;
        extraSection.addbtntitle = _('Add Section');
        extraSection.multiple = true;
        createConfigSection(extraSection, m, network);

        const map_promise = m.render().then(node => {
            const titleDiv = E('h2', { 'class': 'cbi-map-title' }, _('Podkop'));
            node.insertBefore(titleDiv, node.firstChild);

            node.classList.add('fade-in');
            startPeriodicUpdates(titleDiv);
            return node;
        });

        return map_promise;
    }
});