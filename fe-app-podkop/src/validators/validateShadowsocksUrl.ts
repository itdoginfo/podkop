import { ValidationResult } from './types';

// TODO refactor current validation and add tests
export function validateShadowsocksUrl(url: string): ValidationResult {
  if (!url.startsWith('ss://')) {
    return {
      valid: false,
      message: _('Invalid Shadowsocks URL: must start with ss://'),
    };
  }

  try {
    if (!url || /\s/.test(url)) {
      return {
        valid: false,
        message: _('Invalid Shadowsocks URL: must not contain spaces'),
      };
    }

    const mainPart = url.includes('?') ? url.split('?')[0] : url.split('#')[0];

    const encryptedPart = mainPart.split('/')[2]?.split('@')[0];

    if (!encryptedPart) {
      return {
        valid: false,
        message: _('Invalid Shadowsocks URL: missing credentials'),
      };
    }

    try {
      const decoded = atob(encryptedPart);

      if (!decoded.includes(':')) {
        return {
          valid: false,
          message: _(
            'Invalid Shadowsocks URL: decoded credentials must contain method:password',
          ),
        };
      }
    } catch (_e) {
      if (!encryptedPart.includes(':') && !encryptedPart.includes('-')) {
        return {
          valid: false,
          message: _(
            'Invalid Shadowsocks URL: missing method and password separator ":"',
          ),
        };
      }
    }

    const serverPart = url.split('@')[1];

    if (!serverPart) {
      return {
        valid: false,
        message: _('Invalid Shadowsocks URL: missing server address'),
      };
    }

    const [server, portAndRest] = serverPart.split(':');

    if (!server) {
      return {
        valid: false,
        message: _('Invalid Shadowsocks URL: missing server'),
      };
    }

    const port = portAndRest ? portAndRest.split(/[?#]/)[0] : null;

    if (!port) {
      return {
        valid: false,
        message: _('Invalid Shadowsocks URL: missing port'),
      };
    }

    const portNum = parseInt(port, 10);

    if (isNaN(portNum) || portNum < 1 || portNum > 65535) {
      return {
        valid: false,
        message: _('Invalid port number. Must be between 1 and 65535'),
      };
    }
  } catch (_e) {
    return {
      valid: false,
      message: _('Invalid Shadowsocks URL: parsing failed'),
    };
  }

  return { valid: true, message: _('Valid') };
}
