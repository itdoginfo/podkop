'use strict';
'require baseclass';
'require form';
'require ui';
'require uci';
'require fs';
'require view.podkop.constants as constants';

// Cache system for network requests
const fetchCache = {};

// Helper function to fetch with cache
async function cachedFetch(url, options = {}) {
    const cacheKey = url;
    const currentTime = Date.now();

    // If we have a valid cached response, return it
    if (fetchCache[cacheKey] && currentTime - fetchCache[cacheKey].timestamp < constants.CACHE_TIMEOUT) {
        console.log(`Using cached response for ${url}`);
        return Promise.resolve(fetchCache[cacheKey].response.clone());
    }

    // Otherwise, make a new request
    try {
        const response = await fetch(url, options);

        // Cache the response
        fetchCache[cacheKey] = {
            response: response.clone(),
            timestamp: currentTime
        };

        return response;
    } catch (error) {
        throw error;
    }
}

// Helper functions for command execution with prioritization
function safeExec(command, args, priority, callback, timeout = constants.COMMAND_TIMEOUT) {
    priority = (typeof priority === 'number') ? priority : 0;

    const executeCommand = async () => {
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

            if (callback && typeof callback === 'function') {
                callback(result);
            }

            return result;
        } catch (error) {
            console.warn(`Command execution failed or timed out: ${command} ${args.join(' ')}`);
            const errorResult = { stdout: '', stderr: error.message, error: error };

            if (callback && typeof callback === 'function') {
                callback(errorResult);
            }

            return errorResult;
        }
    };

    if (callback && typeof callback === 'function') {
        setTimeout(executeCommand, constants.RUN_PRIORITY[priority]);
        return;
    }
    else {
        return executeCommand();
    }
}

function runCheck(checkFunction, priority, callback) {
    priority = (typeof priority === 'number') ? priority : 0;

    const executeCheck = async () => {
        try {
            const result = await checkFunction();
            if (callback && typeof callback === 'function') {
                callback(result);
            }
            return result;
        } catch (error) {
            if (callback && typeof callback === 'function') {
                callback({ error });
            }
            return { error };
        }
    };

    if (callback && typeof callback === 'function') {
        setTimeout(executeCheck, constants.RUN_PRIORITY[priority]);
        return;
    } else {
        return executeCheck();
    }
}

function runAsyncTask(taskFunction, priority) {
    priority = (typeof priority === 'number') ? priority : 0;

    setTimeout(async () => {
        try {
            await taskFunction();
        } catch (error) {
            console.error('Async task error:', error);
        }
    }, constants.RUN_PRIORITY[priority]);
}

// Helper Functions for UI and formatting
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

function copyToClipboard(text, button) {
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
}

// IP masking function
function maskIP(ip) {
    if (!ip) return '';
    const parts = ip.split('.');
    if (parts.length !== 4) return ip;
    return ['XX', 'XX', 'XX', parts[3]].join('.');
}

