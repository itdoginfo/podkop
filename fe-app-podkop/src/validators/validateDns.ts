import { validateDomain } from './validateDomain';
import { validateIPV4 } from './validateIp';
import { ValidationResult } from './types';

export function validateDNS(value: string): ValidationResult {
  if (!value) {
    return { valid: false, message: _('DNS server address cannot be empty') };
  }

  const cleanedValueWithoutPort = value.replace(/:(\d+)(?=\/|$)/, '');
  const cleanedIpWithoutPath = cleanedValueWithoutPort.split('/')[0];

  if (validateIPV4(cleanedIpWithoutPath).valid) {
    return { valid: true, message: _('Valid') };
  }

  if (validateDomain(cleanedValueWithoutPort).valid) {
    return { valid: true, message: _('Valid') };
  }

  return {
    valid: false,
    message: _(
      'Invalid DNS server format. Examples: 8.8.8.8 or dns.example.com or dns.example.com/nicedns for DoH',
    ),
  };
}
