'use strict';
'require baseclass';
'require form';
'require ui';
'require uci';
'require fs';
'require view.podkop.constants as constants';

// Helper Functions
// Common status object creator
function createStatus(state, message, color) {
    return {
        state,
        message: _(message),
        color: constants.STATUS_COLORS[color]
    };
}

function formatDiagnosticOutput(output) {
    if (typeof output !== 'string') return '';
    return output.trim()
        .replace(/\x1b\[[0-9;]*m/g, '')
        .replace(/\r\n/g, '\n')
        .replace(/\r/g, '\n');
}

const copyToClipboard = (text, button) => {
    const textarea = document.createElement('textarea');
    textarea.value = text;
    document.body.appendChild(textarea);
    textarea.select();
    try {
        document.execCommand('copy');
        const originalText = button.textContent;
        button.textContent = _('Copied!');
        setTimeout(() => button.textContent = originalText, constants.BUTTON_FEEDBACK_TIMEOUT);
    } catch (err) {
        ui.addNotification(null, E('p', {}, _('Failed to copy: ') + err.message));
    }
    document.body.removeChild(textarea);
};

// IP masking function
const maskIP = (ip) => {
    if (!ip) return '';
    const parts = ip.split('.');
    if (parts.length !== 4) return ip;
    return ['XX', 'XX', 'XX', parts[3]].join('.');
};

async function safeExec(command, args = [], timeout = constants.COMMAND_TIMEOUT) {
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

// Status Check Functions
async function checkFakeIP() {
    try {
        const controller = new AbortController();
        const timeoutId = setTimeout(() => controller.abort(), constants.FETCH_TIMEOUT);

        try {
            const response = await fetch(`https://${constants.FAKEIP_CHECK_DOMAIN}/check`, { signal: controller.signal });
            const data = await response.json();
            clearTimeout(timeoutId);

            if (data.fakeip === true) {
                return createStatus('working', 'working', 'SUCCESS');
            } else {
                return createStatus('not_working', 'not working', 'ERROR');
            }
        } catch (fetchError) {
            clearTimeout(timeoutId);
            const message = fetchError.name === 'AbortError' ? 'timeout' : 'check error';
            return createStatus('error', message, 'WARNING');
        }
    } catch (error) {
        return createStatus('error', 'check error', 'WARNING');
    }
}

async function checkFakeIPCLI() {
    try {
        const singboxStatusResult = await safeExec('/usr/bin/podkop', ['get_sing_box_status']);
        const singboxStatus = JSON.parse(singboxStatusResult.stdout || '{"running":0,"dns_configured":0}');

        if (!singboxStatus.running) {
            return createStatus('not_working', 'sing-box not running', 'ERROR');
        }

        const result = await safeExec('nslookup', ['-timeout=2', constants.FAKEIP_CHECK_DOMAIN, '127.0.0.42']);

        if (result.stdout && result.stdout.includes('198.18')) {
            return createStatus('working', 'working on router', 'SUCCESS');
        } else {
            return createStatus('not_working', 'not working on router', 'ERROR');
        }
    } catch (error) {
        return createStatus('error', 'CLI check error', 'WARNING');
    }
}

function checkDNSAvailability() {
    return new Promise(async (resolve) => {
        try {
            const dnsStatusResult = await safeExec('/usr/bin/podkop', ['check_dns_available']);
            if (!dnsStatusResult || !dnsStatusResult.stdout) {
                return resolve({
                    remote: createStatus('error', 'DNS check timeout', 'WARNING'),
                    local: createStatus('error', 'DNS check timeout', 'WARNING')
                });
            }

            try {
                const dnsStatus = JSON.parse(dnsStatusResult.stdout);

                const remoteStatus = dnsStatus.is_available ?
                    createStatus('available', `${dnsStatus.dns_type.toUpperCase()} (${dnsStatus.dns_server}) available`, 'SUCCESS') :
                    createStatus('unavailable', `${dnsStatus.dns_type.toUpperCase()} (${dnsStatus.dns_server}) unavailable`, 'ERROR');

                const localStatus = dnsStatus.local_dns_working ?
                    createStatus('available', 'Router DNS working', 'SUCCESS') :
                    createStatus('unavailable', 'Router DNS not working', 'ERROR');

                return resolve({
                    remote: remoteStatus,
                    local: localStatus
                });
            } catch (parseError) {
                return resolve({
                    remote: createStatus('error', 'DNS check parse error', 'WARNING'),
                    local: createStatus('error', 'DNS check parse error', 'WARNING')
                });
            }
        } catch (error) {
            return resolve({
                remote: createStatus('error', 'DNS check error', 'WARNING'),
                local: createStatus('error', 'DNS check error', 'WARNING')
            });
        }
    });
}

async function checkBypass() {
    return new Promise(async (resolve) => {
        try {
            let configMode = 'proxy'; // Default fallback
            try {
                const data = await uci.load('podkop');
                configMode = uci.get('podkop', 'main', 'mode') || 'proxy';
            } catch (e) {
                console.error('Error getting mode from UCI:', e);
            }

            // Check if sing-box is running
            const singboxStatusResult = await safeExec('/usr/bin/podkop', ['get_sing_box_status']);
            const singboxStatus = JSON.parse(singboxStatusResult.stdout || '{"running":0,"dns_configured":0}');

            if (!singboxStatus.running) {
                return resolve(createStatus('not_working', `${configMode} not running`, 'ERROR'));
            }

            // Fetch IP from first endpoint
            let ip1 = null;
            try {
                const controller1 = new AbortController();
                const timeoutId1 = setTimeout(() => controller1.abort(), constants.FETCH_TIMEOUT);

                const response1 = await fetch(`https://${constants.FAKEIP_CHECK_DOMAIN}/check`, { signal: controller1.signal });
                const data1 = await response1.json();
                clearTimeout(timeoutId1);

                ip1 = data1.IP;
            } catch (error) {
                return resolve(createStatus('error', 'First endpoint check failed', 'WARNING'));
            }

            // Fetch IP from second endpoint
            let ip2 = null;
            try {
                const controller2 = new AbortController();
                const timeoutId2 = setTimeout(() => controller2.abort(), constants.FETCH_TIMEOUT);

                const response2 = await fetch(`https://${constants.IP_CHECK_DOMAIN}/check`, { signal: controller2.signal });
                const data2 = await response2.json();
                clearTimeout(timeoutId2);

                ip2 = data2.IP;
            } catch (error) {
                return resolve(createStatus('not_working', `${configMode} not working`, 'ERROR'));
            }

            // Compare IPs
            if (ip1 && ip2) {
                if (ip1 !== ip2) {
                    return resolve(createStatus('working', `${configMode} working correctly`, 'SUCCESS'));
                } else {
                    return resolve(createStatus('not_working', `${configMode} routing incorrect`, 'ERROR'));
                }
            } else {
                return resolve(createStatus('error', 'IP comparison failed', 'WARNING'));
            }
        } catch (error) {
            return resolve(createStatus('error', 'Bypass check error', 'WARNING'));
        }
    });
}

// Error Handling
async function getPodkopErrors() {
    try {
        const result = await safeExec('/usr/bin/podkop', ['check_logs']);
        if (!result || !result.stdout) return [];

        const logs = result.stdout.split('\n');
        const errors = logs.filter(log =>
            log.includes('[critical]')
        );

        console.log('Found errors:', errors);
        return errors;
    } catch (error) {
        console.error('Error getting podkop logs:', error);
        return [];
    }
}

function showErrorNotification(error, isMultiple = false) {
    const notificationContent = E('div', { 'class': 'alert-message error' }, [
        E('pre', { 'class': 'error-log' }, error)
    ]);

    ui.addNotification(null, notificationContent);
}

// Modal Functions
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
    // Create and show modal immediately with loading state
    const modalContent = E('div', { 'class': 'panel-body' }, [
        E('div', {
            'class': 'panel-body',
            style: 'max-height: 70vh; overflow-y: auto; margin: 1em 0; padding: 1.5em; ' +
                'font-family: monospace; white-space: pre-wrap; word-wrap: break-word; ' +
                'line-height: 1.5; font-size: 14px;'
        }, [
            E('pre', {
                'id': 'modal-content-pre',
                style: 'margin: 0;'
            }, _('Loading...'))
        ]),
        E('div', {
            'class': 'right',
            style: 'margin-top: 1em;'
        }, [
            E('button', {
                'class': 'btn',
                'id': 'copy-button',
                'click': ev => copyToClipboard('```txt\n' + document.getElementById('modal-content-pre').innerText + '\n```', ev.target)
            }, _('Copy to Clipboard')),
            E('button', {
                'class': 'btn',
                'click': ui.hideModal
            }, _('Close'))
        ])
    ]);

    ui.showModal(_(title), modalContent);

    // Function to update modal content
    const updateModalContent = (content) => {
        const pre = document.getElementById('modal-content-pre');
        if (pre) {
            pre.textContent = content;
        }
    };

    try {
        let formattedOutput = '';

        if (command === 'global_check') {
            const res = await safeExec('/usr/bin/podkop', [command]);
            formattedOutput = formatDiagnosticOutput(res.stdout || _('No output'));

            try {
                const controller = new AbortController();
                const timeoutId = setTimeout(() => controller.abort(), constants.FETCH_TIMEOUT);

                const response = await fetch(`https://${constants.FAKEIP_CHECK_DOMAIN}/check`, { signal: controller.signal });
                const data = await response.json();
                clearTimeout(timeoutId);

                if (data.fakeip === true) {
                    formattedOutput += '\n✅ ' + _('FakeIP is working in browser!') + '\n';
                } else {
                    formattedOutput += '\n❌ ' + _('FakeIP is not working in browser') + '\n';
                    formattedOutput += _('Check DNS server on current device (PC, phone)') + '\n';
                    formattedOutput += _('Its must be router!') + '\n';
                }

                // Bypass check
                const bypassResponse = await fetch(`https://${constants.FAKEIP_CHECK_DOMAIN}/check`, { signal: controller.signal });
                const bypassData = await bypassResponse.json();
                const bypassResponse2 = await fetch(`https://${constants.IP_CHECK_DOMAIN}/check`, { signal: controller.signal });
                const bypassData2 = await bypassResponse2.json();

                formattedOutput += '━━━━━━━━━━━━━━━━━━━━━━━━━━━\n';

                if (bypassData.IP && bypassData2.IP && bypassData.IP !== bypassData2.IP) {
                    formattedOutput += '✅ ' + _('Proxy working correctly') + '\n';
                    formattedOutput += _('Direct IP: ') + maskIP(bypassData.IP) + '\n';
                    formattedOutput += _('Proxy IP: ') + maskIP(bypassData2.IP) + '\n';
                } else if (bypassData.IP === bypassData2.IP) {
                    formattedOutput += '❌ ' + _('Proxy is not working - same IP for both domains') + '\n';
                    formattedOutput += _('IP: ') + maskIP(bypassData.IP) + '\n';
                } else {
                    formattedOutput += '❌ ' + _('Proxy check failed') + '\n';
                }

                updateModalContent(formattedOutput);
            } catch (error) {
                formattedOutput += '\n❌ ' + _('Check failed: ') + (error.name === 'AbortError' ? _('timeout') : error.message) + '\n';
                updateModalContent(formattedOutput);
            }
        } else {
            const res = await safeExec('/usr/bin/podkop', [command]);
            formattedOutput = formatDiagnosticOutput(res.stdout || _('No output'));
            updateModalContent(formattedOutput);
        }
    } catch (error) {
        updateModalContent(_('Error: ') + error.message);
    }
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
            onClick: () => safeExec('/usr/bin/podkop', [config.action])
                .then(() => config.reload && location.reload()),
            style: config.style
        });
    },

    createInitActionButton: function (config) {
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
const createStatusPanel = (title, status, buttons, extraData = {}) => {
    const headerContent = [
        E('strong', {}, _(title)),
        status && E('br'),
        status && E('span', {
            'style': `color: ${title === 'Sing-box Status' ?
                (status.running && !status.enabled ? constants.STATUS_COLORS.SUCCESS : constants.STATUS_COLORS.ERROR) :
                title === 'Podkop Status' ?
                    (status.enabled ? constants.STATUS_COLORS.SUCCESS : constants.STATUS_COLORS.ERROR) :
                    (status.running ? constants.STATUS_COLORS.SUCCESS : constants.STATUS_COLORS.ERROR)
                }`
        }, [
            title === 'Sing-box Status' ?
                (status.running && !status.enabled ? '✔ running' : '✘ ' + status.status) :
                title === 'Podkop Status' ?
                    (status.enabled ? '✔ Autostart enabled' : '✘ Autostart disabled') :
                    (status.running ? '✔' : '✘') + ' ' + status.status
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
        }, title === 'Podkop Status' ? [
            ButtonFactory.createActionButton({
                label: 'Restart Podkop',
                type: 'apply',
                action: 'restart',
                reload: true
            }),
            ButtonFactory.createActionButton({
                label: 'Stop Podkop',
                type: 'apply',
                action: 'stop',
                reload: true
            }),
            ButtonFactory.createInitActionButton({
                label: status.enabled ? 'Disable Autostart' : 'Enable Autostart',
                type: status.enabled ? 'remove' : 'apply',
                action: status.enabled ? 'disable' : 'enable',
                reload: true
            }),
            ButtonFactory.createModalButton({
                label: E('strong', _('Global check')),
                command: 'global_check',
                title: _('Global check')
            }),
            ButtonFactory.createModalButton({
                label: 'View Logs',
                command: 'check_logs',
                title: 'Podkop Logs'
            }),
            ButtonFactory.createModalButton({
                label: _('Update Lists'),
                command: 'list_update',
                title: _('Lists Update Results')
            })
        ] : title === _('FakeIP Status') ? [
            E('div', { style: 'margin-bottom: 5px;' }, [
                E('div', {}, [
                    E('span', { style: `color: ${extraData.fakeipStatus?.color}` }, [
                        extraData.fakeipStatus?.state === 'working' ? '✔' : extraData.fakeipStatus?.state === 'not_working' ? '✘' : '!',
                        ' ',
                        extraData.fakeipStatus?.state === 'working' ? _('works in browser') : _('not works in browser')
                    ])
                ]),
                E('div', {}, [
                    E('span', { style: `color: ${extraData.fakeipCLIStatus?.color}` }, [
                        extraData.fakeipCLIStatus?.state === 'working' ? '✔' : extraData.fakeipCLIStatus?.state === 'not_working' ? '✘' : '!',
                        ' ',
                        extraData.fakeipCLIStatus?.state === 'working' ? _('works on router') : _('not works on router')
                    ])
                ])
            ]),
            E('div', { style: 'margin-bottom: 5px;' }, [
                E('div', {}, [
                    E('strong', {}, _('DNS Status')),
                    E('br'),
                    E('span', { style: `color: ${extraData.dnsStatus?.remote?.color}` }, [
                        extraData.dnsStatus?.remote?.state === 'available' ? '✔' : extraData.dnsStatus?.remote?.state === 'unavailable' ? '✘' : '!',
                        ' ',
                        extraData.dnsStatus?.remote?.message
                    ]),
                    E('br'),
                    E('span', { style: `color: ${extraData.dnsStatus?.local?.color}` }, [
                        extraData.dnsStatus?.local?.state === 'available' ? '✔' : extraData.dnsStatus?.local?.state === 'unavailable' ? '✘' : '!',
                        ' ',
                        extraData.dnsStatus?.local?.message
                    ])
                ])
            ]),
            E('div', { style: 'margin-bottom: 5px;' }, [
                E('div', {}, [
                    E('strong', {}, extraData.configName),
                    E('br'),
                    E('span', { style: `color: ${extraData.bypassStatus?.color}` }, [
                        extraData.bypassStatus?.state === 'working' ? '✔' : extraData.bypassStatus?.state === 'not_working' ? '✘' : '!',
                        ' ',
                        extraData.bypassStatus?.message
                    ])
                ])
            ])
        ] : buttons)
    ]);
};

