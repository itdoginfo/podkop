import { ValidationResult } from './types';
import { validateIPV4, validateIPV6 } from './validateIp';

export function validateSubnet(value: string): ValidationResult {
  const subnetRegex = /^(\d{1,3}\.){3}\d{1,3}(?:\/\d{1,2})?$/;

  if (subnetRegex.test(value)) {
    const [ip, cidr] = value.split('/');

    if (ip === '0.0.0.0') {
      return { valid: false, message: _('IP address 0.0.0.0 is not allowed') };
    }

    const ipCheck = validateIPV4(ip);
    if (!ipCheck.valid) {
      return ipCheck;
    }

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

  const ipv6CidrRegex = /^([0-9a-fA-F:]+(?:\/[0-9]{1,3})?)$/;
  if (ipv6CidrRegex.test(value)) {
    const [ip, cidr] = value.split('/');
    const ipCheck = validateIPV6(ip);

    if (!ipCheck.valid) {
      return ipCheck;
    }

    if (cidr) {
      const cidrNum = parseInt(cidr, 10);
      if (cidrNum < 0 || cidrNum > 128) {
        return {
          valid: false,
          message: _('IPv6 CIDR must be between 0 and 128'),
        };
      }
    }

    return { valid: true, message: _('Valid') };
  }

  return {
    valid: false,
    message: _('Invalid format. Use X.X.X.X/Y or IPv6/Y'),
  };
}
