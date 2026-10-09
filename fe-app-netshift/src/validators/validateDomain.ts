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
  const prefixed = /^(full|keyword|regex|regexp):(.*)$/i.exec(domain);

  if (prefixed) {
    return validatePrefixedDomainRule(prefixed[1].toLowerCase(), prefixed[2]);
  }

  if (domain.includes('/')) {
    return { valid: false, message: _('Invalid domain address') };
  }

  return validateDomain(domain, allowDotTLD);
}

// full:host, keyword:text and regex:pattern entries of the domain-rule fields.
// The backend hands a pattern to the core, which is the final judge of it; this
// only catches what is wrong at a glance (empty, spaces, not even a regex).
function validatePrefixedDomainRule(
  prefix: string,
  value: string,
): ValidationResult {
  if (prefix === 'full') {
    return validateDomainRule(value, false);
  }

  if (prefix === 'keyword') {
    if (!/^[a-zA-Z0-9._-]+$/.test(value)) {
      return {
        valid: false,
        message: _(
          'Keyword may contain only letters, digits, dots, dashes and underscores',
        ),
      };
    }

    return { valid: true, message: _('Valid') };
  }

  if (!value || /[\s,]/.test(value) || value.length > 256) {
    return {
      valid: false,
      message: _('Regular expression must not contain spaces or commas'),
    };
  }

  try {
    new RegExp(value);
  } catch {
    return { valid: false, message: _('Invalid regular expression') };
  }

  return { valid: true, message: _('Valid') };
}
