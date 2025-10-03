import { ValidationResult } from './types';

// TODO refactor current validation and add tests
export function validateVlessUrl(url: string): ValidationResult {
  if (!url.startsWith('vless://')) {
    return {
      valid: false,
      message: 'Invalid VLESS URL: must start with vless://',
    };
  }

  try {
    const uuid = url.split('/')[2]?.split('@')[0];

    if (!uuid) {
      return { valid: false, message: 'Invalid VLESS URL: missing UUID' };
    }

    const serverPart = url.split('@')[1];

    if (!serverPart) {
      return {
        valid: false,
        message: 'Invalid VLESS URL: missing server address',
      };
    }

    const [server, portAndRest] = serverPart.split(':');

    if (!server) {
      return { valid: false, message: 'Invalid VLESS URL: missing server' };
    }

    const port = portAndRest ? portAndRest.split(/[/?#]/)[0] : null;

    if (!port) {
      return { valid: false, message: 'Invalid VLESS URL: missing port' };
    }

    const portNum = parseInt(port, 10);

    if (isNaN(portNum) || portNum < 1 || portNum > 65535) {
      return {
        valid: false,
        message: 'Invalid port number. Must be between 1 and 65535',
      };
    }

    const queryString = url.split('?')[1];

    if (!queryString) {
      return {
        valid: false,
        message: 'Invalid VLESS URL: missing query parameters',
      };
    }

    const params = new URLSearchParams(queryString.split('#')[0]);
    const type = params.get('type');
    const validTypes = ['tcp', 'raw', 'udp', 'grpc', 'http', 'ws'];

    if (!type || !validTypes.includes(type)) {
      return {
        valid: false,
        message:
          'Invalid VLESS URL: type must be one of tcp, raw, udp, grpc, http, ws',
      };
    }

    const security = params.get('security');
    const validSecurities = ['tls', 'reality', 'none'];

    if (!security || !validSecurities.includes(security)) {
      return {
        valid: false,
        message:
          'Invalid VLESS URL: security must be one of tls, reality, none',
      };
    }

    if (security === 'reality') {
      if (!params.get('pbk')) {
        return {
          valid: false,
          message:
            'Invalid VLESS URL: missing pbk parameter for reality security',
        };
      }
      if (!params.get('fp')) {
        return {
          valid: false,
          message:
            'Invalid VLESS URL: missing fp parameter for reality security',
        };
      }
    }
  } catch (_e) {
    return { valid: false, message: 'Invalid VLESS URL: parsing failed' };
  }

  return { valid: true, message: 'Valid' };
}
