import { ValidationResult } from './types';

export function validateDomain(
  domain: string,
  allowDotTLD = false,
): ValidationResult {
  const domainRegex =
    /^(?=.{1,253}(?:\/|$))(?:(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)\.)+(?:(?=[a-zA-Z0-9]*[a-zA-Z])[a-zA-Z0-9]{2,}|xn--[a-zA-Z0-9-]{1,59}[a-zA-Z0-9])(?:\/[^\s]*)?$/;

  if (allowDotTLD) {
    const dotTLD = /^\.(?=[a-zA-Z0-9]*[a-zA-Z])[a-zA-Z0-9]{2,}$/;
    if (dotTLD.test(domain)) {
      return { valid: true, message: _('Valid') };
    }
  }

  if (!domainRegex.test(domain)) {
    return { valid: false, message: _('Invalid domain address') };
  }

  const hostname = domain.split('/')[0];
  const parts = hostname.split('.');

  const atLeastOneInvalidPart = parts.some((part) => part.length > 63);

  if (atLeastOneInvalidPart) {
    return { valid: false, message: _('Invalid domain address') };
  }

  return { valid: true, message: _('Valid') };
}

// Validates a domain entered in the domain-rule fields (Custom domains).
// Unlike a DNS server address, a routing rule cannot match a URL path: the
// backend keeps only the host and drops "example.com/path", so the path is
// rejected here instead of being accepted and silently discarded.
export function validateDomainRule(
  domain: string,
  allowDotTLD = false,
): ValidationResult {
  if (domain.includes('/')) {
    return { valid: false, message: _('Invalid domain address') };
  }

  return validateDomain(domain, allowDotTLD);
}