// Status Check Functions
async function checkFakeIP() {
    try {
        const controller = new AbortController();
        const timeoutId = setTimeout(() => controller.abort(), constants.FETCH_TIMEOUT);

        try {
            const response = await cachedFetch(`https://${constants.FAKEIP_CHECK_DOMAIN}/check`, { signal: controller.signal });
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
        return new Promise((resolve) => {
            safeExec('/usr/bin/podkop', ['get_sing_box_status'], 0, singboxStatusResult => {
                const singboxStatus = JSON.parse(singboxStatusResult.stdout || '{"running":0,"dns_configured":0}');

                if (!singboxStatus.running) {
                    resolve(createStatus('not_working', 'sing-box not running', 'ERROR'));
                    return;
                }

                safeExec('nslookup', ['-timeout=2', constants.FAKEIP_CHECK_DOMAIN, '127.0.0.42'], 0, result => {
                    if (result.stdout && result.stdout.includes('198.18')) {
                        resolve(createStatus('working', 'working on router', 'SUCCESS'));
                    } else {
                        resolve(createStatus('not_working', 'not working on router', 'ERROR'));
                    }
                });
            });
        });
    } catch (error) {
        return createStatus('error', 'CLI check error', 'WARNING');
    }
}

function checkDNSAvailability() {
    return new Promise(async (resolve) => {
        try {
            safeExec('/usr/bin/podkop', ['check_dns_available'], 0, dnsStatusResult => {
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
            });
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

            safeExec('/usr/bin/podkop', ['get_sing_box_status'], 0, singboxStatusResult => {
                const singboxStatus = JSON.parse(singboxStatusResult.stdout || '{"running":0,"dns_configured":0}');

                if (!singboxStatus.running) {
                    return resolve(createStatus('not_working', `${configMode} not running`, 'ERROR'));
                }

                // Fetch IP from first endpoint
                let ip1 = null;
                try {
                    const controller1 = new AbortController();
                    const timeoutId1 = setTimeout(() => controller1.abort(), constants.FETCH_TIMEOUT);

                    cachedFetch(`https://${constants.FAKEIP_CHECK_DOMAIN}/check`, { signal: controller1.signal })
                        .then(response1 => response1.json())
                        .then(data1 => {
                            clearTimeout(timeoutId1);
                            ip1 = data1.IP;

                            // Fetch IP from second endpoint
                            const controller2 = new AbortController();
                            const timeoutId2 = setTimeout(() => controller2.abort(), constants.FETCH_TIMEOUT);

                            cachedFetch(`https://${constants.IP_CHECK_DOMAIN}/check`, { signal: controller2.signal })
                                .then(response2 => response2.json())
                                .then(data2 => {
                                    clearTimeout(timeoutId2);
                                    const ip2 = data2.IP;

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
                                })
                                .catch(error => {
                                    return resolve(createStatus('not_working', `${configMode} not working`, 'ERROR'));
                                });
                        })
                        .catch(error => {
                            return resolve(createStatus('error', 'First endpoint check failed', 'WARNING'));
                        });
                } catch (error) {
                    return resolve(createStatus('error', 'Bypass check error', 'WARNING'));
                }
            });
        } catch (error) {
            return resolve(createStatus('error', 'Bypass check error', 'WARNING'));
        }
    });
}

// Error Handling
async function getPodkopErrors() {
    return new Promise(resolve => {
        safeExec('/usr/bin/podkop', ['check_logs'], 0, result => {
            if (!result || !result.stdout) {
                console.error('No logs received from check_logs command');
                return resolve([]);
            }

            const logs = result.stdout.split('\n');
            console.log('Got logs from check_logs command, total lines:', logs.length);

            const errors = logs.filter(log => {
                const hasCritical = log.includes('[critical]');
                if (hasCritical) {
                    console.log('Found critical log:', log);
                }
                return hasCritical;
            });

            console.log('Found errors:', errors.length, errors);
            resolve(errors);
        });
    });
}

function showErrorNotification(error, isMultiple = false) {
    const notificationContent = E('div', { 'class': 'alert-message error' }, [
        E('pre', { 'class': 'error-log' }, error)
    ]);

    ui.addNotification(null, notificationContent);
}

// Modal Functions
function createModalContent(title, content) {
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
}

function showConfigModal(command, title) {
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
            safeExec('/usr/bin/podkop', [command], 0, res => {
                formattedOutput = formatDiagnosticOutput(res.stdout || _('No output'));

                try {
                    const controller = new AbortController();
                    const timeoutId = setTimeout(() => controller.abort(), constants.FETCH_TIMEOUT);

                    cachedFetch(`https://${constants.FAKEIP_CHECK_DOMAIN}/check`, { signal: controller.signal })
                        .then(response => response.json())
                        .then(data => {
                            clearTimeout(timeoutId);

                            if (data.fakeip === true) {
                                formattedOutput += '\n✅ ' + _('FakeIP is working in browser!') + '\n';
                            } else {
                                formattedOutput += '\n❌ ' + _('FakeIP is not working in browser') + '\n';
                                formattedOutput += _('Check DNS server on current device (PC, phone)') + '\n';
                                formattedOutput += _('Its must be router!') + '\n';
                            }

                            // Bypass check
                            cachedFetch(`https://${constants.FAKEIP_CHECK_DOMAIN}/check`, { signal: controller.signal })
                                .then(bypassResponse => bypassResponse.json())
                                .then(bypassData => {
                                    cachedFetch(`https://${constants.IP_CHECK_DOMAIN}/check`, { signal: controller.signal })
                                        .then(bypassResponse2 => bypassResponse2.json())
                                        .then(bypassData2 => {
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
                                        })
                                        .catch(error => {
                                            formattedOutput += '\n❌ ' + _('Check failed: ') + (error.name === 'AbortError' ? _('timeout') : error.message) + '\n';
                                            updateModalContent(formattedOutput);
                                        });
                                })
                                .catch(error => {
                                    formattedOutput += '\n❌ ' + _('Check failed: ') + (error.name === 'AbortError' ? _('timeout') : error.message) + '\n';
                                    updateModalContent(formattedOutput);
                                });
                        })
                        .catch(error => {
                            formattedOutput += '\n❌ ' + _('Check failed: ') + (error.name === 'AbortError' ? _('timeout') : error.message) + '\n';
                            updateModalContent(formattedOutput);
                        });
                } catch (error) {
                    formattedOutput += '\n❌ ' + _('Check failed: ') + error.message + '\n';
                    updateModalContent(formattedOutput);
                }
            });
        } else {
            safeExec('/usr/bin/podkop', [command], 0, res => {
                formattedOutput = formatDiagnosticOutput(res.stdout || _('No output'));
                updateModalContent(formattedOutput);
            });
        }
    } catch (error) {
        updateModalContent(_('Error: ') + error.message);
    }
}

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

