import { ValidationResult } from './types';

// Time of day as HH:MM, 00:00-23:59 (two digits each, 24-hour clock).
export function validateTime(value: string): ValidationResult {
  if (!value) {
    return {
      valid: false,
      message: _('Time cannot be empty'),
    };
  }

  if (/^([01][0-9]|2[0-3]):[0-5][0-9]$/.test(value)) {
    return {
      valid: true,
      message: _('Valid'),
    };
  }

  return {
    valid: false,
    message: _('Invalid time format. Use HH:MM from 00:00 to 23:59'),
  };
}
