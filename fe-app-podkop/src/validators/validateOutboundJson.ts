import { ValidationResult } from './types';

// TODO refactor current validation and add tests
export function validateOutboundJson(value: string): ValidationResult {
  try {
    const parsed = JSON.parse(value);

    if (!parsed.type || !parsed.server || !parsed.server_port) {
      return {
        valid: false,
        message: _(
          'Outbound JSON must contain at least "type", "server" and "server_port" fields',
        ),
      };
    }

    return { valid: true, message: _('Valid') };
  } catch {
    return { valid: false, message: _('Invalid JSON format') };
  }
}
