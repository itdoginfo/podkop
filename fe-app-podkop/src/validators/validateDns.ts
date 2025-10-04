import { validateDomain } from './validateDomain';
import { validateIPV4 } from './validateIp';
import { ValidationResult } from './types';

export function validateDNS(value: string): ValidationResult {
  if (!value) {
    return { valid: false, message: 'DNS server address cannot be empty' };
  }

  if (validateIPV4(value).valid) {
    return { valid: true, message: 'Valid' };
  }

  if (validateDomain(value).valid) {
    return { valid: true, message: 'Valid' };
  }

  return {
    valid: false,
    message:
      'Invalid DNS server format. Examples: 8.8.8.8 or dns.example.com or dns.example.com/nicedns for DoH',
  };
}
