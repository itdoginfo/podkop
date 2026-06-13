import { ValidationResult } from './types';
import { validateDomain } from './validateDomain';
import { validateIPV4, validateIPV6 } from './validateIp';

// Extracts the bare host from a URL, stripping the scheme, optional userinfo,
// the port, and the path/query/fragment. A bracketed IPv6 literal (e.g.
// "[2001:db8::1]") is unwrapped to "2001:db8::1".
function extractHost(url: string): string {
  // Strip scheme://
  const schemeIndex = url.indexOf('://');
  let rest = schemeIndex === -1 ? url : url.slice(schemeIndex + 3);

  // Strip path/query/fragment (everything from the first '/', '?' or '#').
  const pathIndex = rest.search(/[/?#]/);
  if (pathIndex !== -1) {
    rest = rest.slice(0, pathIndex);
  }

  // Strip optional userinfo ("user:pass@").
  const atIndex = rest.lastIndexOf('@');
  if (atIndex !== -1) {
    rest = rest.slice(atIndex + 1);
  }

  // Bracketed IPv6 literal: "[2001:db8::1]:2096" -> "2001:db8::1".
  if (rest.startsWith('[')) {
    const closeIndex = rest.indexOf(']');
    if (closeIndex !== -1) {
      return rest.slice(1, closeIndex);
    }
    // Unterminated bracket: drop the leading '[' and any ':port' suffix.
    return rest.slice(1).split(':')[0];
  }

  // Bare host: strip a trailing ":port".
  const colonIndex = rest.lastIndexOf(':');
  if (colonIndex !== -1) {
    rest = rest.slice(0, colonIndex);
  }

  return rest;
}

export function validateUrl(
  url: string,
  protocols = ['http:', 'https:'],
): ValidationResult {
  if (!url.length) {
    return { valid: false, message: _('Invalid URL format') };
  }

  const hasValidProtocol = protocols.some((p) => url.indexOf(p + '//') === 0);

  if (!hasValidProtocol)
    return {
      valid: false,
      message:
        _('URL must use one of the following protocols:') +
        ' ' +
        protocols.join(', '),
    };

  const host = extractHost(url);

  if (!host) {
    return { valid: false, message: _('Invalid URL format') };
  }

  const isValidHost =
    validateIPV4(host).valid ||
    validateIPV6(host).valid ||
    validateDomain(host).valid;

  if (isValidHost) {
    return { valid: true, message: _('Valid') };
  }

  return { valid: false, message: _('Invalid URL format') };
}
