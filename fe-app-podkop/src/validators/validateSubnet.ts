import { ValidationResult } from './types';
import { validateIPV4 } from './validateIp';

export function validateSubnet(value: string): ValidationResult {
  // Must be in form X.X.X.X or X.X.X.X/Y
  const subnetRegex = /^(\d{1,3}\.){3}\d{1,3}(?:\/\d{1,2})?$/;

  if (!subnetRegex.test(value)) {
    return {
      valid: false,
      message: _('Invalid format. Use X.X.X.X or X.X.X.X/Y'),
    };
  }

  const [ip, cidr] = value.split('/');

  if (ip === '0.0.0.0') {
    return { valid: false, message: _('IP address 0.0.0.0 is not allowed') };
  }

  const ipCheck = validateIPV4(ip);
  if (!ipCheck.valid) {
    return ipCheck;
  }

  // Validate CIDR if present
  if (cidr) {
    const cidrNum = parseInt(cidr, 10);

    if (cidrNum < 0 || cidrNum > 32) {
      return {
        valid: false,
        message: _('CIDR must be between 0 and 32'),
      };
    }
  }

  return { valid: true, message: _('Valid') };
}
