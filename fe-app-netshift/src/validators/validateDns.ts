import { validateDomain } from './validateDomain';
import { validateIPV4, validateIPV6 } from './validateIp';
import { ValidationResult } from './types';

export function validateDNS(value: string): ValidationResult {
  if (!value) {
    return { valid: false, message: _('DNS server address cannot be empty') };
  }

  const valueBeforePath = value.split('/')[0];
  let cleanedValueWithoutPort = value;
  let cleanedIpWithoutPath = valueBeforePath;

  if (valueBeforePath.startsWith('[')) {
    const closingBracketIndex = valueBeforePath.indexOf(']');

    if (closingBracketIndex > 0) {
      cleanedIpWithoutPath = valueBeforePath.slice(1, closingBracketIndex);
    }
  } else if ((valueBeforePath.match(/:/g) || []).length < 2) {
    cleanedValueWithoutPort = value.replace(/:(\d+)(?=\/|$)/, '');
    cleanedIpWithoutPath = cleanedValueWithoutPort.split('/')[0];
  }

  if (validateIPV4(cleanedIpWithoutPath).valid) {
    return { valid: true, message: _('Valid') };
  }

  if (validateIPV6(cleanedIpWithoutPath).valid) {
    return { valid: true, message: _('Valid') };
  }

  if (validateDomain(cleanedValueWithoutPort).valid) {
    return { valid: true, message: _('Valid') };
  }

  return {
    valid: false,
    message: _(
      'Invalid DNS server format. Examples: 8.8.8.8, [::1], dns.example.com, or dns.example.com/dns-query for DoH',
    ),
  };
}