// Create a loading placeholder for status text
function createLoadingStatusText() {
    return E('span', { 'class': 'loading-indicator' }, _('Loading...'));
}

// Create the status section with buttons loaded immediately but status indicators loading asynchronously
let createStatusSection = async function () {
    // Get initial podkop status
    let initialPodkopStatus = { enabled: false };
    try {
        const result = await fs.exec('/usr/bin/podkop', ['get_status']);
        if (result && result.stdout) {
            const status = JSON.parse(result.stdout);
            initialPodkopStatus.enabled = status.enabled === 1;
        }
    } catch (e) {
        console.error('Error getting initial podkop status:', e);
    }

    return E('div', { 'class': 'cbi-section' }, [
        E('div', { 'class': 'table', style: 'display: flex; gap: 20px;' }, [
            // Podkop Status Panel
            E('div', { 'id': 'podkop-status-panel', 'class': 'panel', 'style': 'flex: 1; padding: 15px;' }, [
                E('div', { 'class': 'panel-heading' }, [
                    E('strong', {}, _('Podkop Status')),
                    E('br'),
                    E('span', { 'id': 'podkop-status-text' }, createLoadingStatusText())
                ]),
                E('div', { 'class': 'panel-body', 'style': 'display: flex; flex-direction: column; gap: 8px;' }, [
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
                    // Autostart button - create with initial state
                    ButtonFactory.createInitActionButton({
                        label: initialPodkopStatus.enabled ? 'Disable Autostart' : 'Enable Autostart',
                        type: initialPodkopStatus.enabled ? 'remove' : 'apply',
                        action: initialPodkopStatus.enabled ? 'disable' : 'enable',
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
                ])
            ]),

            // Sing-box Status Panel
            E('div', { 'id': 'singbox-status-panel', 'class': 'panel', 'style': 'flex: 1; padding: 15px;' }, [
                E('div', { 'class': 'panel-heading' }, [
                    E('strong', {}, _('Sing-box Status')),
                    E('br'),
                    E('span', { 'id': 'singbox-status-text' }, createLoadingStatusText())
                ]),
                E('div', { 'class': 'panel-body', 'style': 'display: flex; flex-direction: column; gap: 8px;' }, [
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
                ])
            ]),

            // FakeIP Status Panel
            E('div', { 'id': 'fakeip-status-panel', 'class': 'panel', 'style': 'flex: 1; padding: 15px;' }, [
                E('div', { 'class': 'panel-heading' }, [
                    E('strong', {}, _('FakeIP Status'))
                ]),
                E('div', { 'class': 'panel-body', 'style': 'display: flex; flex-direction: column; gap: 8px;' }, [
                    E('div', { style: 'margin-bottom: 5px;' }, [
                        E('div', {}, [
                            E('span', { 'id': 'fakeip-browser-status' }, createLoadingStatusText())
                        ]),
                        E('div', {}, [
                            E('span', { 'id': 'fakeip-router-status' }, createLoadingStatusText())
                        ])
                    ]),
                    E('div', { style: 'margin-bottom: 5px;' }, [
                        E('div', {}, [
                            E('strong', {}, _('DNS Status')),
                            E('br'),
                            E('span', { 'id': 'dns-remote-status' }, createLoadingStatusText()),
                            E('br'),
                            E('span', { 'id': 'dns-local-status' }, createLoadingStatusText())
                        ])
                    ]),
                    E('div', { style: 'margin-bottom: 5px;' }, [
                        E('div', {}, [
                            E('strong', { 'id': 'config-name-text' }, _('Main config')),
                            E('br'),
                            E('span', { 'id': 'bypass-status' }, createLoadingStatusText())
                        ])
                    ])
                ])
            ]),

            // Version Information Panel
            E('div', { 'id': 'version-info-panel', 'class': 'panel', 'style': 'flex: 1; padding: 15px;' }, [
                E('div', { 'class': 'panel-heading' }, [
                    E('strong', {}, _('Version Information'))
                ]),
                E('div', { 'class': 'panel-body' }, [
                    E('div', { 'style': 'margin-top: 10px; font-family: monospace; white-space: pre-wrap;' }, [
                        E('strong', {}, _('Podkop: ')), E('span', { 'id': 'podkop-version' }, _('Loading...')), '\n',
                        E('strong', {}, _('LuCI App: ')), E('span', { 'id': 'luci-version' }, _('Loading...')), '\n',
                        E('strong', {}, _('Sing-box: ')), E('span', { 'id': 'singbox-version' }, _('Loading...')), '\n',
                        E('strong', {}, _('OpenWrt Version: ')), E('span', { 'id': 'openwrt-version' }, _('Loading...')), '\n',
                        E('strong', {}, _('Device Model: ')), E('span', { 'id': 'device-model' }, _('Loading...'))
                    ])
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

// Error polling functions
function startErrorPolling() {
    console.log('Starting error polling');
    if (errorPollTimer) {
        console.log('Clearing existing error poll timer');
        clearInterval(errorPollTimer);
    }

    // Reset initial check flag to make sure we show errors
    isInitialCheck = false;

    // Immediately check for errors on start
    console.log('Running immediate check for errors');
    checkForCriticalErrors();

    // Then set up periodic checks
    console.log('Setting up periodic error checks with interval:', constants.ERROR_POLL_INTERVAL);
    errorPollTimer = setInterval(checkForCriticalErrors, constants.ERROR_POLL_INTERVAL);
}

function stopErrorPolling() {
    if (errorPollTimer) {
        clearInterval(errorPollTimer);
        errorPollTimer = null;
    }
}

async function checkForCriticalErrors() {
    try {
        console.log('Checking for critical errors, isInitialCheck =', isInitialCheck);
        const errors = await getPodkopErrors();
        console.log('Got errors from getPodkopErrors:', errors.length);

        if (errors && errors.length > 0) {
            // Filter out errors we've already seen
            const newErrors = errors.filter(error => !lastErrorsSet.has(error));
            console.log('New errors not seen before:', newErrors.length);

            if (newErrors.length > 0) {
                // On initial check, just store errors without showing notifications
                if (!isInitialCheck) {
                    console.log('Showing notifications for errors:', newErrors.length);
                    // Show each new error as a notification
                    newErrors.forEach(error => {
                        console.log('Showing notification for error:', error);
                        showErrorNotification(error, newErrors.length > 1);
                    });
                } else {
                    console.log('Initial check, not showing notifications');
                }

                // Add new errors to our set of seen errors
                newErrors.forEach(error => lastErrorsSet.add(error));
                console.log('Updated lastErrorsSet, size =', lastErrorsSet.size);
            }
        }

        // After first check, mark as no longer initial
        if (isInitialCheck) {
            console.log('Setting isInitialCheck to false');
            isInitialCheck = false;
        }
    } catch (error) {
        console.error('Error checking for critical messages:', error);
    }
}

// Update individual text element with new content
function updateTextElement(elementId, content) {
    const element = document.getElementById(elementId);
    if (element) {
        element.innerHTML = '';
        element.appendChild(content);
    }
}

async function updateDiagnostics() {
    // Podkop Status check
    safeExec('/usr/bin/podkop', ['get_status'], 0, result => {
        try {
            const parsedPodkopStatus = JSON.parse(result.stdout || '{"enabled":0,"status":"error"}');

            // Update Podkop status text
            updateTextElement('podkop-status-text',
                E('span', {
                    'style': `color: ${parsedPodkopStatus.enabled ? constants.STATUS_COLORS.SUCCESS : constants.STATUS_COLORS.ERROR}`
                }, [
                    parsedPodkopStatus.enabled ? '✔ Autostart enabled' : '✘ Autostart disabled'
                ])
            );

            // Update autostart button
            const autostartButton = parsedPodkopStatus.enabled ?
                ButtonFactory.createInitActionButton({
                    label: 'Disable Autostart',
                    type: 'remove',
                    action: 'disable',
                    reload: true
                }) :
                ButtonFactory.createInitActionButton({
                    label: 'Enable Autostart',
                    type: 'apply',
                    action: 'enable',
                    reload: true
                });

            // Find the autostart button and replace it
            const panel = document.getElementById('podkop-status-panel');
            if (panel) {
                const buttons = panel.querySelectorAll('.cbi-button');
                if (buttons.length >= 3) {
                    buttons[2].parentNode.replaceChild(autostartButton, buttons[2]);
                }
            }
        } catch (error) {
            updateTextElement('podkop-status-text',
                E('span', { 'style': `color: ${constants.STATUS_COLORS.ERROR}` }, '✘ Error')
            );
        }
    });

    // Sing-box Status check
    safeExec('/usr/bin/podkop', ['get_sing_box_status'], 0, result => {
        try {
            const parsedSingboxStatus = JSON.parse(result.stdout || '{"running":0,"enabled":0,"status":"error"}');

            // Update Sing-box status text
            updateTextElement('singbox-status-text',
                E('span', {
                    'style': `color: ${parsedSingboxStatus.running && !parsedSingboxStatus.enabled ?
                        constants.STATUS_COLORS.SUCCESS : constants.STATUS_COLORS.ERROR}`
                }, [
                    parsedSingboxStatus.running && !parsedSingboxStatus.enabled ?
                        '✔ running' : '✘ ' + parsedSingboxStatus.status
                ])
            );
        } catch (error) {
            updateTextElement('singbox-status-text',
                E('span', { 'style': `color: ${constants.STATUS_COLORS.ERROR}` }, '✘ Error')
            );
        }
    });

    // Version Information checks
    safeExec('/usr/bin/podkop', ['show_version'], 2, result => {
        updateTextElement('podkop-version',
            document.createTextNode(result.stdout ? result.stdout.trim() : _('Unknown'))
        );
    });

    safeExec('/usr/bin/podkop', ['show_luci_version'], 2, result => {
        updateTextElement('luci-version',
            document.createTextNode(result.stdout ? result.stdout.trim() : _('Unknown'))
        );
    });

    safeExec('/usr/bin/podkop', ['show_sing_box_version'], 2, result => {
        updateTextElement('singbox-version',
            document.createTextNode(result.stdout ? result.stdout.trim() : _('Unknown'))
        );
    });

    safeExec('/usr/bin/podkop', ['show_system_info'], 2, result => {
        if (result.stdout) {
            updateTextElement('openwrt-version',
                document.createTextNode(result.stdout.split('\n')[1].trim())
            );
            updateTextElement('device-model',
                document.createTextNode(result.stdout.split('\n')[4].trim())
            );
        } else {
            updateTextElement('openwrt-version', document.createTextNode(_('Unknown')));
            updateTextElement('device-model', document.createTextNode(_('Unknown')));
        }
    });

    // FakeIP and DNS status checks
    runCheck(checkFakeIP, 3, result => {
        updateTextElement('fakeip-browser-status',
            E('span', { style: `color: ${result.error ? constants.STATUS_COLORS.WARNING : result.color}` }, [
                result.error ? '! ' : result.state === 'working' ? '✔ ' : result.state === 'not_working' ? '✘ ' : '! ',
                result.error ? 'check error' : result.state === 'working' ? _('works in browser') : _('not works in browser')
            ])
        );
    });

    runCheck(checkFakeIPCLI, 3, result => {
        updateTextElement('fakeip-router-status',
            E('span', { style: `color: ${result.error ? constants.STATUS_COLORS.WARNING : result.color}` }, [
                result.error ? '! ' : result.state === 'working' ? '✔ ' : result.state === 'not_working' ? '✘ ' : '! ',
                result.error ? 'check error' : result.state === 'working' ? _('works on router') : _('not works on router')
            ])
        );
    });

    runCheck(checkDNSAvailability, 4, result => {
        if (result.error) {
            updateTextElement('dns-remote-status',
                E('span', { style: `color: ${constants.STATUS_COLORS.WARNING}` }, '! DNS check error')
            );
            updateTextElement('dns-local-status',
                E('span', { style: `color: ${constants.STATUS_COLORS.WARNING}` }, '! DNS check error')
            );
        } else {
            updateTextElement('dns-remote-status',
                E('span', { style: `color: ${result.remote.color}` }, [
                    result.remote.state === 'available' ? '✔ ' : result.remote.state === 'unavailable' ? '✘ ' : '! ',
                    result.remote.message
                ])
            );

            updateTextElement('dns-local-status',
                E('span', { style: `color: ${result.local.color}` }, [
                    result.local.state === 'available' ? '✔ ' : result.local.state === 'unavailable' ? '✘ ' : '! ',
                    result.local.message
                ])
            );
        }
    });

    runCheck(checkBypass, 1, result => {
        updateTextElement('bypass-status',
            E('span', { style: `color: ${result.error ? constants.STATUS_COLORS.WARNING : result.color}` }, [
                result.error ? '! ' : result.state === 'working' ? '✔ ' : result.state === 'not_working' ? '✘ ' : '! ',
                result.error ? 'check error' : result.message
            ])
        );
    });

    // Config name
    runAsyncTask(async () => {
        try {
            let configName = _('Main config');
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

            updateTextElement('config-name-text', document.createTextNode(configName));
        } catch (e) {
            console.error('Error getting config name from UCI:', e);
        }
    }, 1);
}

function createDiagnosticsSection(mainSection) {
    let o = mainSection.tab('diagnostics', _('Diagnostics'));

    o = mainSection.taboption('diagnostics', form.DummyValue, '_status');
    o.rawhtml = true;
    o.cfgvalue = () => E('div', {
        id: 'diagnostics-status',
        'data-loading': 'true'
    });
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
            if (diagnosticsContainer.hasAttribute('data-loading')) {
                diagnosticsContainer.innerHTML = '';
                showConfigModal.busy = false;
                createStatusSection().then(section => {
                    diagnosticsContainer.appendChild(section);
                    startDiagnosticsUpdates();
                    startErrorPolling();
                });
            }
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

                            // Render UI structure immediately
                            container.innerHTML = '';
                            createStatusSection().then(section => {
                                container.appendChild(section);
                                startDiagnosticsUpdates();
                                startErrorPolling();
                            });
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

                    // Render UI structure immediately
                    container.innerHTML = '';
                    createStatusSection().then(section => {
                        container.appendChild(section);
                        startDiagnosticsUpdates();
                        startErrorPolling();
                    });
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