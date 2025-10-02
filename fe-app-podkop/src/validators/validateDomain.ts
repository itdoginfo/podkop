import { ValidationResult } from './types.js';

export function validateDomain(domain: string): ValidationResult {
  const domainRegex =
    /^(?=.{1,253}(?:\/|$))(?:(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)\.)+(?:[a-zA-Z]{2,}|xn--[a-zA-Z0-9-]{1,59}[a-zA-Z0-9])(?:\/[^\s]*)?$/;

  if (!domainRegex.test(domain)) {
    return { valid: false, message: 'Invalid domain address' };
  }

  const hostname = domain.split('/')[0];
  const parts = hostname.split('.');

  const atLeastOneInvalidPart = parts.some((part) => part.length > 63);

  if (atLeastOneInvalidPart) {
    return { valid: false, message: 'Invalid domain address' };
  }

  return { valid: true, message: 'Valid' };
}
