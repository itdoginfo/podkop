import { ValidationResult } from './types';

export function validateUrl(
  url: string,
  protocols: string[] = ['http:', 'https:'],
): ValidationResult {
  try {
    const parsedUrl = new URL(url);

    if (!protocols.includes(parsedUrl.protocol)) {
      return {
        valid: false,
        message: `${_('URL must use one of the following protocols:')} ${protocols.join(', ')}`,
      };
    }
    return { valid: true, message: _('Valid') };
  } catch (_e) {
    return { valid: false, message: _('Invalid URL format') };
  }
}