// Create the status section
let createStatusSection = function (podkopStatus, singboxStatus, podkop, luci, singbox, system, fakeipStatus, fakeipCLIStatus, dnsStatus, bypassStatus, configName) {
    return E('div', { 'class': 'cbi-section' }, [
        E('div', { 'class': 'table', style: 'display: flex; gap: 20px;' }, [
            // Podkop Status Panel
            createStatusPanel('Podkop Status', podkopStatus, [
                ButtonFactory.createActionButton({
                    label: 'Restart Podkop',
                    type: 'apply',
                    action: 'restart',
                    reload: true
                }),
                ButtonFactory.createActionButton({
                    label: 'Stop Podkop',
                    type: 'apply',
                    action: 'stop',
                    reload: true
                }),
                ButtonFactory.createInitActionButton({
                    label: podkopStatus.enabled ? 'Disable Autostart' : 'Enable Autostart',
                    type: podkopStatus.enabled ? 'remove' : 'apply',
                    action: podkopStatus.enabled ? 'disable' : 'enable',
                    reload: true
                }),
                ButtonFactory.createModalButton({
                    label: _('Global check'),
                    command: 'global_check',
                    title: _('Click here for all the info')
                }),
                ButtonFactory.createModalButton({
                    label: 'View Logs',
                    command: 'check_logs',
                    title: 'Podkop Logs'
                }),
                ButtonFactory.createModalButton({
                    label: _('Update Lists'),
                    command: 'list_update',
                    title: _('Lists Update Results')
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
                }),
                ButtonFactory.createModalButton({
                    label: _('Check NFT Rules'),
                    command: 'check_nft',
                    title: _('NFT Rules')
                }),
                ButtonFactory.createModalButton({
                    label: _('Check DNSMasq'),
                    command: 'check_dnsmasq',
                    title: _('DNSMasq Configuration')
                })
            ]),

            // FakeIP Status Panel
            createStatusPanel(_('FakeIP Status'), null, null, {
                fakeipStatus,
                fakeipCLIStatus,
                dnsStatus,
                bypassStatus,
                configName
            }),

            // Version Information Panel
            createStatusPanel(_('Version Information'), null, [
                E('div', { 'style': 'margin-top: 10px; font-family: monospace; white-space: pre-wrap;' }, [
                    E('strong', {}, _('Podkop: ')), podkop.stdout ? podkop.stdout.trim() : _('Unknown'), '\n',
                    E('strong', {}, _('LuCI App: ')), luci.stdout ? luci.stdout.trim() : _('Unknown'), '\n',
                    E('strong', {}, _('Sing-box: ')), singbox.stdout ? singbox.stdout.trim() : _('Unknown'), '\n',
                    E('strong', {}, _('OpenWrt Version: ')), system.stdout ? system.stdout.split('\n')[1].trim() : _('Unknown'), '\n',
                    E('strong', {}, _('Device Model: ')), system.stdout ? system.stdout.split('\n')[4].trim() : _('Unknown')
                ])
            ])
        ])
    ]);
};

