import { ValidationResult } from './types';

// TODO refactor current validation and add tests
export function validateShadowsocksConfigUrl(url: string): ValidationResult {
  if (!url.startsWith('ssconf://')) {
    return {
      valid: false,
      message: _('Invalid Shadowsocks Config URL: must start with ssconf://'),
    };
  }

  try {
    if (!url || /\s/.test(url)) {
      return {
        valid: false,
        message: _('Invalid Shadowsocks Config URL: must not contain spaces'),
      };
    }

    // @todo
    // maybe its a good idea to fetch url i validate ss:// options

  } catch (_e) {
    return {
      valid: false,
      message: _('Invalid Shadowsocks Config URL: parsing failed'),
    };
  }

  return { valid: true, message: _('Valid') };
}
