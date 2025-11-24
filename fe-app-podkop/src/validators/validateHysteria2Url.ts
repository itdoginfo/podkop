import { ValidationResult } from './types';

// TODO refactor current validation and add tests
export function validateHysteria2Url(url: string): ValidationResult {
    if (!url.startsWith('hysteria2://')) {
        return {
            valid: false,
            message: _('Invalid Hysteria2 URL: must start with hysteria2://'),
        };
    }

    try {
        if (!url || /\s/.test(url)) {
            return {
                valid: false,
                message: _('Invalid Hysteria2 URL: must not contain spaces'),
            };
        }

        // Parse URL using standard URL API
        const parsedUrl = new URL(url);

        // Check if server and port are present
        if (!parsedUrl.hostname) {
            return {
                valid: false,
                message: _('Invalid Hysteria2 URL: missing server address'),
            };
        }

        // Validate port if specified
        if (parsedUrl.port && parsedUrl.port !== '') {
            const portNum = parseInt(parsedUrl.port, 10);
            if (isNaN(portNum) || portNum < 1 || portNum > 65535) {
                return {
                    valid: false,
                    message: _('Invalid port number. Must be between 1 and 65535'),
                };
            }
        }

        // Check for auth info (password)
        if (!parsedUrl.username && !parsedUrl.password) {
            return {
                valid: false,
                message: _('Invalid Hysteria2 URL: missing authentication'),
            };
        }

        // Validate upmbps and downmbps if present in query params
        const params = parsedUrl.searchParams;
        if (params.has('upmbps')) {
            const upmbps = parseInt(params.get('upmbps')!, 10);
            if (isNaN(upmbps) || upmbps <= 0) {
                return {
                    valid: false,
                    message: _('Invalid upmbps value. Must be a positive number'),
                };
            }
        }

        if (params.has('downmbps')) {
            const downmbps = parseInt(params.get('downmbps')!, 10);
            if (isNaN(downmbps) || downmbps <= 0) {
                return {
                    valid: false,
                    message: _('Invalid downmbps value. Must be a positive number'),
                };
            }
        }

        // Validate obfs if present
        if (params.has('obfs') && params.get('obfs') !== 'salamander') {
            return {
                valid: false,
                message: _('Invalid obfs type. Only "salamander" is supported'),
            };
        }

        if (params.has('obfs') === true && !params.has('obfs-password')) {
            return {
                valid: false,
                message: _('Missing obfs-password for salamander obfuscation'),
            };
        }
    } catch (e) {
        return {
            valid: false,
            message: _('Invalid Hysteria2 URL: parsing failed'),
        };
    }

    return { valid: true, message: _('Valid') };
}
