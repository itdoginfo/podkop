import { ValidationResult } from './types';

// TODO refactor current validation and add tests
export function validateOutboundJson(value: string): ValidationResult {
  try {
    const parsed = JSON.parse(value);

    if (!parsed.type || !parsed.server || !parsed.server_port) {
      return {
        valid: false,
        message:
          'Outbound JSON must contain at least "type", "server" and "server_port" fields',
      };
    }

    return { valid: true, message: 'Valid' };
  } catch {
    return { valid: false, message: 'Invalid JSON format' };
  }
}
