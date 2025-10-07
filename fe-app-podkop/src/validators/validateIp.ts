import { ValidationResult } from './types';

export function validateIPV4(ip: string): ValidationResult {
  const ipRegex =
    /^(?:(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])$/;

  if (ipRegex.test(ip)) {
    return { valid: true, message: _('Valid') };
  }

  return { valid: false, message: _('Invalid IP address') };
}
