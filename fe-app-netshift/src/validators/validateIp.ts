import { ValidationResult } from './types';

export function validateIPV4(ip: string): ValidationResult {
  const ipRegex =
    /^(?:(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])$/;

  if (ipRegex.test(ip)) {
    return { valid: true, message: _('Valid') };
  }

  return { valid: false, message: _('Invalid IP address') };
}

const HEXTET_REGEX = /^[0-9a-fA-F]{1,4}$/;

function isHextet(group: string): boolean {
  return HEXTET_REGEX.test(group);
}

function isEmbeddedIPv4(group: string): boolean {
  return validateIPV4(group).valid;
}

// Validates one side (the part before or after "::") as a list of hextets.
// The trailing group may be a dotted IPv4 (embedded/IPv4-mapped IPv6), which
// counts as TWO 16-bit groups. Returns the 16-bit group count, or null on any
// invalid group.
function countGroups(side: string, allowEmbeddedIPv4: boolean): number | null {
  if (side === '') {
    return 0;
  }

  const groups = side.split(':');

  for (let i = 0; i < groups.length; i++) {
    const group = groups[i];
    const isLast = i === groups.length - 1;

    if (allowEmbeddedIPv4 && isLast && group.includes('.')) {
      if (!isEmbeddedIPv4(group)) {
        return null;
      }

      continue;
    }

    if (!isHextet(group)) {
      return null;
    }
  }

  // An embedded IPv4 tail occupies two 16-bit groups instead of one.
  const lastGroup = groups[groups.length - 1];
  const embeddedExtra =
    allowEmbeddedIPv4 && lastGroup.includes('.') && isEmbeddedIPv4(lastGroup)
      ? 1
      : 0;

  return groups.length + embeddedExtra;
}

export function validateIPV6(ip: string): ValidationResult {
  const stripped = ip.replace(/^\[/, '').replace(/\]$/, '');
  const invalid: ValidationResult = {
    valid: false,
    message: _('Invalid IPv6 address'),
  };

  // At most one "::" compression is allowed.
  const doubleColonCount = stripped.split('::').length - 1;
  if (doubleColonCount > 1) {
    return invalid;
  }

  if (doubleColonCount === 1) {
    const [head, tail] = stripped.split('::');

    const headGroups = countGroups(head, true);
    const tailGroups = countGroups(tail, true);

    if (headGroups === null || tailGroups === null) {
      return invalid;
    }

    // "::" must replace at least one group, so the explicit groups can total
    // at most 7 (it stands in for one or more zero groups).
    if (headGroups + tailGroups > 7) {
      return invalid;
    }

    return { valid: true, message: _('Valid') };
  }

  // No "::" → must be exactly 8 groups, all explicit.
  const totalGroups = countGroups(stripped, true);
  if (totalGroups === 8) {
    return { valid: true, message: _('Valid') };
  }

  return invalid;
}

export function validateIP(ip: string): ValidationResult {
  const ipv4 = validateIPV4(ip);

  if (ipv4.valid) {
    return ipv4;
  }

  return validateIPV6(ip);
}
