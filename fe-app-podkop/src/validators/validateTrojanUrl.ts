import { ValidationResult } from './types';

// TODO refactor current validation and add tests
export function validateTrojanUrl(url: string): ValidationResult {
  try {
    if (!url.startsWith('trojan://')) {
      return {
        valid: false,
        message: _('Invalid Trojan URL: must start with trojan://'),
      };
    }

    if (!url || /\s/.test(url)) {
      return {
        valid: false,
        message: _('Invalid Trojan URL: must not contain spaces'),
      };
    }

    const refinedURL = url.replace('trojan://', 'https://');
    const parsedUrl = new URL(refinedURL);

    if (!parsedUrl.username || !parsedUrl.hostname || !parsedUrl.port) {
      return {
        valid: false,
        message: _(
          'Invalid Trojan URL: must contain username, hostname and port',
        ),
      };
    }
  } catch (_e) {
    return { valid: false, message: _('Invalid Trojan URL: parsing failed') };
  }

  return { valid: true, message: _('Valid') };
}
