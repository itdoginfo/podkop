import { ValidationResult } from './types';

// "80,443, 1000-2000 5000:5100": ports (1-65535) and ranges, separated by commas or
// spaces. Mirrors parse_port_list of the backend.
export function validatePortList(value: string): ValidationResult {
  const items = value
    .split(/[,\s]+/)
    .map((item) => item.trim())
    .filter(Boolean);

  if (items.length === 0) {
    return { valid: true, message: _('Valid') };
  }

  for (const item of items) {
    const match = item.match(/^(\d+)(?:[-:](\d+))?$/);

    if (!match) {
      return { valid: false, message: _('Invalid port or port range') };
    }

    const first = Number(match[1]);
    const last = match[2] === undefined ? first : Number(match[2]);

    if (first < 1 || last > 65535 || first > last) {
      return { valid: false, message: _('Invalid port or port range') };
    }
  }

  return { valid: true, message: _('Valid') };
}
