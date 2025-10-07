import { ValidationResult } from './types';

export function validatePath(value: string): ValidationResult {
  if (!value) {
    return {
      valid: false,
      message: _('Path cannot be empty'),
    };
  }

  const pathRegex = /^\/[a-zA-Z0-9_\-/.]+$/;

  if (pathRegex.test(value)) {
    return {
      valid: true,
      message: _('Valid'),
    };
  }

  return {
    valid: false,
    message: _(
      'Invalid path format. Path must start with "/" and contain valid characters',
    ),
  };
}
