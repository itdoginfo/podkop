import { ValidationResult } from './types';

export function validateOutboundJson(value: string): ValidationResult {
  try {
    JSON.parse(value);

    return { valid: true, message: _('Valid') };
  } catch {
    return { valid: false, message: _('Invalid JSON format') };
  }
}
