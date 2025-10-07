import { ValidationResult } from './types';

export function validateVlessUrl(url: string): ValidationResult {
  try {
    const parsedUrl = new URL(url);

    if (!url || /\s/.test(url)) {
      return {
        valid: false,
        message: _('Invalid VLESS URL: must not contain spaces'),
      };
    }

    if (parsedUrl.protocol !== 'vless:') {
      return {
        valid: false,
        message: _('Invalid VLESS URL: must start with vless://'),
      };
    }

    if (!parsedUrl.username) {
      return { valid: false, message: _('Invalid VLESS URL: missing UUID') };
    }

    if (!parsedUrl.hostname) {
      return { valid: false, message: _('Invalid VLESS URL: missing server') };
    }

    if (!parsedUrl.port) {
      return { valid: false, message: _('Invalid VLESS URL: missing port') };
    }

    if (
      isNaN(+parsedUrl.port) ||
      +parsedUrl.port < 1 ||
      +parsedUrl.port > 65535
    ) {
      return {
        valid: false,
        message: _(
          'Invalid VLESS URL: invalid port number. Must be between 1 and 65535',
        ),
      };
    }

    if (!parsedUrl.search) {
      return {
        valid: false,
        message: _('Invalid VLESS URL: missing query parameters'),
      };
    }

    const params = new URLSearchParams(parsedUrl.search);

    const type = params.get('type');
    const validTypes = [
      'tcp',
      'raw',
      'udp',
      'grpc',
      'http',
      'httpupgrade',
      'xhttp',
      'ws',
      'kcp',
    ];

    if (!type || !validTypes.includes(type)) {
      return {
        valid: false,
        message: _(
          'Invalid VLESS URL: type must be one of tcp, raw, udp, grpc, http, ws',
        ),
      };
    }

    const security = params.get('security');
    const validSecurities = ['tls', 'reality', 'none'];

    if (!security || !validSecurities.includes(security)) {
      return {
        valid: false,
        message: _(
          'Invalid VLESS URL: security must be one of tls, reality, none',
        ),
      };
    }

    if (security === 'reality') {
      if (!params.get('pbk')) {
        return {
          valid: false,
          message: _(
            'Invalid VLESS URL: missing pbk parameter for reality security',
          ),
        };
      }
      if (!params.get('fp')) {
        return {
          valid: false,
          message: _(
            'Invalid VLESS URL: missing fp parameter for reality security',
          ),
        };
      }
    }

    return { valid: true, message: _('Valid') };
  } catch (_e) {
    return { valid: false, message: _('Invalid VLESS URL: parsing failed') };
  }
}