// Diagnostics Update Functions
let diagnosticsUpdateTimer = null;
let errorPollTimer = null;
let lastErrorsSet = new Set();
let isInitialCheck = true;

function startDiagnosticsUpdates() {
    if (diagnosticsUpdateTimer) {
        clearInterval(diagnosticsUpdateTimer);
    }

    const container = document.getElementById('diagnostics-status');
    if (container) {
        container.innerHTML = _('Loading diagnostics...');
    }

    updateDiagnostics();
    diagnosticsUpdateTimer = setInterval(updateDiagnostics, constants.DIAGNOSTICS_UPDATE_INTERVAL);
}

function stopDiagnosticsUpdates() {
    if (diagnosticsUpdateTimer) {
        clearInterval(diagnosticsUpdateTimer);
        diagnosticsUpdateTimer = null;
    }

    // Reset the loading state when stopping updates
    const container = document.getElementById('diagnostics-status');
    if (container) {
        container.removeAttribute('data-loading');
    }
}

function startErrorPolling() {
    if (errorPollTimer) {
        clearInterval(errorPollTimer);
    }

    async function checkErrors() {
        const result = await safeExec('/usr/bin/podkop', ['check_logs']);
        if (!result || !result.stdout) return;

        const logs = result.stdout;

        const errorLines = logs.split('\n').filter(line =>
            line.includes('[critical]')
        );

        if (errorLines.length > 0) {
            const currentErrors = new Set(errorLines);

            if (isInitialCheck) {
                if (errorLines.length > 0) {
                    showErrorNotification(errorLines.join('\n'), true);
                }
                isInitialCheck = false;
            } else {
                const newErrors = [...currentErrors].filter(error => !lastErrorsSet.has(error));

                newErrors.forEach(error => {
                    showErrorNotification(error, false);
                });
            }
            lastErrorsSet = currentErrors;
        }
    }

    checkErrors();

    errorPollTimer = setInterval(checkErrors, constants.ERROR_POLL_INTERVAL);
}

