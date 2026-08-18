import { ValidationResult } from './types';

export function validateIPV4(ip: string): ValidationResult {
  const ipRegex =
    /^(?:(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])$/;

  if (ipRegex.test(ip)) {
    return { valid: true, message: _('Valid') };
  }

  return { valid: false, message: _('Invalid IP address') };
}

export function validateIPV6(ip: string): ValidationResult {
  // Covers the forms that appear in proxy URLs: full, compressed (::) and
  // IPv4-mapped addresses. Zone indices (%eth0) are not accepted — they are
  // meaningless for a remote endpoint.
  const group = '[0-9a-fA-F]{1,4}';
  const ipv4 =
    '(?:(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\\.){3}(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])';

  const ipv6Regex = new RegExp(
    '^(?:' +
      `(?:${group}:){7}${group}` +
      `|(?:${group}:){1,7}:` +
      `|(?:${group}:){1,6}:${group}` +
      `|(?:${group}:){1,5}(?::${group}){1,2}` +
      `|(?:${group}:){1,4}(?::${group}){1,3}` +
      `|(?:${group}:){1,3}(?::${group}){1,4}` +
      `|(?:${group}:){1,2}(?::${group}){1,5}` +
      `|${group}:(?::${group}){1,6}` +
      `|:(?::${group}){1,7}` +
      '|::' +
      `|(?:${group}:){6}${ipv4}` +
      `|(?:${group}:){1,5}:${ipv4}` +
      `|::(?:${group}:){0,5}${ipv4}` +
      ')$',
  );

  if (ipv6Regex.test(ip)) {
    return { valid: true, message: _('Valid') };
  }

  return { valid: false, message: _('Invalid IPv6 address') };
}
