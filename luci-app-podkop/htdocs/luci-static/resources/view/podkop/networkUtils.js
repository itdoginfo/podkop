'use strict';
'require baseclass';
'require network';

function validateUrl(url, protocols = ['http:', 'https:']) {
    try {
        const parsedUrl = new URL(url);
        if (!protocols.includes(parsedUrl.protocol)) {
            return _('URL must use one of the following protocols: ') + protocols.join(', ');
        }
        return true;
    } catch (e) {
        return _('Invalid URL format');
    }
}

function getNetworkInterfaces(o, section_id, excludeInterfaces = []) {
    return network.getDevices().then(devices => {
        o.keylist = [];
        o.vallist = [];

        devices.forEach(device => {
            if (device.dev && device.dev.name) {
                const deviceName = device.dev.name;
                if (!excludeInterfaces.includes(deviceName)) {
                    o.value(deviceName, deviceName);
                }
            }
        });
    }).catch(error => {
        console.error('Failed to get network devices:', error);
    });
}

function getNetworkNetworks(o, section_id, excludeInterfaces = []) {
    return network.getNetworks().then(networks => {
        o.keylist = [];
        o.vallist = [];

        networks.forEach(net => {
            const name = net.getName();
            const ifname = net.getIfname();
            if (name && !excludeInterfaces.includes(name)) {
                o.value(name, ifname ? `${name} (${ifname})` : name);
            }
        });
    }).catch(error => {
        console.error('Failed to get networks:', error);
    });
}

return baseclass.extend({
    getNetworkInterfaces,
    getNetworkNetworks,
    validateUrl
}); 