function stopErrorPolling() {
    if (errorPollTimer) {
        clearInterval(errorPollTimer);
        errorPollTimer = null;
    }
}

async function updateDiagnostics() {
    try {
        const results = {
            podkopStatus: null,
            singboxStatus: null,
            podkop: null,
            luci: null,
            singbox: null,
            system: null,
            fakeipStatus: null,
            fakeipCLIStatus: null,
            dnsStatus: null,
            bypassStatus: null
        };

        // Perform all checks independently of each other
        const checks = [
            safeExec('/usr/bin/podkop', ['get_status'])
                .then(result => results.podkopStatus = result)
                .catch(() => results.podkopStatus = { stdout: '{"enabled":0,"status":"error"}' }),

            safeExec('/usr/bin/podkop', ['get_sing_box_status'])
                .then(result => results.singboxStatus = result)
                .catch(() => results.singboxStatus = { stdout: '{"running":0,"enabled":0,"status":"error"}' }),

            safeExec('/usr/bin/podkop', ['show_version'])
                .then(result => results.podkop = result)
                .catch(() => results.podkop = { stdout: 'error' }),

            safeExec('/usr/bin/podkop', ['show_luci_version'])
                .then(result => results.luci = result)
                .catch(() => results.luci = { stdout: 'error' }),

            safeExec('/usr/bin/podkop', ['show_sing_box_version'])
                .then(result => results.singbox = result)
                .catch(() => results.singbox = { stdout: 'error' }),

            safeExec('/usr/bin/podkop', ['show_system_info'])
                .then(result => results.system = result)
                .catch(() => results.system = { stdout: 'error' }),

            checkFakeIP()
                .then(result => results.fakeipStatus = result)
                .catch(() => results.fakeipStatus = { state: 'error', message: 'check error', color: constants.STATUS_COLORS.WARNING }),

            checkFakeIPCLI()
                .then(result => results.fakeipCLIStatus = result)
                .catch(() => results.fakeipCLIStatus = { state: 'error', message: 'check error', color: constants.STATUS_COLORS.WARNING }),

            checkDNSAvailability()
                .then(result => results.dnsStatus = result)
                .catch(() => results.dnsStatus = {
                    remote: { state: 'error', message: 'DNS check error', color: constants.STATUS_COLORS.WARNING },
                    local: { state: 'error', message: 'DNS check error', color: constants.STATUS_COLORS.WARNING }
                }),

            checkBypass()
                .then(result => results.bypassStatus = result)
                .catch(() => results.bypassStatus = { state: 'error', message: 'check error', color: constants.STATUS_COLORS.WARNING })
        ];

        // Waiting for all the checks to be completed
        await Promise.allSettled(checks);

        const container = document.getElementById('diagnostics-status');
        if (!container) return;

        let configName = _('Main config');
        try {
            const data = await uci.load('podkop');
            const proxyString = uci.get('podkop', 'main', 'proxy_string');

            if (proxyString) {
                const activeConfig = proxyString.split('\n')
                    .map(line => line.trim())
                    .find(line => line && !line.startsWith('//'));

                if (activeConfig) {
                    if (activeConfig.includes('#')) {
                        const label = activeConfig.split('#').pop();
                        if (label && label.trim()) {
                            configName = _('Config: ') + decodeURIComponent(label);
                        }
                    }
                }
            }
        } catch (e) {
            console.error('Error getting config name from UCI:', e);
        }

        const parsedPodkopStatus = JSON.parse(results.podkopStatus.stdout || '{"enabled":0,"status":"error"}');
        const parsedSingboxStatus = JSON.parse(results.singboxStatus.stdout || '{"running":0,"enabled":0,"status":"error"}');

        const statusSection = createStatusSection(
            parsedPodkopStatus,
            parsedSingboxStatus,
            results.podkop,
            results.luci,
            results.singbox,
            results.system,
            results.fakeipStatus,
            results.fakeipCLIStatus,
            results.dnsStatus,
            results.bypassStatus,
            configName
        );

        container.innerHTML = '';
        container.appendChild(statusSection);

        // Updating individual status items
        const updateStatusElement = (elementId, status, template) => {
            const element = document.getElementById(elementId);
            if (element) {
                element.innerHTML = template(status);
            }
        };

        updateStatusElement('fakeip-status', results.fakeipStatus,
            status => E('span', { 'style': `color: ${status.color}` }, [
                status.state === 'working' ? '✔ ' : status.state === 'not_working' ? '✘ ' : '! ',
                status.message
            ]).outerHTML
        );

        updateStatusElement('fakeip-cli-status', results.fakeipCLIStatus,
            status => E('span', { 'style': `color: ${status.color}` }, [
                status.state === 'working' ? '✔ ' : status.state === 'not_working' ? '✘ ' : '! ',
                status.message
            ]).outerHTML
        );

        updateStatusElement('dns-remote-status', results.dnsStatus.remote,
            status => E('span', { 'style': `color: ${status.color}` }, [
                status.state === 'available' ? '✔ ' : status.state === 'unavailable' ? '✘ ' : '! ',
                status.message
            ]).outerHTML
        );

        updateStatusElement('dns-local-status', results.dnsStatus.local,
            status => E('span', { 'style': `color: ${status.color}` }, [
                status.state === 'available' ? '✔ ' : status.state === 'unavailable' ? '✘ ' : '! ',
                status.message
            ]).outerHTML
        );

    } catch (e) {
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

function createDiagnosticsSection(mainSection) {
    let o = mainSection.tab('diagnostics', _('Diagnostics'));

    o = mainSection.taboption('diagnostics', form.DummyValue, '_status');
    o.rawhtml = true;
    o.cfgvalue = () => E('div', {
        id: 'diagnostics-status',
        'style': 'cursor: pointer;'
    }, _('Click to load diagnostics...'));
}

function setupDiagnosticsEventHandlers(node) {
    const titleDiv = E('h2', { 'class': 'cbi-map-title' }, _('Podkop'));
    node.insertBefore(titleDiv, node.firstChild);

    document.addEventListener('visibilitychange', function () {
        const diagnosticsContainer = document.getElementById('diagnostics-status');
        if (document.hidden) {
            stopDiagnosticsUpdates();
            stopErrorPolling();
        } else if (diagnosticsContainer && diagnosticsContainer.hasAttribute('data-loading')) {
            startDiagnosticsUpdates();
            startErrorPolling();
        }
    });

    setTimeout(() => {
        const diagnosticsContainer = document.getElementById('diagnostics-status');
        if (diagnosticsContainer) {
            diagnosticsContainer.addEventListener('click', function () {
                if (!this.hasAttribute('data-loading')) {
                    this.setAttribute('data-loading', 'true');
                    startDiagnosticsUpdates();
                    startErrorPolling();
                }
            });
        }

        const tabs = node.querySelectorAll('.cbi-tabmenu');
        if (tabs.length > 0) {
            tabs[0].addEventListener('click', function (e) {
                const tab = e.target.closest('.cbi-tab');
                if (tab) {
                    const tabName = tab.getAttribute('data-tab');
                    if (tabName === 'diagnostics') {
                        const container = document.getElementById('diagnostics-status');
                        if (container && !container.hasAttribute('data-loading')) {
                            container.setAttribute('data-loading', 'true');
                            startDiagnosticsUpdates();
                            startErrorPolling();
                        }
                    } else {
                        stopDiagnosticsUpdates();
                        stopErrorPolling();
                    }
                }
            });

            const activeTab = tabs[0].querySelector('.cbi-tab[data-tab="diagnostics"]');
            if (activeTab) {
                const container = document.getElementById('diagnostics-status');
                if (container && !container.hasAttribute('data-loading')) {
                    container.setAttribute('data-loading', 'true');
                    startDiagnosticsUpdates();
                    startErrorPolling();
                }
            }
        }
    }, constants.DIAGNOSTICS_INITIAL_DELAY);

    node.classList.add('fade-in');
    return node;
}

return baseclass.extend({
    createDiagnosticsSection,
    setupDiagnosticsEventHandlers
}); 